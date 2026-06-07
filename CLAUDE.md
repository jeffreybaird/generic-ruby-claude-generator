# CLAUDE.md — Generic Ruby Project (Rails 8)

Claude Code reads this every session. Follow all rules unless the user overrides for a
specific task. This is a **generic template** — replace `MyApp` / `my_app` with your real
module and gem/app names, and adapt the example domain (contexts, models, services) to
yours.

Detail patterns live in `.claude/`. Load the relevant file when working in that area.

### Stack Baseline

Ruby 3.3+ · **Rails 8.0** (Hotwire/Turbo + Stimulus, Propshaft, importmap, Solid
Queue/Cache/Cable, Kamal 2, Tailwind) · PostgreSQL. Key conventions: domain logic in
**service objects returning Result types** (dry-monads), not controllers; request context via
**`Current` attributes** (`Current.user` / `Current.account`) — the data boundary, *not*
authorization; **Pundit** for authorization; **Faraday** for HTTP; background work on
**Solid Queue / Sidekiq**; **RSpec + FactoryBot + Capybara** for tests.

Lean on Rails' generators, conventions, and Rails 8 defaults.

### Core (apply to any Ruby web app)

- `.claude/architecture-decisions.md` — Result/error objects, audit logging, soft deletes, pagination, side effects, feature flags, idempotency
- `.claude/separation-of-concerns.md` — what belongs in a controller/route, a service object, a model, a view
- `.claude/testing.md` — test-as-contract rule, FactoryBot, WebMock/VCR, `data-testid` selectors, system specs
- `.claude/observability.md` — OpenTelemetry, ActiveSupport::Notifications, structured logging
- `.claude/scalability.md` — write buffers, caching, jobs by criticality, Turbo/Action Cable, rate limiting
- `.claude/stimulus-controllers.md` — Hotwire/Stimulus conventions (thin client bridges)
- `.claude/deployment.md` — Kamal 2, Docker, credentials/ENV, migrations, health checks, CI/CD
- `.claude/theming.md` — CSS-variable tokens + optional per-tenant theming
- `.claude/design-system.md` — **template**: document your visual design tokens and tone
- `.claude/frontend-map.md` — **template**: map your routes, controllers, views, components, Stimulus controllers
- `.claude/a11y-audit.md` — WCAG 2.1 AA accessibility audit command

### Optional modules (include only if your app needs them)

- `.claude/multi-tenancy.md` — `account_id` row-level scoping, `Current.account`, test isolation
- `.claude/rbac.md` — authentication, roles on memberships, Pundit authorization
- `.claude/external-service-integration.md` — wrapping any third-party API behind a client class
- `.claude/payment-integration.md` — Stripe billing/subscriptions/checkout
- `.claude/object-storage-integration.md` — Active Storage / S3-compatible blob storage

---

## Project Overview

`MyApp` is a Rails 8 web application. Replace this section with your own overview: what the
app does, who uses it, and the high-level architecture.

### Architecture Summary

- **Interfaces:** typically an internal/admin UI and a public/end-user UI. Adapt to your app.
- **Domain logic:** service objects (`app/services`) that return Result types; models hold
  persistence and invariants.
- **Background jobs:** Solid Queue (Rails 8 default) or Sidekiq, queues split by criticality.
- **External services:** wrapped behind client classes (see
  `.claude/external-service-integration.md`). Never call a vendor SDK directly outside its client.
- **Deployment:** Kamal 2 + Docker on the host of your choice (see `.claude/deployment.md`).

### Domain Modules

Business logic lives in service objects and models. Controllers and routes never embed
business rules or raw queries. Common examples:

| Area            | Responsibility                                            |
|-----------------|-----------------------------------------------------------|
| `Accounts`      | Users, authentication, memberships, invitations, RBAC     |
| `<Domain>`      | Your core domain resources (replace with real services)   |
| `Billing`       | Subscriptions, plans, checkout (if you charge money)      |
| `Notifications` | Email/push notifications, delivery                        |
| `Admin`         | Platform-level / cross-tenant operations (if applicable)  |

---

## Architecture Principles

Apply to every feature, service object, and model. These are rules, not guidelines. Detail
patterns and code live in `.claude/architecture-decisions.md`, `.claude/scalability.md`,
and `.claude/observability.md`.

### 1. Protect Postgres from the Hot Path

Never write high-frequency data directly to Postgres row-by-row (analytics, counters,
progress, heartbeats). Buffer in Redis and flush in batches (`activerecord-import`), or use
atomic Redis counters. The caller uses the same interface regardless.

### 2. Separate Read and Write Paths

Structure so reads can route to a replica and writes to the primary (Rails multi-database
`connects_to` / `connected_to`). Never mix reads and writes in one method unless a
transaction requires it. Replicas then become a config change, not a rewrite.

### 3. Cache Frequently-Read, Infrequently-Written Data

