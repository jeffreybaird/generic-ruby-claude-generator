# Separation of Concerns — Controllers/Routes vs Service Objects vs Models

Load this file when writing or modifying any controller, Sinatra route, service
object, or model. This is the rule that keeps the codebase ready for a JSON API,
a background worker, a CLI, or any future caller of the same logic.

> **Baseline:** Ruby 3.3+ · Rails 8 / Sinatra 4. Skinny controllers/routes → service objects (Result types) + models. Request context via Current attributes; authorization via Pundit.

---

## The Rule

**Controllers and routes are thin adapters. Service objects are the application.**

A controller action / route block's job is:

1. Parse and whitelist params (`params.expect`/strong params in Rails; `params` in Sinatra).
2. Call **one** service object (or one trivial model query for a plain read).
3. Pattern-match the Result.
4. Set flash/status, then render or redirect.

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
| **Controllers (Rails) / routes (Sinatra)** | Parse + whitelist params; call ONE service (or a scoped model read for trivial reads); pattern-match the Result; set flash/status; render/redirect. | Business rules; raw queries; multi-step orchestration; external API calls; authorization logic inline. |
| **Service objects** `app/services/MyApp::Posts::Publish` (Rails) / `lib/my_app/posts/publish.rb` (Sinatra), a `call` returning a Result | Business rules; authorization checks (via Pundit); multi-step atomic ops (wrap in `ActiveRecord::Base.transaction`); external API calls; event publishing; audit logging; returning tagged Results. | Rendering; touching `params`/`session`/`flash`; HTTP concerns. |
| **Models (ActiveRecord)** | Persistence; validations; associations; scopes; record-level invariants. | Cross-aggregate orchestration; external calls; multi-record workflows (no fat models doing service work). |
| **Views / helpers / presenters / ViewComponents** | Formatting only — currency, dates, thumbnail URLs, pluralization. | Business logic; queries; authorization. |

JS/Stimulus controllers are presentation-layer bridges too — thin, no business
logic.

---

## Result type

Service objects return a tagged Result, never a bare boolean or a raised
exception for expected failures. Use a small value object (or a gem like
`dry-monads`'s `Success`/`Failure`). Failures carry a serializable tag so a
future API maps cleanly to HTTP.

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

**Rails**

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

**Sinatra**

```ruby
post "/posts/:id/publish" do
  result = MyApp::Posts::Publish.call(post_id: params[:id], actor: Current.user)
  case result.to_tuple
  in [:ok, post]      then redirect "/posts/#{post.id}"
  in [:error, :not_ready] then halt 422, "Post must be ready to publish."
  in [:error, :forbidden] then halt 403
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
      ActiveRecord::Base.transaction do
        post = @account.posts.create!(@attrs)
        FeaturedCollection.current.collection_posts.create!(post:)
        post.update!(published: true)
        publish_event(:post_published, post)        # see architecture-decisions.md
        audit(@actor, :quick_publish, post)
        Success(post)
      end
    rescue ActiveRecord::RecordInvalid => e
      Failure([:validation, e.record.errors])       # transaction already rolled back
    rescue Pundit::NotAuthorizedError
      Failure([:forbidden])
    end
  end
end
```

Publish events and dispatch side effects **after** the transaction commits
(here, the call returns the committed record; emit out-of-band side effects via
`after_commit` or an enqueued job), so a subscriber never reacts to a write that
later rolls back.

---

## Service-object creation workflow

When an audit or a new feature needs something no service supports, build the
service **first** — never put logic in the controller "temporarily."

1. **Define** the class: `MyApp::<Context>::<Verb>` with a class-level `call`
   delegating to an instance.
2. **Implement**: authorization (Pundit), business rules, `ActiveRecord::Base.transaction`
   for multi-step writes, external calls, event publish, audit, returning a Result.
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
Set it once in a `before_action` (Rails) or `before` filter (Sinatra); reset per
request (Rails resets `Current` automatically between requests).

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

## Sinatra specifics

- Route blocks in `app.rb` / `routes/*.rb` stay thin: parse `params`, call one
  service in `lib/my_app/**`, match the Result, set status/body.
- **No ActiveRecord in a route block.** Domain logic lives in `lib/my_app/`,
  the same service objects a Rails app would use.
- Cross-cutting concerns (auth, request id, logging, rate limiting) belong in
  **Rack middleware**, not repeated in route blocks
  ([Sinatra README — Rack middleware](https://sinatrarb.com/intro.html#rack-middleware)).
- `Current` works the same via `ActiveSupport::CurrentAttributes`; set it in a
  `before` filter and reset it in an `after` filter (Sinatra has no automatic
  per-request reset).

```ruby
# ✅ Sinatra route stays an adapter
post "/posts" do
  result = MyApp::Posts::Create.call(account: Current.account, actor: Current.user, attrs: params[:post])
  case result.to_tuple
  in [:ok, post]               then status 201; json post
  in [:error, :validation, e]  then status 422; json(errors: e)
  in [:error, :forbidden]      then halt 403
  end
end
```

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

- `architecture-decisions.md` — Result/error tags, audit logging, soft deletes, pagination, event publishing
- `external-service-integration.md` — client wrapper pattern for third-party APIs
- `testing.md` — RSpec/Minitest patterns, factories, mocks, request specs
- `multi-tenancy.md` — tenant scoping and query patterns (if applicable)
