# Architecture Decisions

Load this file when creating a new model/migration, a service object, or any
system infrastructure. These are decisions made early to avoid costly retrofits
later. Follow them in all new code.

> **Baseline:** Ruby 3.3+ · Rails 8.0 (Hotwire, Propshaft, importmap, Solid
> Queue/Cache/Cable, Kamal 2, Tailwind) · Sinatra 4 (Rack, Puma) · PostgreSQL.
> Domain logic in service objects returning Result types; request context via
> Current attributes; authorization via Pundit.

**Dual-framework reading guide.** Rails 8 is batteries-included; Sinatra 4 is
minimal Rack and you assemble the pieces yourself. Where the two differ, the
section splits **Rails** vs **Sinatra**. Where they are identical, it is stated
once. Sinatra notes assume you have pulled in `activesupport` (~> 8.0) and an ORM
(ActiveRecord, Sequel, or ROM); several Rails-native facilities below do not
exist in Sinatra and must be added.

| Topic | Rails 8 | Sinatra 4 |
|-------|---------|-----------|
| Result type | identical (`dry-monads` or hand-rolled) | identical |
| Audit log | `audited`/`paper_trail` **or** event subscriber | event subscriber (hand-rolled) |
| Soft delete | `discard` gem | `deleted_at` column + scope helper |
| Pagination | Pagy or Kaminari | Pagy (Kaminari is AR/Rails-only) |
| Events | `ActiveSupport::Notifications` (built in) | `ActiveSupport::Notifications` (via `activesupport`) |
| Idempotency keys | identical | identical |
| Feature flags | Flipper | Flipper |
| Request context | `ActiveSupport::CurrentAttributes` | per-request object in Rack `env` |
| Job tenant id | Active Job / Solid Queue arg | Sidekiq/`sucker_punch` arg |
| Data export | identical service object | identical service object |

---

## 1. Result / Tagged-Error Pattern

Service objects return an **explicit Result**, never a bare boolean and never an
exception used for control flow. The Result carries a tagged error so the caller
knows the failure *kind* without inspecting a string. This is the Ruby analog of
Elixir's tagged tuples, and it prepares the domain layer for a future public API
without a rewrite.

**Reserve `raise` for the truly exceptional** — programmer error, unreachable
state, infrastructure down. Expected, recoverable outcomes (not found, invalid
input, over a plan limit) are *values*, not exceptions.

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
          ActiveSupport::Notifications.instrument("my_app.post.created", post: post, actor: actor)
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

**Rails controller**

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

**Sinatra route** (same Result, same `case/in`)

```ruby
post "/posts" do
  case MyApp::Posts::Create.call(account: current.account, actor: current.user, attrs: params[:post])
  in Success(post)             then redirect "/posts/#{post.id}"
  in Failure[:validation, e]   then status 422; erb :new, locals: { errors: e }
  in Failure[:forbidden]       then halt 403
  in Failure[:not_found]       then halt 404
  in Failure[:unauthenticated] then halt 401
  in Failure[code, *]          then halt 422
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

### Rails — gem or subscriber

- **Gem path:** `audited` (~> 5) for a single `audits` table across models, or
  `paper_trail` for full versioning/diffing.
  ([audited](https://github.com/collectiveidea/audited),
  [paper_trail](https://github.com/paper-trail-gem/paper_trail))
- **Preferred (per §5):** an event subscriber, so audit is a *reaction* to a
  published event rather than logic inlined in the model. This keeps the mutation
  path clean and makes audit one of several independent side effects.

```ruby
# config/initializers/audit_subscriber.rb
ActiveSupport::Notifications.subscribe(/\Amy_app\.\w+\.\w+\z/) do |name, _start, _finish, _id, payload|
  resource = payload[:post] || payload[:resource]
  MyApp::AuditLog.create!(
    actor_id:      Current.user&.id,
    account_id:    Current.account&.id,
    action:        name.delete_prefix("my_app."),     # "post.created"
    resource_type: resource.class.name,
    resource_id:   resource.id,
    changes:       resource.try(:saved_changes) || {},
    request_id:    Current.request_id,
    ip:            Current.ip
  )
end
```

### Sinatra — subscriber (no AR callback magic)

No `audited`/`paper_trail` (they hook ActiveRecord internals). Subscribe to the
same `ActiveSupport::Notifications` topic and insert an audit row via your ORM.
The actor/account/request_id come from the per-request context (§8), not the event
payload.

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

### Rails — `discard` gem

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
# delete = discard + event (drives audit "post.deleted")
post.discard
ActiveSupport::Notifications.instrument("my_app.post.deleted", post:)
```

> Be deliberate with `default_scope`: it applies to associations too. The common
> alternative is **no default scope**, calling `.kept` explicitly in every finder —
> safer but easy to forget. Pick one project-wide and document it.

### Sinatra — column + helper

Add a `deleted_at` migration. Provide a query helper rather than relying on a gem.

```ruby
# Sequel
class Post < Sequel::Model
  dataset_module do
    def kept           = where(deleted_at: nil)
    def with_discarded = self
  end
  def discard = update(deleted_at: Time.now)
end
# Every list query starts from Post.kept; admin/export uses Post.with_discarded.
```

Restoration sets `deleted_at` back to `nil` and emits `post.restored`.

---

