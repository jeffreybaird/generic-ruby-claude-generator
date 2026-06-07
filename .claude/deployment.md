# Deployment — Releases, CI/CD, Secrets, Migrations

Load this file when configuring deploys, writing a Dockerfile, tuning Puma,
wiring CI/CD, or changing how secrets and migrations are handled. Host-agnostic:
examples use **Kamal 2** (the Rails 8 default), the way the old Elixir template
used Fly + mix releases. Swap in any host that runs Docker.

> **Baseline:** Ruby 3.3+ · Rails 8 deploys with Kamal 2 (default) + Docker · PostgreSQL · secrets via env / Rails encrypted credentials.

---

## Rules (apply to every deploy)

- **No secrets in source.** Not in `config/*.rb`, not in `deploy.yml`, not in the
  Dockerfile. Runtime env or encrypted credentials only.
- **Migrations are a release step**, run before traffic reaches the new code —
  never by hand-SSHing in after the fact.
- **Tests gate the deploy.** CI runs the suite (+ rubocop, brakeman,
  bundler-audit) and the deploy job `needs:` it. A red suite never ships.
- **Build once, run anywhere.** The image is the artifact; config comes from env
  at boot, so the same image promotes dev → staging → prod.
- **Health-checked, zero-downtime.** The new container must pass `/up` before the
  proxy cuts traffic to it.
- **`mix`-equivalent rule:** never run dev/test tooling in production. No
  `bundle exec rails console` as a deploy mechanism, no `RAILS_ENV` unset. Use
  release-style commands (`kamal app exec`, entrypoint steps).

---

## 1. Secrets — never in source

| Concern | Rails |
|---|---|
| App secrets at runtime | Encrypted credentials (`config/credentials.yml.enc` decrypted with `RAILS_MASTER_KEY`) and/or plain ENV |
| Dev convenience | `dotenv-rails` loads `.env` in dev/test **only** |
| Committed? | `credentials.yml.enc` yes (encrypted); `master.key` / `.env` **never** |
| Production source | env injected by the host (Kamal secrets, platform env) |

**Encrypted credentials** <span title="stable">`[stable]`</span>

```bash
bin/rails credentials:edit            # opens decrypted YAML in $EDITOR
# read at runtime:
Rails.application.credentials.dig(:stripe, :secret_key)
```

