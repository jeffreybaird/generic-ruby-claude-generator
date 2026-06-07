# Separation of Concerns — Controllers/Routes vs Service Objects vs Models

Load this file when writing or modifying any controller, service object, or
model. This is the rule that keeps the codebase ready for a JSON API, a
background worker, a CLI, or any future caller of the same logic.

> **Baseline:** Ruby 3.3+ · Rails 8. Skinny controllers → domain logic in service objects (the default for non-trivial work) or models. Request context via Current attributes; authorization via Pundit.

---

## The Rule

**Controllers and routes are thin adapters; the domain logic lives behind them.**

A controller action / route block's job is:

1. Parse and whitelist params (`params.expect`/strong params).
2. Invoke the domain layer — a service object for anything non-trivial, or a model
   method / scoped query for a plain CRUD action.
3. Inspect the outcome (pattern-match a Result, or check `record.errors`).
4. Set flash/status, then render or redirect.

Where the domain logic lives is a judgment call. A service object is the right home
when an operation spans multiple models, has side effects, or must be callable from
more than one entry point (web, API, job, CLI). For a plain create/update/destroy,
idiomatic Rails — a model method, a scope, the controller coordinating a single
`save`/`update` — is perfectly fine; don't wrap a one-line save in a ceremonial
service. The line that matters is the one below: business *rules* and orchestration
don't live in the controller.

A controller/route must NEVER:

- Issue raw SQL or build ad-hoc query chains beyond a single named scope.
- Contain business rules (domain validation, authorization, state machine logic).
- Run multi-step writes (two+ `save`/`update` calls that should be atomic).
- Call external APIs directly.
- Aggregate/transform data that another caller (API, worker, CLI) would also need.

**The test:** could a JSON API endpoint or an Active Job perform this same
operation by calling the **same service object** with the same arguments? If no —
because the logic is trapped in the controller — the separation is broken.