## 4. Pagination on Every List

Every method returning a collection accepts `page` and `per_page`
(**default 25, max 100**) and returns a consistent paginated result — even if the
current UI shows everything.

### Default: Pagy

Community default — fastest, lowest memory, framework-agnostic (works in both
Rails and Sinatra). ([pagy](https://github.com/ddnexus/pagy), `gem "pagy", "~> 43.0"`)

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

`gem "kaminari"` — ActiveRecord/Rails-only (relies on AR relations), not usable on
Sinatra + Sequel/ROM. Use only in a Rails-only project that already standardized on
it. ([kaminari](https://github.com/kaminari/kaminari))

---

## 5. Event-Driven Side Effects, Not Inline

A mutation **publishes an event**; subscribers react. A new side effect is a **new
subscriber**, never an edit to the mutating service. Subscribers that do real work
(webhooks, email, third-party sync) **enqueue a background job** for reliable,
retryable delivery — they do not call out synchronously inside the request.

```ruby
# Mutation publishes (one line, no side effects inlined):
ActiveSupport::Notifications.instrument("my_app.post.created", post:, actor: Current.user)
```

([ActiveSupport::Notifications](https://guides.rubyonrails.org/active_support_instrumentation.html))

| Side effect | Subscriber does |
|-------------|-----------------|
| Audit log | insert audit row synchronously (§2) — cheap, must not be lost |
| Webhook dispatch | `MyApp::WebhookJob.perform_later(account_id:, event:, payload:)` |
| Notification email | enqueue mailer job |
| Cache invalidation | `Rails.cache.delete_matched(...)` / bust key |

```ruby
ActiveSupport::Notifications.subscribe("my_app.post.created") do |*, payload|
  MyApp::WebhookJob.perform_later(account_id: payload[:post].account_id,
                                  event: "post.created",
                                  payload: payload[:post].as_json)
end
```

- ✅ `Posts::Create` publishes one event; audit, webhook, email are separate subscribers.
- ❌ `Posts::Create` calling `AuditLog.create!` *and* `Webhook.post` *and*
  `Mailer.deliver` inline — every new effect now edits the service.

**Rails:** `ActiveSupport::Notifications` is built in. **Sinatra:** identical API,
available once `activesupport` is required; register subscribers at boot.

> Naming: `my_app.<resource>.<verb>`, matching the audit `action`. Keep the
> instrument payload small (the record + actor), not preloaded association trees.

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

Identical in Rails and Sinatra (Flipper is Rack-based; mount the optional Flipper UI
as Rack middleware in either).

---

## 8. Request Context (`Current` Attributes)

Per-request context (current user, account/tenant, request id, ip) lives in a
context object so it is available everywhere without threading it through every
method signature. **It must be reset per request** to avoid leaking state across
requests on a reused thread/fiber.

> **Scope ≠ authorization.** `Current` defines the *data boundary* (which tenant's
> rows you may even see). *Whether this actor may perform this action* is Pundit's
> job (its own doc). Never use `Current` as an authorization check.

### Rails — `ActiveSupport::CurrentAttributes`

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

### Sinatra — per-request object via middleware

No `CurrentAttributes` reset machinery. Build a per-request context, store it in the
Rack `env` (or a thread-local you explicitly clear in an `after` filter), and reset
it every request.

```ruby
class MyApp::RequestContext < Struct.new(:user, :account, :request_id, :ip)
  def self.current = Thread.current[:my_app_ctx]
end

before do
  Thread.current[:my_app_ctx] =
    MyApp::RequestContext.new(current_user, current_account, request.env["action_dispatch.request_id"] || SecureRandom.uuid, request.ip)
end
after { Thread.current[:my_app_ctx] = nil }   # mandatory: prevent cross-request leak
```

The audit subscriber (§2) reads actor/account/request_id/ip from here, so individual
services never pass request metadata.

---

## 9. Background Jobs Carry the Tenant / Scope Id

Every enqueued job includes the relevant **account/tenant id (and owner id)** in its
args — for fair scheduling, monitoring, and so the worker can re-establish scope.
A platform-wide job (cleanup, aggregation) is the only exception.

**Rails — Active Job on Solid Queue**

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

**Sinatra — Sidekiq / sucker_punch**: same rule, tenant id is the first arg.

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
- Identical in Rails and Sinatra.

---

## New-Feature Checklist

When adding a feature, verify:

- [ ] Service object returns a tagged `Result` (`Success`/`Failure[...]`), never a bare bool or string error
- [ ] Every `Failure[...]` tag has a controller/route arm **and** a test
- [ ] New user-facing model has `deleted_at` (soft delete); list queries filter it by default
- [ ] New model is scoped to the tenant (`account_id`)
- [ ] List methods accept `page` / `per_page`, clamp `per_page ≤ 100`, return the paginated struct
- [ ] Mutations **publish an event**; side effects are subscribers, not inline
- [ ] External mutations carry a **deterministic** idempotency key
- [ ] Plan-tier / rollout behavior is gated behind a Flipper flag
- [ ] Background jobs include `account_id` in args; idempotent + unique where needed
- [ ] `ExportAccountData` updated to include the new tenant-scoped table
- [ ] Authorization is enforced via Pundit (not via `Current`)
- [ ] Every new behavior has a test (per CLAUDE.md)
