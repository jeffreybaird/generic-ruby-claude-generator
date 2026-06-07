# Generic Ruby + Claude Code Skill Template (Rails 8 / Sinatra 4)

An opinionated, production-minded starting point for **Ruby web applications** — **Rails 8**
or **Sinatra 4** — built with **[Claude Code](https://claude.com/claude-code)** as a
first-class collaborator.

It is two things in one repository:

1. **A set of agent-facing "skill docs"** — `CLAUDE.md` plus a `.claude/` library of focused
   guidance files — that teach Claude Code how *this kind of app* should be built: the
   architecture, the conventions, the test discipline, and the anti-patterns to avoid. The
   docs cover **both frameworks**: identical principles, framework-specific wiring.
2. **A bootstrap script** — `new_ruby_app.sh` — that generates a fresh Rails or Sinatra app
   with defaults that match those docs, rewrites every `MyApp`/`my_app` placeholder to your
   real app name, and drops the docs into the new project.

The docs are a **generic template**: they use `MyApp` (module/class) and `my_app` (snake:
gem, directory, database) as placeholders and describe patterns, not a specific product.
You adapt them to your domain, or let the bootstrap script rename everything for you.

> This is the Ruby sibling of a Phoenix/Elixir skill template. The *principles* are the same;
> the *idioms* are translated to Ruby — ActiveRecord and service objects instead of Ecto and
> contexts, Hotwire/Stimulus instead of LiveView hooks, Sidekiq/Solid Queue instead of Oban,
> Pundit instead of hand-rolled role checks, Faraday instead of Req, Kamal instead of mix
> releases, RSpec/Capybara instead of ExUnit/Wallaby.

---

## Why this exists

Coding agents are most useful when they share the team's mental model: where logic belongs,
how errors are shaped, what "done" means, which gem to reach for. Without that, an agent
re-derives conventions on every task and drifts.

This repo encodes those conventions once, where Claude Code reads them automatically
(`CLAUDE.md` every session; the `.claude/*.md` files on demand for the area in play), so
that new features land in the right layer with the right Result types, tests, and spans —
and so the agent reaches for the *current* idiomatic tool rather than a dated one. The rules
are concrete enough to apply: decision tables, ✅/❌ anti-pattern pairs, and "when to escalate"
ladders, with both **Rails** and **Sinatra** guidance side by side.

---

## What's in the box

```text
.
├── CLAUDE.md                 # Root instructions Claude reads every session
├── .claude/                  # Detailed, load-on-demand skill docs
│   ├── architecture-decisions.md
│   ├── separation-of-concerns.md
│   ├── scalability.md
│   ├── observability.md
│   ├── testing.md
│   ├── stimulus-controllers.md
│   ├── design-system.md
│   ├── theming.md
│   ├── frontend-map.md
│   ├── a11y-audit.md
│   ├── deployment.md
│   ├── multi-tenancy.md            (optional module)
│   ├── rbac.md                     (optional module)
│   ├── external-service-integration.md (optional)
│   ├── payment-integration.md          (optional)
│   └── object-storage-integration.md   (optional)
├── new_ruby_app.sh           # Bootstrap script (Rails or Sinatra)
├── README.md
└── LICENSE
```

### Core skill docs (apply to any Ruby web app)

| File | Covers |
| ---- | ------ |
| `architecture-decisions.md` | Result/tagged-error objects (dry-monads), audit logging, soft deletes (discard), pagination (Pagy), event publishing, feature flags (Flipper), idempotency keys, `Current` context |
| `separation-of-concerns.md` | What belongs in a controller/route vs. service object vs. model vs. view; the skinny-controller rule |
| `testing.md` | Test-as-contract rule, RSpec layout, FactoryBot, WebMock/VCR, `data-testid` selectors, system specs, job specs, CI gates |
| `observability.md` | OpenTelemetry Ruby SDK + auto-instrumentation, ActiveSupport::Notifications, span/log conventions |
| `scalability.md` | Write buffers, caching, jobs by criticality, Turbo/Action Cable delivery semantics, Rack::Attack rate limiting, read replicas |
| `stimulus-controllers.md` | Hotwire: Turbo-first, thin Stimulus controllers, registration, when to reach for JS |
| `deployment.md` | Kamal 2, Docker, credentials/ENV, migrations as a release step, health checks, Puma, CI/CD |
| `theming.md` / `design-system.md` | CSS-variable tokens, Tailwind, ViewComponent, per-tenant theming, design tokens & tone |
| `frontend-map.md` | Template: map your routes, controllers, views, components, Stimulus controllers |
| `a11y-audit.md` | WCAG 2.1 AA audit command |

### Optional modules (include only if the app needs them)

`multi-tenancy.md` (row-level `account_id` scoping), `rbac.md` (authentication + Pundit),
`external-service-integration.md`, `payment-integration.md` (Stripe),
`object-storage-integration.md` (Active Storage / S3).

---

## Guiding principles

Stated as rules, not suggestions — every feature, service object, and model follows them.

1. **Protect Postgres from the hot path.** High-frequency writes batch through a buffer
   (Redis + `activerecord-import`), never row-by-row.
2. **Separate read and write paths.** Structured so reads can later route to a replica
   (`connects_to`/`connected_to`) — a config change, not a rewrite.
3. **Cache frequently-read, infrequently-written data** in `Rails.cache` (Solid Cache /
   Redis), invalidated via events.
4. **Keep the client lean; prefer server-rendered Hotwire** over an SPA; lean payloads, no
   N+1, Action Cable only for genuinely realtime.
5. **Broadcast only what multiple processes need.** Turbo Streams / Action Cable for content
   changes, never per-user UI state; channels scoped narrowly.
6. **Separate background jobs by criticality.** Solid Queue / Sidekiq queues split so
   payments never share with bulk; every job carries its account id.
7. **Emit events, don't inline side effects.** Mutations publish via
   `ActiveSupport::Notifications`; audit, webhooks, notifications, and cache invalidation are
   subscribers that enqueue jobs.
8. **Instrument everything.** OpenTelemetry auto-instrumentation for HTTP/DB/jobs; manual
   spans for business logic; structured logs with trace/scope metadata.
9. **Isolate workloads** (especially if multi-tenant): indexed/paginated queries, queue
   separation, namespaced cache keys, per-actor rate limiting (Rack::Attack).
10. **Design interfaces for tomorrow, implement for today.** Client classes so vendors swap
    without touching callers; consistent Result types; pagination on every list; feature
    flags to gate rollout.

Cross-cutting disciplines the docs codify:

- **Domain logic in service objects returning Result types** (dry-monads `Success`/`Failure`),
  not in controllers/routes; models hold persistence and invariants.
- **Three distinct layers:** authentication (who you are) · tenant scoping (`Current.account`,
  *which rows*) · authorization (Pundit, *which actions*). A valid scope still needs an
  authorization check.
- **Tests are a contract.** Existing specs are specifications — never weaken or delete a spec
  to make a change pass; fix the code or add new behavior.
- **Accessibility is non-negotiable.** WCAG 2.1 AA: semantic HTML over ARIA, keyboard
  navigability, visible focus, labels, contrast, `aria-live`.

### Stack baseline

Ruby 3.3+ · **Rails 8.0** (Hotwire/Turbo + Stimulus, Propshaft, importmap, Solid
Queue/Cache/Cable, Kamal 2, Tailwind) **or Sinatra 4** (Rack, Puma) · PostgreSQL. Default
gems the docs assume: dry-monads, Pundit, Pagy, Faraday (+faraday-retry), discard, Flipper,
RSpec, FactoryBot, Capybara, WebMock/VCR.

---

## Quick start

```bash
# 1. Clone this template
git clone <this-repo> generic-ruby-claude-generator
cd generic-ruby-claude-generator

# 2. Generate a Rails 8 app (default framework)
./new_ruby_app.sh blog_engine

# 3. …or a Sinatra 4 app
./new_ruby_app.sh blog_engine --framework sinatra

cd blog_engine
```

Every `MyApp`/`my_app` reference in the copied `CLAUDE.md` and `.claude/` is rewritten to
`BlogEngine`/`blog_engine`. Open the project in Claude Code and the agent picks up the
conventions immediately.

---

## The bootstrap script

`new_ruby_app.sh` is a shell script (not a Rake task) because it must scaffold a project that
doesn't exist yet — for Rails it wraps `rails new`; for Sinatra it generates a minimal Rack
skeleton by hand (Sinatra has no generator).

### What it does

1. **Validates** the app name (lowercase snake_case) and derives the module name
   (`blog_engine` → `BlogEngine`).
2. **Generates** the app:
   - **Rails:** `rails new <name> --database=postgresql --css=tailwind` — Rails 8 defaults
     (Hotwire, importmap, Propshaft, Solid Queue/Cache/Cable, Kamal 2).
   - **Sinatra:** a hand-scaffolded skeleton — `Gemfile`, `config.ru`, `app.rb`,
     `lib/<app>.rb` (a modular `Sinatra::Base` app with a `/up` health check),
     `config/database.yml` + `puma.rb`, ActiveRecord via `sinatra-activerecord`, a `Rakefile`,
     ERB views, and an RSpec + Rack::Test setup.
3. **Adds the gems** the skill docs assume (dry-monads, Pundit, Pagy, Faraday, discard,
   Flipper, RSpec/FactoryBot/Capybara/WebMock/VCR, plus framework-appropriate extras).
4. **Copies and rewrites the skill docs** into the project: `CLAUDE.md` to the root and
   `.claude/*.md` into `.claude/`. Every `MyApp` → `<Module>` and `my_app` → `<app_name>`.
5. **Installs gems** (`bundle install`, unless `--no-deps`).
6. **Commits** the bootstrapped app + docs (unless `--no-git`).
7. Prints a **next-steps checklist** tailored to the framework.

### Usage

```text
./new_ruby_app.sh <app_name> [options]
```

| Option | Effect |
| ------ | ------ |
| `<app_name>` | App name, lowercase snake_case (e.g. `blog_engine`). Required. |
| `--framework <fw>` | `rails` (default) or `sinatra`. |
| `--path <dir>` | Parent directory to create the app in (default: current directory). |
| `--template <dir>` | Directory holding `CLAUDE.md` + `.claude/` (default: the script's own directory). |
| `--no-deps` | Skip `bundle install` (Sinatra) / pass `--skip-bundle` (Rails). |
| `--no-git` | Skip git init / the initial commit. |
| `-h`, `--help` | Show usage. |

### Examples

```bash
./new_ruby_app.sh blog_engine                          # Rails 8
./new_ruby_app.sh blog_engine --framework sinatra      # Sinatra 4
./new_ruby_app.sh shopfront --framework rails --path ~/src
./new_ruby_app.sh internal_tool --framework sinatra --no-deps --no-git
```

### Requirements

- **Ruby 3.3+** and **Bundler** on `PATH`.
- **Rails:** the `rails` gem (`gem install rails`) for `--framework rails`.
- **PostgreSQL** to create the database and run the app.
- `bash`, `perl`, and `git` (standard on macOS and Linux).

---

## Using this as your own template

- **Adapt the docs to your domain.** Replace the "Project Overview" / "Domain Modules"
  sections of `CLAUDE.md`, drop the optional `.claude/` modules you don't need, and fill in
  the `frontend-map.md` / `design-system.md` templates.
- **Keep the script beside the docs.** `new_ruby_app.sh` resolves its own directory as the
  doc source, so `CLAUDE.md` and `.claude/` must sit next to it (or point elsewhere with
  `--template`).
- **Change the injected gems** by editing `common_gem_block` (and the per-framework blocks)
  in the script.
- **Re-audit when the stack moves.** Guidance is pinned to a baseline (Ruby 3.3+, Rails 8,
  Sinatra 4). When that shifts, update the affected docs and the baseline notes.

---

## License

[MIT](LICENSE).
