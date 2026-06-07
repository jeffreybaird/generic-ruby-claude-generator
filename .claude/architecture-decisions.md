# Architecture Decisions

Load this file when creating a new model/migration, a service object, or any
system infrastructure. These are decisions made early to avoid costly retrofits
later. Follow them in all new code.

> **Baseline:** Ruby 3.3+ · Rails 8.0 (Hotwire, Propshaft, importmap, Solid
> Queue/Cache/Cable, Kamal 2, Tailwind) · PostgreSQL.
> Domain logic in service objects returning Result types; request context via
> Current attributes; authorization via Pundit.

| Topic | Rails 8 |
|-------|---------|
| Result type | `dry-monads` or hand-rolled |
| Audit log | `audited`/`paper_trail` **or** event subscriber |
| Soft delete | `discard` gem |
| Pagination | Pagy or Kaminari |
| Side effects | called directly after commit (inline / `perform_later`) |
| Idempotency keys | deterministic key per external mutation |
| Feature flags | Flipper |
| Request context | `ActiveSupport::CurrentAttributes` |
| Job tenant id | Active Job / Solid Queue arg |
| Data export | single tenant-scoped service object |

---

## 1. Result / Tagged-Error Pattern

The principle: **expected, recoverable outcomes are values the caller branches on,
not exceptions raised for control flow.** Not found, invalid input, over a plan
limit — these are ordinary results, and `raise` is reserved for the truly
exceptional (programmer error, unreachable state, infrastructure down).

This template's **default** for surfacing those outcomes is a tagged Result: the
Result carries a tagged error so the caller knows the failure *kind* without
inspecting a string. This is the Ruby analog of Elixir's tagged tuples, and it
prepares the domain layer for a future public API without a rewrite. It earns its
keep most when an operation has several distinct failure modes.

**Tagged Results are not the only idiom**, and for simple cases plain Rails is
often clearer:

- A `model.save` / `update` that returns `false` with `model.errors` populated —
  fine for a single-model create/update where the controller just re-renders the form.
- Raising a domain exception and rescuing it at the boundary — fine when the failure
  really is exceptional, or when one rescue at the controller/route covers many actions.

Pick one approach per context and stay consistent. Whatever you pick: don't return a
bare boolean or `nil` where the caller needs to know *why* it failed, and never leak
a raw exception string out of the domain layer as the error (strings are a view concern).

### Default: `dry-monads`