This mirrors the Rails guides' "skinny controller" guidance: controllers
coordinate, they don't compute
([Action Controller Overview](https://guides.rubyonrails.org/action_controller_overview.html)).
The service-object layer is the long-standing community pattern for "where the
business logic goes"
([thoughtbot, "Skinny Controllers, Skinny Models"](https://thoughtbot.com/blog/skinny-controllers-skinny-models)).

---

## Layer responsibilities

| Layer | Owns | Never does |
|---|---|---|
| **Controllers** | Parse + whitelist params; invoke the domain layer (a service for non-trivial work, or a model method/scope for trivial CRUD); inspect the outcome (Result or `record.errors`); set flash/status; render/redirect. | Business rules; raw queries; multi-step orchestration; external API calls; authorization logic inline. |
| **Service objects** `app/services/MyApp::Posts::Publish`, a `call` returning a Result | Business rules; authorization checks (via Pundit); multi-step atomic ops (wrap in `ActiveRecord::Base.transaction`); external API calls; side effects after commit (audit, enqueued jobs, cache busting); returning a Result (or another explicit outcome). | Rendering; touching `params`/`session`/`flash`; HTTP concerns. |
| **Models (ActiveRecord)** | Persistence; validations; associations; scopes; record-level invariants. | Cross-aggregate orchestration; external calls; multi-record workflows (no fat models doing service work). |
| **Views / helpers / presenters / ViewComponents** | Formatting only — currency, dates, thumbnail URLs, pluralization. | Business logic; queries; authorization. |

JS/Stimulus controllers are presentation-layer bridges too — thin, no business
logic.

---

## Result type

The template's default is for service objects to return a tagged Result rather than
a bare boolean or a raised exception for expected failures. Use a small value object
(or a gem like `dry-monads`'s `Success`/`Failure`). Failures carry a serializable tag
so a future API maps cleanly to HTTP. (For simple single-model actions, returning the
record and reading `record.errors` is a fine alternative — see
`architecture-decisions.md` §1. The rule that doesn't bend: expected failures are
explicit outcomes, never a bare boolean or a raw error string.)

```ruby
Success(post)
Failure([:validation, changeset_errors])   # e.g. record.errors
Failure([:not_found])
Failure([:forbidden])
Failure([:not_ready])
Failure([:plan_limit_reached, { limit: n, current: m }])
Failure([:external_service_error, details])
```

Never return a string error message from a service — use tagged symbols so
callers branch on `:not_ready`, not on prose.

---

## What belongs where — by example

### ✅ Controller: parse, call one service, match Result <span title="stable">`[stable]`</span>

```ruby
class PostsController < ApplicationController
  def publish
    case MyApp::Posts::Publish.call(post_id: params[:id], actor: Current.user).result
    in [:ok, post]
      redirect_to post_path(post), notice: "Published."
    in [:error, :not_ready]
      redirect_to post_path(params[:id]), alert: "Post must be ready to publish."
    in [:error, :forbidden]
      head :forbidden
    end
  end
end
```

### ✅ Controller: trivial read straight from a scoped model query <span title="stable">`[stable]`</span>

```ruby
def index
  @posts = Current.account.posts.published.page(params[:page])  # one scoped read, fine
end
```

A single named scope on the current-account association is acceptable in a
controller. The moment it needs joins, conditionals, or aggregation, extract a
**query object** (`app/queries/MyApp::Posts::FeedQuery`).

---

## ✅/❌ Violation → fix

### Business rule in the controller

```ruby
# ❌ "can only publish if ready" is a domain rule
def publish
  post = Current.account.posts.find(params[:id])
  if post.status == "ready"
    post.update!(published: true)
    redirect_to post, notice: "Published."
  else
    redirect_to post, alert: "Post must be ready."
  end
end
```

```ruby
# ✅ rule lives in the service; controller only matches the Result
def publish
  case MyApp::Posts::Publish.call(post_id: params[:id], actor: Current.user).result
  in [:ok, post]          then redirect_to post, notice: "Published."
  in [:error, :not_ready] then redirect_to post_path(params[:id]), alert: "Post must be ready."
  end
end
```

The service returns `Failure([:not_ready])` when `status != "ready"`.

### Raw query in the controller

```ruby
# ❌ ad-hoc query building in the action
def index
  @posts = Post.where(account_id: Current.account.id)
               .where(deleted_at: nil)
               .order(created_at: :desc)
end
```

```ruby
# ✅ a model scope (or query object) owns the query shape
class Post < ApplicationRecord
  scope :kept,  -> { where(deleted_at: nil) }
  scope :recent, -> { order(created_at: :desc) }
end

def index
  @posts = Current.account.posts.kept.recent.page(params[:page])
end
```

### Multiple saves in one action

```ruby
# ❌ three writes that must be atomic, scattered in the controller
def quick_publish
  post = Current.account.posts.create!(post_params)
  FeaturedCollection.current.collection_posts.create!(post:)
  post.update!(published: true)
  redirect_to post
end
```

```ruby
# ✅ one service wraps them in a transaction and returns a Result
module MyApp::Posts
  class QuickPublish
    def self.call(...) = new(...).call

    def initialize(account:, actor:, attrs:)
      @account, @actor, @attrs = account, actor, attrs
    end

    def call
      authorize!(@actor, :create, Post)             # Pundit
      post = ActiveRecord::Base.transaction do
        p = @account.posts.create!(@attrs)
        FeaturedCollection.current.collection_posts.create!(post: p)
        p.update!(published: true)
        p
      end
      # after commit — side effects called directly (see architecture-decisions.md §5)
      MyApp::Audit.record("post.published", resource: post, actor: @actor)
      Success(post)
    rescue ActiveRecord::RecordInvalid => e
      Failure([:validation, e.record.errors])       # transaction already rolled back
    rescue Pundit::NotAuthorizedError
      Failure([:forbidden])
    end
  end
end
```

Run side effects **after** the transaction commits — as above (the record is
returned from the `transaction` block, then side effects run against it), or via an
`after_commit` callback or an enqueued job — so nothing reacts to a write that later
rolls back.

---

## Service-object creation workflow

When an audit or a new feature needs something no service supports, build the
service **first** — never put logic in the controller "temporarily."

1. **Define** the class: `MyApp::<Context>::<Verb>` with a class-level `call`
   delegating to an instance.
2. **Implement**: authorization (Pundit), business rules, `ActiveRecord::Base.transaction`
   for multi-step writes, external calls, side effects after commit (audit, jobs),
   returning a Result.
3. **Spec it**: cover the happy path and every `Failure` branch (`:not_ready`,
   `:forbidden`, `:validation`, …). Every behavior gets a test.
4. **THEN call it** from the controller/route and match the Result.

Temporary controller logic becomes permanent debt the moment you add a JSON API
or a worker.

---

## Request-scoped data via `Current`

Use Rails'
[`ActiveSupport::CurrentAttributes`](https://api.rubyonrails.org/classes/ActiveSupport/CurrentAttributes.html)
for request context — `Current.account`, `Current.user`, `Current.request_id`.
Set it once in a `before_action`; reset per request (Rails resets `Current`
automatically between requests).

```ruby
class Current < ActiveSupport::CurrentAttributes
  attribute :account, :user, :request_id
end
```

- **Controllers/routes** populate `Current` from the session/token. They never
  build tenant filters themselves.
- **Services and models** read scope through the current-account association
  (`Current.account.posts`) — the scope filter lives here.
- **For testability**, prefer passing the actor/account as explicit args to a
  service (`Publish.call(actor:, account:, ...)`) and reading `Current` only at
  the controller boundary, so specs can call the service without a global. A
  service may read `Current` directly when an explicit arg would be pure
  ceremony — but keep it consistent within a context.

```ruby
# ❌ controller hand-rolls the tenant filter
@posts = Post.where(account_id: Current.account.id)

# ✅ scope rides the association; the model/service owns the boundary
@posts = Current.account.posts.kept
```

Authorization is separate from scoping: scope answers *which rows is this actor
allowed to see*; Pundit policies answer *is this actor allowed to do this*
([Pundit](https://github.com/varvet/pundit)). Both belong in the service layer,
not the controller — the service applies the scope and calls `authorize`,
returning `Failure([:forbidden])` when denied.

---

## Patterns for when it gets complex

- **Query objects** (`app/queries/` or `lib/my_app/queries/`): when a read needs
  joins, conditional filters, or aggregation beyond a single scope. Controllers
  and services call the query object; neither builds the chain inline.
- **Form objects**: when a single submission spans multiple models or needs
  validations that don't belong on any one record. The form object validates and
  hands clean attrs to a service.

---

## Controller / route audit checklist

Before committing changes to any controller action or route block:

- [ ] No raw SQL / ad-hoc query chains (single named scope on a scoped
      association is OK).
- [ ] No business-rule conditionals (`if post.status == ...`).
- [ ] No multi-step saves/updates (extract to a service + `transaction`).
- [ ] No direct external API calls.
- [ ] No hand-rolled tenant filter (`where(account_id: ...)`) — scope rides the
      association.
- [ ] No inline authorization logic — Pundit policy via the service.
- [ ] Every service called exists and is spec'd (happy path + every `Failure`).
- [ ] Every Result branch is handled (no unmatched `case`/`in`).

---

## Related docs

- `architecture-decisions.md` — Result/error tags, audit logging, soft deletes, pagination, side effects after commit
- `external-service-integration.md` — client wrapper pattern for third-party APIs
- `testing.md` — RSpec/Minitest patterns, factories, mocks, request specs
- `multi-tenancy.md` — tenant scoping and query patterns (if applicable)