Hot, rarely-changing data (config, metadata, lookups) goes through `Rails.cache` (Solid
Cache / Redis / Memcached). Invalidate on write — the service that mutates the data (or an
`after_commit` callback on the model) busts the cache key once the change commits.

### 4. Keep the Client Lean

This template defaults to Turbo (server-rendered HTML over the wire) with small Stimulus
controllers, and that's the path to reach for first. An SPA is a legitimate choice when a UI
genuinely needs rich client-side state — pick the tool that fits the screen. Either way, keep
the client thin: lean payloads and partials, avoid N+1 (`includes`), don't ship entire
association trees to the view. Reserve Action Cable for genuinely realtime features.

### 5. Broadcast Only What Multiple Processes Need

Use Turbo Streams / Action Cable for content changes and cross-process events, never for
per-user UI state (scroll, per-session progress). Scope channels/topics narrowly —
`account:{id}:posts`, not a global firehose.

### 6. Separate Background Jobs by Criticality

Job queues by criticality: `critical` (payments), `default` (webhooks, notifications), and
`bulk` (analytics, exports). High-volume work never shares a queue with payments. Every job
carries its account/scope id in arguments.

### 7. Instrument Everything

Use OpenTelemetry auto-instrumentation for HTTP/DB/jobs; add manual spans for multi-step
business logic and external calls. Emit a metric on every business-significant event via
`ActiveSupport::Notifications`. Every log line is structured (lograge/semantic_logger) with
`request_id`, `trace_id`, and account/user ids.

### 8. Isolate Workloads (especially if multi-tenant)

Queries indexed and paginated. Background jobs queue-separated. Cache keys namespaced. Rate
limiting per-actor (Rack::Attack). If multi-tenant: one account's bulk work must never
starve another's, and a misconfigured tenant must not slow others' requests. See
`.claude/multi-tenancy.md`.

### 9. Design Interfaces for Tomorrow, Implement for Today

Wrap external services behind client classes so implementations swap without touching
callers. Consistent Result types so a future API layer maps cleanly to HTTP. Pagination
params on every list method even if the UI doesn't paginate yet. Feature flags (Flipper) to
gate by plan tier or rollout.

---

## Code Style Rules

## **NOTE: EVERY ADDITION THAT ADDS BEHAVIOR MUST BE ACCOMPANIED BY A TEST THAT VALIDATES SAID BEHAVIOR**

### Single Responsibility — One Object, One Job

A service object does one thing and exposes a single `call`. If you write "and" in its
description, split it.

### Keep Domain Logic Out of Controllers and Routes

Skinny controllers/routes: parse params, invoke the domain layer, hand the outcome to the
view. No business rules, raw queries, multi-step orchestration, or external API calls in
controllers/routes. *Where* that domain logic lives is a judgment call: lean on plain Rails
conventions (a model method, a scope, a controller-coordinated `update`) for simple CRUD, and
reach for a service object when an operation spans multiple models, has real side effects, or
needs to be callable from more than one entry point (web, API, job, CLI). Don't manufacture a
one-line service for a trivial save. See `.claude/separation-of-concerns.md`.

### Make Expected Failures Explicit, Not Exceptions

Expected, recoverable outcomes (not found, invalid input, over a plan limit) should be values
the caller can branch on, not exceptions raised for control flow. This template's default is a
tagged Result (`dry-monads`):

```ruby
Success(resource)
Failure([:validation, errors])
Failure([:not_found])
Failure([:forbidden])
Failure([:unauthenticated])
Failure([:plan_limit_reached, { limit:, current: }])
Failure([:conflict])
```

Tagged Results pay off most when an operation has several distinct failure modes or a future
API must map them to HTTP. For simpler cases, idiomatic Rails alternatives are fine —
`model.save` returning false with `model.errors`, or raising and rescuing a domain exception
at the boundary. Whatever you pick, be consistent within a context, don't return a bare
boolean/`nil` where the caller needs to know *why* it failed, and never leak a raw exception
string out of the domain layer as the error. See `.claude/architecture-decisions.md` for the
full taxonomy.

### Request Context via `Current`, Scoped in Services

Service objects read `Current.account` / `Current.user` (or accept them as arguments for
testability). Controllers never build the tenant filter — scoping lives in services and
models. `Current` is the **data boundary**, not authorization.

### Soft Deletes on User-Facing Content

Never hard-delete user-facing records. Use the `discard` gem (`deleted_at`); default scopes
exclude discarded rows; provide explicit `with_discarded` variants for admin views.

### Pagination on Every List

Every method returning a list accepts `page` + `per_page` (default 25, max 100) and returns
a paginated result (Pagy). See `.claude/architecture-decisions.md`.

### Audit Every Mutation

Every create, update, and delete is recorded — the service writes an audit row after the
mutation commits, or a gem (`audited`/`paper_trail`) captures it: who, when, what changed,
from which IP — including impersonation context where applicable.

### Authorization Is Separate from Scoping and Authentication