Community default for typed Results. ([dry-monads](https://dry-rb.org/gems/dry-monads/), `gem "dry-monads", "~> 1.8"`)

```ruby
# app/services/my_app/posts/create.rb
module MyApp
  module Posts
    class Create
      include Dry::Monads[:result]

      def self.call(...) = new.call(...)

      def call(account:, actor:, attrs:)
        return Failure([:unauthenticated]) unless actor
        return Failure([:forbidden]) unless PostPolicy.new(actor, Post).create?
        return Failure([:plan_limit_reached, { limit: 100, current: count_for(account) }]) if over_limit?(account)

        post = account.posts.new(attrs)
        if post.save
          MyApp::Audit.record("post.created", resource: post, actor: actor)  # side effects: see §5
          Success(post)
        else
          Failure([:validation, post.errors])
        end
      end
    end
  end
end
```

### Error taxonomy (use these tags verbatim)

| Result | Meaning | HTTP map |
|--------|---------|----------|
| `Success(value)` | ok | 200 / 201 |
| `Failure([:validation, errors])` | invalid input; `errors` is the model's error object | 422 |
| `Failure([:not_found])` | record missing or out of scope | 404 |
| `Failure([:forbidden])` | authenticated but not allowed | 403 |
| `Failure([:unauthenticated])` | no/invalid identity | 401 |
| `Failure([:plan_limit_reached, meta])` | `meta` = `{ limit:, current: }` | 402 / 403 |
| `Failure([:conflict])` | uniqueness / optimistic-lock / duplicate | 409 |

Rules:

- ✅ `Failure([:validation, errors])` — tagged, the caller branches on `:validation`.
- ❌ `Failure(post.errors)` / `Failure("Title can't be blank")` — untagged; never
  return raw strings from a service. Strings are a view concern.
- The leading element is always a `Symbol`; the second (when present) is structured
  data, never a sentence.

### Handling the Result (pattern match)

dry-monads wraps the array as a tuple, so `case/in` deconstructs it directly.
Use `Failure[...]` (brackets) in patterns. ([pattern matching](https://hanakai.org/learn/dry/dry-monads/v1.8/pattern-matching))

**Controller**

```ruby
class PostsController < ApplicationController
  def create
    case MyApp::Posts::Create.call(account: Current.account, actor: Current.user, attrs: post_params)
    in Success(post)
      redirect_to post, notice: "Post created."
    in Failure[:validation, errors]
      @errors = errors
      render :new, status: :unprocessable_entity
    in Failure[:plan_limit_reached, meta]
      render :upgrade, locals: { meta: }, status: :payment_required
    in Failure[:forbidden]
      head :forbidden
    in Failure[:not_found]
      head :not_found
    in Failure[code, *]
      Rails.logger.warn("unhandled result", code:) and head :unprocessable_entity
    end
  end
end
```

> A `Failure[code, *]` catch-all arm is mandatory — an unmatched `case/in` raises
> `NoMatchingPatternError`. Every error tag must have a test exercising its arm.

### Simpler alternative: hand-rolled `Result`

If you do not want a dependency, a frozen value object works and **must mirror the
same tags** so it is swappable with dry-monads.

```ruby
module MyApp
  class Result
    attr_reader :value, :error
    def self.ok(value = nil)       = new(ok: true,  value: value)
    def self.err(*error)           = new(ok: false, error: error.freeze)
    def initialize(ok:, value: nil, error: nil) = (@ok, @value, @error = ok, value, error)
    def ok?  = @ok
    def err? = !@ok
    def deconstruct = ok? ? [value] : error   # enables `case/in`
  end
end

# MyApp::Result.err(:plan_limit_reached, { limit: 100, current: 100 })
# case result in [:plan_limit_reached, meta] then ...
```

---

## 2. Audit Logging on Every Mutation

Every create / update / delete writes one audit row: **who, when, what changed,
from where**. No exceptions.

### Audit row shape

| Column | Example | Source |
|--------|---------|--------|
| `actor_id` | current user id | `Current.user` |
| `account_id` | tenant / org id | `Current.account` |
| `action` | `"post.created"` | `resource.verb` convention |
| `resource_type` / `resource_id` | `"Post"` / `42` | the record |
| `changes` | `{ "title" => ["old", "new"] }` | diff (`saved_changes` in AR) |
| `request_id` | UUID | `Current.request_id` |
| `ip` | `"203.0.113.4"` | request |

Action naming is `resource.verb`: `post.created`, `post.updated`, `post.deleted`,
`member.invited`, `subscription.canceled`, `settings.updated`.

### Gem or a small audit helper

- **Gem path:** `audited` (~> 5) for a single `audits` table across models, or
  `paper_trail` for full versioning/diffing. These hook ActiveRecord callbacks, so
  you get audit rows with no changes to your services.
  ([audited](https://github.com/collectiveidea/audited),
  [paper_trail](https://github.com/paper-trail-gem/paper_trail))
- **Service path:** a small helper the service calls directly, right after the
  mutation commits (§5). Reads actor/account/request_id/ip from the per-request
  context (§8), so the call site stays a one-liner.

```ruby
# app/services/my_app/audit.rb
module MyApp
  class Audit
    def self.record(action, resource:, actor: Current.user)
      AuditLog.create!(
        actor_id:      actor&.id,
        account_id:    Current.account&.id,
        action:        action,                          # "post.created"
        resource_type: resource.class.name,
        resource_id:   resource.id,
        changes:       resource.try(:saved_changes) || {},
        request_id:    Current.request_id,
        ip:            Current.ip
      )
    end
  end
end

# in the service, after save/commit:
MyApp::Audit.record("post.created", resource: post, actor: actor)
```

> Audit rows are **append-only and never soft-deleted** (§3). Retention is a
> separate pruning job.

---

## 3. Soft Deletes on User-Facing Records

Never hard-delete a record a user expects to recover or that other records
reference. Use a `deleted_at` timestamp; filter it out by default; provide an
explicit `with_discarded` escape hatch for admin views and export.

| Soft delete (`deleted_at`) | Hard delete (allowed) |
|----------------------------|-----------------------|
| `Post`, `Comment`, `Collection`, `Tag` | audit logs (append-only) |
| `Plan`, `Notification`, `WebhookEndpoint` | analytics/event rows (append-only) |
| `Account` (deactivate, don't destroy) | sessions / API tokens (revoke = gone) |

### `discard` gem

Community default; adds `deleted_at`, `discard`/`undiscard`, and `kept`/`discarded`
scopes. ([discard](https://github.com/jhawthorn/discard), `gem "discard", "~> 1.3"`)

```ruby
class Post < ApplicationRecord
  include Discard::Model
  self.discard_column = :deleted_at
  default_scope -> { kept }            # filter discarded everywhere by default
end

# ✅ default — discarded rows excluded
Post.all
# ✅ admin / export — include discarded
Post.with_discarded
# delete = discard + audit ("post.deleted")
post.discard
MyApp::Audit.record("post.deleted", resource: post)
```

> Be deliberate with `default_scope`: it applies to associations too. The common
> alternative is **no default scope**, calling `.kept` explicitly in every finder —
> safer but easy to forget. Pick one project-wide and document it.

Restoration sets `deleted_at` back to `nil` and records a `post.restored` audit entry.

---

## 4. Pagination on Every List

Every method returning a collection accepts `page` and `per_page`
(**default 25, max 100**) and returns a consistent paginated result — even if the
current UI shows everything.

### Default: Pagy

Community default — fastest, lowest memory, framework-agnostic.
([pagy](https://github.com/ddnexus/pagy), `gem "pagy", "~> 43.0"`)

> **Version note:** Pagy 43 (2026) is a full API redesign — the backend is the
> `pagy(:offset, scope, ...)` form below via `Pagy::Method`. If your `Gemfile.lock`
> pins an older major, the old `pagy(scope, items:)` signature applies instead;
> confirm against [the docs](https://ddnexus.github.io/pagy) for your pinned major.

```ruby
PER_PAGE_MAX = 100

def list_posts(account:, page: 1, per_page: 25)
  limit = [per_page.to_i, PER_PAGE_MAX].min
  scope = account.posts.kept.order(created_at: :desc)
  pagy, records = Pagy::Method.pagy(:offset, scope, page: page, limit: limit)
  { results: records, page: pagy.page, per_page: pagy.limit,
    total: pagy.count, total_pages: pagy.pages }
end
```

- ✅ every list method clamps `per_page` to 100 and returns the struct above.
- ❌ `account.posts.all` returned raw to the view — unbounded.

### Alternative: Kaminari

`gem "kaminari"` — ActiveRecord/Rails-only (relies on AR relations). Use only if
your project has already standardized on it. ([kaminari](https://github.com/kaminari/kaminari))

---

## 5. Side Effects After Commit

When a mutation has side effects — audit log, webhook dispatch, notification email,
cache invalidation — the service performs them directly, **after the write commits**.
Cheap, must-not-be-lost work (an audit row) runs inline; slow or external work
(webhooks, email, third-party sync) is handed to a **background job** so the request
isn't blocked and delivery is retryable.

```ruby
def call(...)
  post = nil
  ActiveRecord::Base.transaction do
    post = account.posts.create!(attrs)
    # ...any other writes that must be atomic with it...
  end

  # AFTER the transaction commits — side effects, called directly:
  MyApp::Audit.record("post.created", resource: post, actor:)         # inline: cheap, durable (§2)
  MyApp::WebhookJob.perform_later(account_id: post.account_id,        # enqueued: slow/external
                                  event: "post.created", payload: post.as_json)
  MyApp::PostMailer.published(post).deliver_later                     # enqueued
  Rails.cache.delete("account:#{post.account_id}:post_count")        # bust the cache key

  Success(post)
end
```

| Side effect | How |
|-------------|-----|
| Audit log | `MyApp::Audit.record(...)` inline after commit (§2) — cheap, must not be lost |
| Webhook dispatch | `MyApp::WebhookJob.perform_later(account_id:, event:, payload:)` |
| Notification email | `Mailer#...#deliver_later` (enqueues a job) |
| Cache invalidation | `Rails.cache.delete(...)` / bust the key |

Run side effects **after** the transaction commits — after the `transaction` block as
above, or from an `after_commit` callback on the model — so nothing reacts to a write
that later rolls back.

> **When direct calls stop scaling.** If one mutation accretes many unrelated side
> effects, or the same effect is needed after several different mutations, an
> in-process pub/sub bus
> ([`ActiveSupport::Notifications`](https://guides.rubyonrails.org/active_support_instrumentation.html))
> is a reasonable refactor — the mutation broadcasts, handlers react. Reach for it when
> the duplication is real, not as the default; for most services a direct call is
> simpler to read and to test.

---

## 6. Idempotency Keys on External Mutations

Every call that mutates state in a third party (charge, send, provision) carries an
idempotency key so a retry never double-applies. The key is **deterministic**,
derived from the operation — **never random** (a random key defeats the purpose on
retry).

```
operation:tenant:resource:date_bucket
# e.g. "invoice.charge:acct_42:inv_9001:2026-06-01"
```

```ruby
key = "invoice.charge:#{account.id}:#{invoice.id}:#{Date.current}"
Stripe::Charge.create({ amount:, currency: "usd" }, idempotency_key: key)
```

- ✅ deterministic — the same logical operation retried produces the same key.
- ❌ `idempotency_key: SecureRandom.uuid` — a retry generates a new key and charges twice.

Choose the `date_bucket` granularity to match how often the operation may *legitimately*
repeat (daily invoice → date; one-shot signup bonus → omit the bucket).

---

## 7. Feature Flags

Gate plan-tier features and rollouts behind **Flipper**, enabled per actor, group,
or percentage — not by sprinkling `if account.plan == "pro"` through the code.
([flipper](https://github.com/flippercloud/flipper), `gem "flipper", "~> 1.3"`)

```ruby
Flipper.enabled?(:new_editor, Current.user)          # per-actor
Flipper.enable_percentage_of_actors(:new_editor, 25) # gradual rollout
Flipper.enable_group(:beta_export, :pro_accounts)    # by group
```

- ✅ `return Failure([:feature_not_enabled]) unless Flipper.enabled?(:export, account)`
- ❌ hardcoded plan checks scattered across services and views.

---

## 8. Request Context (`Current` Attributes)

Per-request context (current user, account/tenant, request id, ip) lives in a
context object so it is available everywhere without threading it through every
method signature. **It must be reset per request** to avoid leaking state across
requests on a reused thread/fiber.

> **Scope ≠ authorization.** `Current` defines the *data boundary* (which tenant's
> rows you may even see). *Whether this actor may perform this action* is Pundit's
> job (its own doc). Never use `Current` as an authorization check.

([CurrentAttributes](https://api.rubyonrails.org/classes/ActiveSupport/CurrentAttributes.html))

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :account, :request_id, :ip
end

# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  before_action :set_current
  private def set_current
    Current.request_id = request.request_id
    Current.ip         = request.remote_ip
    Current.user       = authenticate!         # after auth resolution
    Current.account    = Current.user&.account # tenant = data boundary
  end
end
```

`CurrentAttributes` is reset automatically between requests by the Rails executor —
do not memoize it across jobs.

---

## 9. Background Jobs Carry the Tenant / Scope Id

Every enqueued job includes the relevant **account/tenant id (and owner id)** in its
args — for fair scheduling, monitoring, and so the worker can re-establish scope.
A platform-wide job (cleanup, aggregation) is the only exception.

**Active Job on Solid Queue**

```ruby
class MyApp::WebhookJob < ApplicationJob
  queue_as :default
  def perform(account_id:, event:, payload:)
    account = Account.find(account_id)   # re-establish data boundary
    Current.account = account
    # ...deliver...
  end
end
MyApp::WebhookJob.perform_later(account_id: account.id, event:, payload:)
```

- ✅ `perform_later(account_id: account.id, post_id: post.id)`
- ❌ `perform_later(post)` with no tenant id, relying on ambient state that does not
  exist inside a worker.

Make jobs **idempotent** and add a **uniqueness** constraint (Solid Queue concurrency
control, or `sidekiq-unique-jobs`) scoped to `account_id + resource_id` where a
duplicate enqueue is possible. Log the `account_id` at the start of `perform`.

---

## 10. Data Export (GDPR / DSAR)

Maintain one service that exports **all records scoped to a tenant, including
soft-deleted ones**. This is the foundation for data-subject-access-request
compliance and account migration.

```ruby
module MyApp
  class ExportAccountData
    def self.call(account)
      {
        account:    account.as_json,
        posts:      account.posts.with_discarded.as_json,
        comments:   account.comments.with_discarded.as_json,
        audit_logs: account.audit_logs.as_json,
        # ...one entry per tenant-scoped table...
      }
    end
  end
end
```

Rules:

- Include soft-deleted rows (`with_discarded`) with their `deleted_at` intact —
  omitting them breaks data portability.
- **Update this service every time you add a tenant-scoped table.** A missing table
  here is a silent compliance gap. A test should assert every tenant-scoped model
  appears in the export.

---

## New-Feature Checklist

When adding a feature, verify:

- [ ] Expected failures are surfaced as values, not control-flow exceptions — a tagged `Result` (the default), or `model.errors`; never a bare bool or raw string error
- [ ] Every `Failure[...]` tag (or error branch) has a controller/route arm **and** a test
- [ ] New user-facing model has `deleted_at` (soft delete); list queries filter it by default
- [ ] New model is scoped to the tenant (`account_id`)
- [ ] List methods accept `page` / `per_page`, clamp `per_page ≤ 100`, return the paginated struct
- [ ] Side effects (audit, webhooks, email, cache bust) run **after the write commits** — inline call for cheap/durable work, enqueued job for slow/external work
- [ ] External mutations carry a **deterministic** idempotency key
- [ ] Plan-tier / rollout behavior is gated behind a Flipper flag
- [ ] Background jobs include `account_id` in args; idempotent + unique where needed
- [ ] `ExportAccountData` updated to include the new tenant-scoped table
- [ ] Authorization is enforced via Pundit (not via `Current`)
- [ ] Every new behavior has a test (per CLAUDE.md)