`config/master.key` (or `RAILS_MASTER_KEY` env) decrypts it. Commit
`credentials.yml.enc`; **gitignore `master.key`**. Per-env files
(`credentials/production.yml.enc` + `production.key`) keep prod secrets separate
([Rails — Custom Credentials](https://guides.rubyonrails.org/security.html#custom-credentials)).

In CI/host, secrets arrive as env. With Kamal, declare them under
`env.secret` and source from `.kamal/secrets` (which itself pulls from a vault /
1Password / CI secrets, never literals)
([Kamal — Environment variables](https://kamal-deploy.org/)).

---

## 2. Migrations as a release step

Run migrations **before the new code serves traffic**, automatically, every
deploy. Two correct hook points; use one, not both:

| Mechanism | Where | When it fires |
|---|---|---|
| Docker entrypoint (Rails default) | `bin/docker-entrypoint` runs `./bin/rails db:prepare` before `rails server` | every container boot, guarded to the server command |
| Kamal pre-deploy hook | `.kamal/hooks/pre-deploy` → `kamal app exec` | once per deploy, before the new container takes traffic |

> **Kamal does NOT auto-migrate.** In a stock Rails 8 image, the *entrypoint*
> runs `db:prepare`; Kamal just boots the image. Don't assume `kamal deploy`
> migrates on its own ([Kamal — Hooks](https://kamal-deploy.org/docs/hooks/overview/)).

- `db:prepare` = create-if-needed + migrate + seed-if-fresh; idempotent and
  safe to run on every boot. `db:migrate` = migrate only (use when the DB always
  exists).
- **Multi-container deploys:** run migrations in **one** place (a pre-deploy hook
  or a single release task), not in every replica's entrypoint, to avoid
  concurrent migration races. The entrypoint-on-every-boot pattern is fine for a
  single web container; gate it for clusters.

```ruby
# bin/docker-entrypoint  (shipped by Rails 8)
if [ "${@: -1:1}" = "./bin/rails" ] && [ "${@: -1}" = "server" ]; then
  ./bin/rails db:prepare
fi
exec "${@}"
```

---

## 3. Kamal 2 (Rails 8 default) <span title="stable">`[stable]`</span>

The host-agnostic deploy tool: build a Docker image, push it, run it on your
servers with a zero-downtime proxy. The Fly-analog for this template
([kamal-deploy.org](https://kamal-deploy.org/)).

```yaml
# config/deploy.yml
service: my_app
image: my-org/my_app

servers:
  web:
    - 192.0.2.10        # add more IPs to scale horizontally

proxy:
  ssl: true
  host: app.example.com
  healthcheck:
    path: /up           # must pass before traffic cuts over

registry:
  server: ghcr.io
  username: my-org
  password:
    - KAMAL_REGISTRY_PASSWORD   # from .kamal/secrets, not a literal

env:
  clear:
    RAILS_MAX_THREADS: 5
    WEB_CONCURRENCY: 2
  secret:
    - RAILS_MASTER_KEY
    - DATABASE_URL

accessories:
  db:
    image: postgres:16
    host: 192.0.2.10
    env:
      secret:
        - POSTGRES_PASSWORD
    directories:
      - data:/var/lib/postgresql/data
  redis:                # only if using Sidekiq / Action Cable Redis adapter
    image: redis:7
    host: 192.0.2.10
    directories:
      - data:/data
```

| Command | Does |
|---|---|
| `kamal setup` | first-time: install Docker on hosts, boot accessories, deploy |
| `kamal deploy` | build + push + zero-downtime roll of the app |
| `kamal app exec '<cmd>'` | run a one-off (`bin/rails db:migrate`, console) on a host |
| `kamal rollback` | revert to the previous image |

---

## 4. Docker

| | Rails 8 |
|---|---|
| Dockerfile | **shipped** by `rails new` (multi-stage, prod-optimized) |
| Entrypoint | `bin/docker-entrypoint` (runs `db:prepare`) |
| Asset build | `assets:precompile` in build stage |

The generated Dockerfile already does multi-stage build, drops to a
non-root user, precompiles assets, and sets the entrypoint. Don't hand-roll one;
edit the generated file.

Run migrations via the release step (§2), not in `CMD`, so replicas don't race.

---

## 5. Puma config (`config/puma.rb`)

Puma is the production app server. Tune **workers**
(processes, CPU parallelism) × **threads** (per-process concurrency, I/O)
([puma/puma](https://github.com/puma/puma)).

```ruby
# config/puma.rb
max_threads = Integer(ENV.fetch("RAILS_MAX_THREADS", 5))
min_threads = Integer(ENV.fetch("RAILS_MIN_THREADS", max_threads))
threads min_threads, max_threads

workers Integer(ENV.fetch("WEB_CONCURRENCY", 2))
preload_app!                       # fork after boot → copy-on-write memory savings

port Integer(ENV.fetch("PORT", 3000))
environment ENV.fetch("RACK_ENV") { ENV.fetch("RAILS_ENV", "development") }

on_worker_boot do
  ActiveRecord::Base.establish_connection if defined?(ActiveRecord)
end
```

| Knob | Env var | Guidance |
|---|---|---|
| Worker processes | `WEB_CONCURRENCY` | ≈ CPU cores; raises RAM linearly |
| Threads / worker | `RAILS_MAX_THREADS` | match DB pool size; 3–5 typical |
| `preload_app!` | — | on, so workers share booted memory (needed for phased restart) |

**DB pool must cover threads:** the pool (`RAILS_MAX_THREADS` in `database.yml`)
≥ `max_threads`, or threads block waiting for connections.

---

## 6. Health checks

The proxy/orchestrator polls a cheap endpoint to decide a container is live.
**Exempt it from auth and `force_ssl`/redirects** so a plain HTTP probe gets 200.

Rails ships `/up` served by
`Rails::HealthController#show` (200 if the app booted)
([Rails — Health Check](https://guides.rubyonrails.org/configuring.html#configuring-health-check)).

```ruby
# config/routes.rb (generated)
get "up" => "rails/health#show", as: :rails_health_check
```

The default `/up` checks boot only, not the DB. If you want a DB-touching probe,
add a custom controller — but keep it fast and unauthenticated. Point
`proxy.healthcheck.path` (Kamal, §3) at it.

---

## 7. Background work

| Stack | Backing store | Process model | Maturity |
|---|---|---|---|
| **Solid Queue** | Postgres (in-DB) | Puma plugin **or** separate worker | <span title="new in Rails 8 default">`[new]`</span> |
| **Solid Cache** | Postgres (in-DB) | none (library) | <span title="new in Rails 8 default">`[new]`</span> |
| **Solid Cable** | Postgres (in-DB) | none (Action Cable adapter) | <span title="new in Rails 8 default">`[new]`</span> |
| **Sidekiq** | Redis | separate worker process | <span title="stable">`[stable]`</span> |

**Solid Queue (Rails 8 default)** runs jobs in your Postgres DB — no Redis
([rails/solid_queue](https://github.com/rails/solid_queue)). Two ways to run it:

```yaml
# A) in the Puma process (small apps) — config/puma.rb / deploy default:
plugin :solid_queue            # SOLID_QUEUE_IN_PUMA=true
# B) dedicated worker (recommended at scale) — a second Kamal role:
servers:
  job:
    hosts: [ 192.0.2.11 ]
    cmd: bin/jobs              # bin/jobs runs the Solid Queue supervisor
```

Prefer a **separate worker process** in production so a slow job never starves
web request threads (CLAUDE.md: separate background jobs by criticality).

**Sidekiq alternative** needs a Redis accessory (§3) and its own worker
container/role running `bundle exec sidekiq`.

---

## 8. CI/CD (GitHub Actions)

Test gate first; deploy `needs:` it. Mirror the local verify task (rubocop,
brakeman, bundler-audit) ([Rails guides](https://guides.rubyonrails.org/)).

```yaml
# .github/workflows/ci.yml
name: ci
on: { push: { branches: [main] }, pull_request: {} }

jobs:
  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env: { POSTGRES_PASSWORD: postgres }
        ports: ["5432:5432"]
        options: >-
          --health-cmd pg_isready --health-interval 10s --health-timeout 5s --health-retries 5
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with: { bundler-cache: true }
      - run: bundle exec rubocop
      - run: bundle exec brakeman --no-pager      # Rails; security scan
      - run: bundle exec bundler-audit check --update
      - run: bin/rails db:prepare
      - run: bundle exec rspec

  deploy:
    needs: test                                   # ← red suite never ships
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with: { bundler-cache: true }
      - run: bin/rails assets:precompile          # Rails only, if not done in image
      - run: bundle exec kamal deploy
        env:
          KAMAL_REGISTRY_PASSWORD: ${{ secrets.KAMAL_REGISTRY_PASSWORD }}
          RAILS_MASTER_KEY: ${{ secrets.RAILS_MASTER_KEY }}
```

- **No deploy without the test gate** — `needs: test` is mandatory.
- Assets: precompile in the **image build** (Rails Dockerfile already does) and
  drop the CI step, or precompile in CI — not both.

---

## 9. Clustering & scaling

| Concern | Rule |
| --- | --- |
| Vertical | more Puma `workers` × `threads` per container (§5), bounded by RAM/CPU and DB pool |
| Horizontal | more containers / `servers` hosts in `deploy.yml` (§3) behind the proxy |
| Sessions | keep **stateless** (signed cookie or DB/Redis store). Add sticky sessions **only** if you truly hold per-connection server state |
| Action Cable | single process → in-memory OK; **multi-process/multi-host → Redis adapter** (or Solid Cable on shared Postgres), else clients miss broadcasts |
| Migrations | run **once** per deploy across the cluster (§2), never per-replica concurrently |
| Background jobs | scale workers independently of web (§7); per-criticality queues so bulk work can't starve critical |

**Stateless web is the default.** Anything that must be shared across processes
(cache, jobs, pub/sub, sessions-if-server-side) lives in Postgres (Solid *) or
Redis — never in a single process's memory. This is what lets `servers.web` grow
from one IP to many with no code change.

---

## Deploy checklist

Before shipping a deploy change:

- [ ] No secret in source (credentials encrypted; `.env`/`master.key` gitignored).
- [ ] Migrations run automatically as a release step, once per deploy.
- [ ] Health check (`/up`) is unauthenticated and SSL-exempt; proxy points at it.
- [ ] Puma DB pool ≥ `max_threads`.
- [ ] CI deploy job `needs:` the test job; rubocop/brakeman/bundler-audit run.
- [ ] Background jobs run in a process separate from web (at scale).
- [ ] Multi-process Action Cable uses a Redis/Solid Cable adapter, not in-memory.
- [ ] Image built once; all config comes from env at boot.

---

## Related docs

- `architecture-decisions.md` — Result/error tags, audit logging, events, feature flags
- `separation-of-concerns.md` — where logic lives (services vs controllers/routes)
- `scalability.md` — buffers, caching, PubSub, rate limiting (if present)
- `observability.md` — spans, metrics, structured logging (if present)