Authentication = who you are. Tenant scoping (`Current.account`) = which rows you may touch.
Authorization (Pundit) = which actions you may perform. A valid scope still needs an
authorization check. Enforce in controllers **and** re-check in services. See `.claude/rbac.md`.

---

## Tests Are a Contract, Not an Obstacle

Existing tests describe intended behavior. They are specifications, not suggestions.

1. **Never modify an existing test to make it pass.** A previously-passing test that fails
   after your change means your change broke intended behavior. Fix the code, not the test.
   Only exception: a deliberate, explicitly-stated behavior change.
2. **Never weaken an assertion** to pass a failing test.
3. **Never delete a test to resolve a failure** — flag it for discussion.
4. **Never change existing behavior to satisfy a new test** — add a new method/argument instead.
5. **A new feature that breaks existing tests** carries the burden of proof.
6. **If you believe a test is genuinely wrong**, flag it and ask before changing.
7. **Given a bug report**, write a failing spec for the expected behavior, then fix.
8. **Find the root cause** — don't take the shortest route around an error message.

The suite is a ratchet: it only moves forward. See `.claude/testing.md`.

---

## Accessibility — WCAG 2.1 AA Compliance

Every UI addition or modification must comply with WCAG 2.1 AA. A11y violations are bugs.

1. **Semantic HTML over ARIA** — `<button>`, `<a>`, `<nav>`, `<main>`. In Rails use
   `button_to`/`link_to`; never a `data-action` click handler on a `<div>`/`<span>`.
2. **Keyboard navigable** — everything reachable via Tab; custom widgets support arrow keys,
   Escape, Enter/Space. No keyboard traps.
3. **Visible focus indicators** — never remove outlines without a replacement.
4. **ARIA labels on icon-only controls.** Active nav links use `aria-current="page"`.
5. **Color contrast** — text ≥ 4.5:1, large text ≥ 3:1, UI boundaries ≥ 3:1. Never convey
   info by color alone.
6. **Images** — every `<img>` has `alt`; decorative images use `alt=""`.
7. **Forms** — every input has a linked `<label>` (`form.label`); errors via
   `aria-describedby`; required fields marked.
8. **Motion** — respects `prefers-reduced-motion`; auto-advancing content has a pause control.
9. **Touch targets** — min 44×44 CSS px.
10. **Dynamic content** — Turbo Stream updates, flashes, and loading states use `aria-live`.

Run `/a11y-audit` (`.claude/a11y-audit.md`) to audit recent UI.

---

## Git Process: Trunk-Based Development & Atomic Commits

- Work off `main`. Keep branches short-lived. Rebase frequently. Never create merge commits.
  Ship in small, safe increments.

**Before every commit:** run your verify task (`rubocop`, `brakeman`, `bundle audit`) and
`bundle exec rspec`. No commit if checks fail.

**Atomic commits** each do one thing, contain only related changes, leave the codebase in a
valid working state, and are independently reviewable. Avoid mixing refactors with behavior
changes and "WIP"/"misc" commits.

**Commit message format:** `feat:`, `fix:`, `refactor:`, `test:` — be specific.

`main` is always releasable.

---

## What Not to Do

### Code
- No business logic or raw queries in controllers/routes — use service objects and model scopes
- No domain method returning a bare boolean/`nil` where the caller must know *why* it failed — surface the reason (a tagged Result, `model.errors`, or a domain exception)
- No `raise` for ordinary control flow — reserve exceptions for the exceptional
- No service or query that ignores `Current.account` when scopes are configured (multi-tenant)
- No untested branch — every conditional arm needs a spec
- No `binding.pry` / `byebug` / `puts` debugging left in committed code
- No fat models doing cross-aggregate orchestration or external calls

### External Services
- No direct vendor (Stripe/AWS/etc.) calls outside their client class
- No external mutation without an idempotency key
- No webhook processed without verifying its signature over the raw body first
- No external API call without an OpenTelemetry span / Faraday instrumentation

### Data
- No hard deletes on user-facing content — use soft deletes (`discard`)
- No list method without pagination params
- No high-frequency writes straight to Postgres — buffer and batch
- No N+1 queries in views — preload with `includes`

### Infrastructure
- No secrets in source — use Rails credentials / ENV
- No deploys that skip tests
- No migration that isn't part of the release step
- No Action Cable broadcast for per-user UI state
- No background job without its account/scope id in arguments

### Frontend
- No business logic in Stimulus controllers — they are thin DOM/JS bridges
- No CSS classes as test selectors — use `data-testid`
- No hardcoded config that should come from the DB/runtime
- No click handler on a `<div>`/`<span>` — use `<button>`/`<a>`/`button_to`
- No icon-only control without an `aria-label`
- No interactive element without a visible focus indicator

### Logging
- No string interpolation of context into log lines — use structured fields
- No log line without `request_id`/`trace_id` and scope metadata where context exists
