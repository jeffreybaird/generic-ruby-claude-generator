# Scalability

Load this file when building any feature that handles end-user-facing traffic,
writes high-frequency data, or introduces new database queries. Build every
feature assuming the platform will eventually serve a large number of concurrent
users.

We don't need to handle that load today. We need to make decisions today that
don't prevent us from handling it later.

> **Baseline:** Ruby 3.3+ · Rails 8.0 (Hotwire, Solid Queue/Cache/Cable, Kamal 2) · PostgreSQL. Domain logic in service objects; request context via Current attributes.

**Maturity tags** used below: `[Rails 8 default]` ships in a stock Rails 8 app ·
`[Stable]` mature, widely-run gem · `[Optional]` reach for it only when you
outgrow the default. Gem pins are **loose** (`~> X.Y`) — track the latest
compatible release.

---

## Guiding Principle

External services (a media provider, a payment provider, an object store) handle
their respective heavy lifting. Your infrastructure handles everything around
them: authentication, session management, page rendering, event tracking,
activity feeds, and the admin dashboard. Design every feature knowing
high-concurrency users will hit your database, your realtime connections, your
caches, and your background job queues.

### Request context: Current attributes, not globals

Domain logic lives in **service objects** (and ActiveRecord scopes), never inline
in controllers/routes. The current actor and tenant boundary travel via
**`Current` attributes** ([`ActiveSupport::CurrentAttributes`](https://api.rubyonrails.org/classes/ActiveSupport/CurrentAttributes.html)),
not thread-globals or method-threaded `scope` args.

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :account
end

# set once per request (before_action), reset automatically after
Current.account = resolved_account
Current.user    = authenticated_user
```

The **tenant boundary is explicit** and every tenant-scoped query filters on it
(see Tenant Isolation, below). Scoping is a *data boundary* (which rows a query
may touch) — keep it distinct from *authorization* (which actions a user may
perform); gate actions with Pundit/Action Policy separately.

---

## 1. Protect Postgres from the Hot Path

### Never write high-frequency data directly to the DB, row by row

Any operation firing more than once per user per minute must not do a per-event
`INSERT`/`UPDATE`. Batch it.

**High-frequency examples:** progress/position tracking, analytics/activity
events (play, pause, seek, complete), heartbeat pings, view/like counters.

**Two batching strategies:**

| Strategy | Use when | Mechanism |
|---|---|---|
| **Buffer → flush** | Append-only events you can lose a few seconds of on crash | Push to Redis (list/stream); a recurring job drains and bulk-inserts |
| **Counters in Redis** | Monotonic counts (views, likes, plays) | `INCR`/`HINCRBY` in Redis; periodic job reconciles to Postgres |
| **Bulk insert** | You already hold N rows in memory | [`activerecord-import`](https://github.com/zdennis/activerecord-import) `import` — one multi-row `INSERT` |

### Provide a buffer abstraction

Callers never know whether a write was buffered or direct — same interface. The
default impl is Redis-backed; the interface lets you swap to Kafka or a
time-series store later without touching callers.

```ruby
# Buffer interface — one queue method, one flush method.
module MyApp
  module Buffer
    def write(key, value); raise NotImplementedError; end  # enqueue, return :ok
    def flush; raise NotImplementedError; end               # drain → bulk insert
  end
end

# Default Redis impl. [Stable] gem: redis ~> 5.0
class MyApp::Buffers::AnalyticsBuffer
  extend MyApp::Buffer
  KEY = "buffer:analytics".freeze

  def self.write(_key, value)
    MyApp.redis.rpush(KEY, value.to_json)
    :ok
  end

  def self.flush
    rows = []
    while (raw = MyApp.redis.lpop(KEY))
      rows << JSON.parse(raw, symbolize_names: true)
    end
    # ✅ one multi-row INSERT, not N inserts — activerecord-import
    AnalyticsEvent.import(rows, validate: false) unless rows.empty?
    :ok
  end
end
```

```ruby
# ❌ WRONG — one insert per event in the hot path
def record_view(resource)
  AnalyticsEvent.create!(account_id: Current.account.id, resource_id: resource.id)
end

# ✅ CORRECT — buffer; a recurring job flushes
def record_view(resource)
  MyApp::Buffers::AnalyticsBuffer.write(:resource_view, {
    account_id: Current.account.id, user_id: Current.user.id,
    resource_id: resource.id, occurred_at: Time.current
  })
end
```

**Flush job.** Schedule the drain on a short interval. A recurring
`[Rails 8 default]` Solid Queue job (`config/recurring.yml`) calls
`MyApp::Buffers::AnalyticsBuffer.flush` every 30s. Or `ActiveJob` on Sidekiq
with the sidekiq-scheduler gem.

**Counters:** never `UPDATE counters SET n = n + 1` per event (row-lock
contention). `INCR` in Redis; reconcile periodically.

```ruby
MyApp.redis.hincrby("views:account:#{Current.account.id}", resource.id, 1)  # hot path
# recurring job: read the hash, bulk-update Postgres, reset
```

> **Rule:** any write firing >1×/user/minute goes through a buffer or Redis
> counter. Losing the last few seconds on a crash is acceptable for analytics;
> business-critical effects use the durable job path (§6), not the buffer.

---

## 2. Separate Read and Write Paths (for future replicas)

Structure service objects and scopes so **reads can route to a replica** and
**writes hit the primary**. Don't mix reads and writes in one method unless
transactional consistency requires it. This makes replica routing a config
change, not a rewrite.

### Multi-database

Rails ships first-class multi-DB ([Rails multi-db guide](https://guides.rubyonrails.org/active_record_multiple_databases.html)):

```ruby
# config/database.yml — primary + replica
production:
  primary:         { <<: *default, url: <%= ENV["DATABASE_URL"] %> }
  primary_replica: { <<: *default, url: <%= ENV["REPLICA_URL"] %>, replica: true }

# app/models/application_record.rb
class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :primary, reading: :primary_replica }
end
```

```ruby
# ✅ pure read — safe to run against the replica
def recent_posts
  ActiveRecord::Base.connected_to(role: :reading) do
    Post.where(account_id: Current.account.id).order(created_at: :desc).limit(25).to_a
  end
end

# ❌ AVOID — read+write in one method forces the primary for everything
def create_post_and_return_feed(attrs)
  post = Post.create!(attrs)          # write → primary
  feed = recent_posts                 # this read now also runs on primary
  [post, feed]
end
```

Rails can also switch automatically via
[`ActiveRecord::Middleware::DatabaseSelector`](https://guides.rubyonrails.org/active_record_multiple_databases.html#activating-automatic-role-switching)
(reads → replica, writes → primary, recent writers pinned to primary). Until you
add a replica, point `reading` at the primary — zero code change later.

> Don't implement replicas today. Just keep reads and writes in separate methods
> so adding one is routing, not rework.

---

## 3. Indexing

Every query in the end-user hot path must be backed by an index.

| Table shape | Required index |
|---|---|
| Any tenant-scoped table | `account_id` |
| Listing query (sorted) | composite `[account_id, created_at]` |
| User-scoped lookup (favorites, progress, subs) | composite `[account_id, user_id]` |
| Lookup by slug/handle | `[account_id, slug]` (unique where appropriate) |

- **Composite tenant indexes lead with `account_id`** — it's in every `WHERE`.
- **Verify with `EXPLAIN ANALYZE`** in dev for each new hot-path query. Treat a
  sequential scan on any table >1000 rows as a bug.
- `add_index :posts, [:account_id, :created_at]`.

```sql
EXPLAIN ANALYZE SELECT * FROM posts
WHERE account_id = 42 ORDER BY created_at DESC LIMIT 25;
-- want: Index Scan using index_posts_on_account_id_and_created_at
```

---

## 4. Minimize Heavy Client Connections

This template defaults to **server-rendered HTML with minimal JS**, and that's the
cheaper path at scale: each persistent realtime socket holds server resources per
user, so spend them only where realtime is genuinely required. An SPA is a fair
choice when the UI needs rich client state — the cost to watch for either way is
*unnecessary* persistent connections, not the rendering style itself.

### Hotwire first

| Need | Tool | Persistent socket? |
|---|---|---|
| Show/hide, toggles, small client behavior | [Stimulus](https://stimulus.hotwired.dev/) controller on static HTML | **No** |
| Replace part of the page on a request | [Turbo Frames](https://turbo.hotwired.dev/handbook/frames) | **No** (request/response) |
| Server pushes updates to many clients | [Turbo Streams](https://turbo.hotwired.dev/handbook/streams) over Action Cable | **Yes** (one per stream) |

Reserve Action Cable / Turbo Stream subscriptions for genuinely realtime views
(live feed, presence). Static browse/detail/search pages render plain HTML +
Stimulus — no socket.

### Keep payloads lean, kill N+1

```ruby
# ❌ N+1 — one query per post for its author
Post.where(account_id: Current.account.id).each { |p| p.author.name }

# ✅ eager-load with includes
Post.where(account_id: Current.account.id).includes(:author).limit(25)
```

- Never load entire association trees for a list view. Select only the columns
  you render (`select(:id, :title, :slug)`).
- Paginate every list (kaminari/pagy). Never render an unbounded collection.

---

## 5. Caching: The Layer Between Users and Postgres

Data read on every page load but written only on an admin edit must be cached.

| Cache | Examples | Strategy |
|---|---|---|
| **Cache** | tenant resolution (slug→account), theme/branding, layout config, catalog metadata, feature flags, entitlement status | `Rails.cache.fetch` with TTL + invalidation on write |
| **Never cache** | per-user progress/position, analytics (write-only), audit logs (write-only), live connection counts | — |

### Backend decision table

| Backend | When | Maturity |
|---|---|---|
| **Solid Cache** | Rails 8 default; DB-backed, no extra infra; great for large/disk-backed caches | `[Rails 8 default]` ([solid_cache](https://github.com/rails/solid_cache)) |
| **Redis** | Need shared in-memory cache across nodes, or you already run Redis for jobs/buffers | `[Stable]` |
| **Memcached** | Pure volatile LRU, multi-node, simplest semantics | `[Stable]` |

Configure once (`config.cache_store = :solid_cache_store` / `:redis_cache_store`);
callers use the same `Rails.cache` API ([caching guide](https://guides.rubyonrails.org/caching_with_rails.html)).

```ruby
# read-through cache; invalidation on write is primary, TTL is the backstop
def account_theme
  Rails.cache.fetch("theme:#{Current.account.id}", expires_in: 5.minutes) do
    Theme.find_by(account_id: Current.account.id)
  end
end
```

### Fragment / Russian-doll caching for views

Cache rendered view fragments keyed by record + `updated_at`; nested fragments
auto-expire when a child changes ([caching guide](https://guides.rubyonrails.org/caching_with_rails.html#russian-doll-caching)).

```erb
<% cache @account do %>
  <% @account.posts.each do |post| %>
    <% cache post do %><%= render post %><% end %>
  <% end %>
<% end %>
```

### Invalidate on write

The code that mutates the data busts its cache key, right after the change commits —
in the service, or in an `after_commit` callback on the model so it can't be missed.

```ruby
# in the service that updates the theme, after the write commits:
account.update!(theme_attrs)
Rails.cache.delete("theme:#{account.id}")

# or, so no call site can forget it:
class Theme < ApplicationRecord
  after_commit { Rails.cache.delete("theme:#{account_id}") }
end
```

With a shared backend (Solid Cache/Redis), one node's delete is visible
cluster-wide. With per-node in-memory stores, prefer a shared backend or
broadcast invalidation so nodes don't serve stale data.

---

## 6. Realtime / PubSub: Topic Design + the At-Most-Once Caveat

**This is the highest-value rule in this doc.** Broadcasts are **lossy**; jobs
are **durable**. Use each for what it guarantees.

### Broadcast only what multiple processes need

**DO broadcast** (lossy-OK, self-heals on next event/reload):
- Content changes (post published, layout reordered) — viewers on the same
  account see it update
- Admin-dashboard live counters (new subscriber, cancellation)
- Presence / live UI state shared across clients

**DO NOT broadcast:**
- Per-user progress/position (single-session state — nobody else cares)
- Analytics events (→ buffer, §1)
- Per-user UI state (scroll, open accordions, filters)
- Heartbeats

### Delivery guarantee: broadcasts are at-most-once

Turbo Streams / Action Cable (and any pub/sub) deliver **at most once**. A
message is lost if the subscriber crashes mid-handle, a node fails, or a process
restarts after the broadcast. Fine for cache invalidation, live UI, presence.

For **business-critical** side effects (audit log, billing webhooks, anything
that must happen exactly once), **do not** hang the effect off a broadcast
subscriber. Make it durable **at the source**: enqueue the job **inside the same
DB transaction** that commits the write. That gives at-least-once delivery;
idempotency keys dedupe replays.

```ruby
# ✅ CORRECT (Solid Queue — same DB) — job row commits atomically with the write
def publish_post(attrs)
  post = nil
  ApplicationRecord.transaction do
    post = Post.create!(attrs.merge(account_id: Current.account.id))
    AuditJob.perform_later(account_id: Current.account.id, post_id: post.id)
  end
  # AFTER commit: broadcast the lossy-OK live-UI / cache-bust event
  post
end

# ❌ WRONG — audit work hangs off a broadcast subscriber: lost on the dropped hop
# (pseudo-code; an Action Cable `received` handler or Notifications subscriber)
on_broadcast("posts") do |post|
  AuditJob.perform_later(post_id: post.id)  # the broadcast was at-most-once
end
```

> **Enqueue-vs-commit is framework-asymmetric — get this right:**
>
> - **Solid Queue** `[Rails 8 default]` stores jobs in the **same database**.
>   Enqueuing **inside** the AR transaction is atomic — the job row commits (or
>   rolls back) with the write. That's the whole point of a DB-backed queue.
> - **Sidekiq** stores jobs in **Redis**, which is **not** in the AR transaction.
>   Enqueuing inside the transaction is the classic race: a worker can pick up
>   the job before the row commits, or the job gets enqueued even on rollback.
>   With Sidekiq, enqueue from an **`after_commit` callback** or via a
>   **transactional outbox row** — never inside the transaction.

| Consumer | Lossy OK? | How |
|---|---|---|
| Cache invalidation, live UI, presence | Yes | Turbo Stream / Action Cable broadcast |
| Audit log, billing, outbound webhooks | No | Job enqueued in the write's transaction (§7) |

### Topic / channel design

Scope channels to the narrowest useful audience. Prefer hierarchical names.

```ruby
"account:#{account_id}:posts"          # ✅ account-scoped resource stream
"account:#{account_id}:room:#{room_id}" # ✅ hierarchical, specific slice
"user:#{user_id}:notifications"        # ✅ user-scoped (distinct audience)
"all_events"                           # ❌ global, high-frequency
"user:#{user_id}:progress"             # ❌ single-session state — don't broadcast
```

**Authorize in the channel's `subscribed` callback** ([Action Cable guide](https://guides.rubyonrails.org/action_cable_overview.html))
— it's the security boundary. A user may only stream `account:#{id}:…` for an
account their `Current` boundary grants. Never interpolate user-controlled
strings into `stream_from` without an authorization check.

---

## 7. Background Jobs: Separate by Criticality

### Queue hierarchy

```yaml
# config/queue.yml (Solid Queue) or Sidekiq config
production:
  dispatchers: [...]
  workers:
    - { queues: critical, threads: 5 }   # payments, subscription changes
    - { queues: default,  threads: 5 }   # webhooks, notifications, email
    - { queues: bulk,     threads: 3 }   # analytics flush, exports, imports
```

### Rules

- **Never put high-volume work in `critical` or `default`.** Buffer flushes,
  analytics aggregation, and exports go in `bulk`.
- **Payment/subscription jobs go in `critical`.** A `bulk` backlog must never
  delay a payment confirmation.
- **Tag every job with the tenant id** in its args — enables per-tenant
  monitoring and fair scheduling.
- **Set timeouts/retries per queue:** `critical` times out fast and retries
  quickly; `bulk` may run long with slower backoff.
- **Enqueue durable side effects inside the write's transaction** (§6).

```ruby
class AuditJob < ApplicationJob
  queue_as :default
  # always include the tenant id in args
  def perform(account_id:, post_id:); ...; end
end
```

### Backend decision

| Backend | When | Maturity |
|---|---|---|
| **Solid Queue** | Rails 8 default; DB-backed, no Redis needed; recurring jobs built in | `[Rails 8 default]` ([solid_queue](https://github.com/rails/solid_queue)) |
| **Sidekiq** | High throughput, Redis-backed, mature ecosystem | `[Stable]` ([sidekiq](https://github.com/sidekiq/sidekiq)) |

ActiveJob over Solid Queue (default) or Sidekiq — adapter swap, jobs unchanged.

### At scale

Per-tenant fairness: partition by `account_id` so one tenant's bulk import can't
consume all slots (Sidekiq capsules/limits, or separate per-tenant queues). Every
job already carries its tenant id, which makes partitioning possible. Worker
interface stays the same; only queue config changes.

---

## 8. Rate Limiting: Per-Actor Protection

A misbehaving tenant, bot, or attack on one actor must not degrade others.

### Rack::Attack — the canonical gem

[Rack::Attack](https://github.com/rack/rack-attack) `~> 6.7` `[Stable]` is Rack
middleware. Throttle by IP, account, or endpoint; return `429` with
`Retry-After`.

```ruby
# config/initializers/rack_attack.rb
class Rack::Attack
  throttle("req/ip", limit: 200, period: 60) { |req| req.ip }

  throttle("api/account", limit: 100, period: 60) do |req|
    req.env["myapp.account_id"] if req.path.start_with?("/api")
  end

  throttle("logins/ip", limit: 10, period: 60) do |req|
    req.ip if req.path == "/login" && req.post?
  end

  self.throttled_responder = lambda do |req|
    match = req.env["rack.attack.match_data"]
    retry_after = match ? match[:period] : 60
    [429, { "Retry-After" => retry_after.to_s, "Content-Type" => "text/plain" },
     ["Rate limit exceeded\n"]]
  end
end
```

Back the store with Redis (or Solid Cache) so counters are **cluster-wide**; the
default in-memory store gives per-node limits (effective limit × node count).

### Rails 8 also ships controller-level `rate_limit` `[Rails 8 default]`

For coarse per-action limits without middleware, Rails 8 has
[`rate_limit`](https://api.rubyonrails.org/classes/ActionController/RateLimiting/ClassMethods.html)
in controllers:

```ruby
class SessionsController < ApplicationController
  rate_limit to: 10, within: 1.minute, only: :create,
             by: -> { request.remote_ip }, with: -> { head :too_many_requests }
end
```

Use it for simple endpoint guards; reach for Rack::Attack when you need
cross-endpoint rules, blocklists, or fail2ban-style logic.

### Suggested starting limits (generous)

| Route scope | Key | Limit | Period |
|---|---|---|---|
| Public/end-user pages | `account + ip` | 200 | 1 min |
| Public/end-user API | `account + user` | 100 | 1 min |
| Webhook receivers | `ip` | 500 | 1 min |
| Admin pages | `account + user` | 300 | 1 min |
| Auth endpoints | `ip` | 10 | 1 min |

---

## 9. Tenant Isolation Under Load

**One tenant must never degrade another's experience** — the core multi-tenant
scalability rule. If your app isn't multi-tenant, apply it to any shared resource
(queues, cache, DB pool).

| Vector | Risk | Mitigation |
|---|---|---|
| **Database** | One tenant's huge dataset slows others' queries | Composite `[account_id, …]` indexes (§3), pagination, per-statement timeouts (`SET LOCAL statement_timeout`) |
| **Background jobs** | One tenant's bulk import starves others' webhooks | Queue separation (§7) + per-tenant concurrency limits / partitioning |
| **Cache** | One tenant's invalidation storm evicts others' data | **Namespace keys by account** (`theme:#{account_id}`) so eviction is scoped |
| **Realtime** | One tenant's users consume all sockets | Keep public pages socket-free (§4); reserve streams for realtime needs |
| **Rate limits** | One tenant monopolizes throughput | Per-account throttles (§8) |

```ruby
# ✅ tenant-namespaced cache key — scoped eviction
Rails.cache.fetch("account:#{Current.account.id}:layout") { ... }

# ✅ enforce the tenant boundary on every query via Current
Post.where(account_id: Current.account.id)
```

Every tenant-scoped query filters on `Current.account.id`. A `default_scope` or a
shared scope helper (e.g. `for_current_account`) makes the boundary hard to omit
— but keep it as a *data boundary*, with authorization enforced separately.

---

## Checklist for New Features

- [ ] Service objects own domain logic; controllers/routes stay thin
- [ ] Tenant boundary read from `Current`, not globals
- [ ] High-frequency writes go through a buffer or Redis counter, not row-by-row inserts
- [ ] Bulk inserts use `activerecord-import`, not a loop of `create!`
- [ ] Reads and writes are in separate methods (replica-routable later)
- [ ] Every hot-path query has a composite `[account_id, …]` index, verified with `EXPLAIN ANALYZE`
- [ ] List views eager-load (`includes`) and paginate — no N+1, no unbounded loads
- [ ] Public pages render server HTML + minimal JS; sockets reserved for realtime
- [ ] Frequently-read/rarely-written data goes through `Rails.cache` with invalidation on write
- [ ] Cache keys are account-namespaced
- [ ] Broadcasts carry only lossy-OK UI/cache events; business-critical effects enqueue a job inside the write's transaction
- [ ] Channels/topics are narrowly scoped and authorized in `subscribed`
- [ ] Jobs are in the right queue by criticality and tagged with the tenant id
- [ ] Rate limiting (Rack::Attack / Rails `rate_limit`) covers every external-facing route
- [ ] One tenant's usage cannot degrade another's (DB, jobs, cache, sockets, limits)
