# Observability

Load this file when writing service objects, jobs, external API client classes,
controllers, or Rack endpoints. Traces and metrics are first-class citizens —
every operation that matters to the business must be observable.

> **Baseline:** Ruby 3.3+ · OpenTelemetry Ruby SDK + auto-instrumentation · ActiveSupport::Notifications · structured logging. Auto-instrument HTTP/DB/jobs; reserve manual spans for business logic.

This template supports **Rails 8** and **Sinatra 4**. Where the idiom differs the
section splits into **Rails** / **Sinatra**. Replace `MyApp` / `my_app` with your
real app name. Maturity tags: **stable** (1.0+, safe to depend on) ·
**pre-1.0** (0.x — pin the minor line, expect breaking changes).

---

## Principles

1. **Every business mutation gets a manual span.** If a method creates, updates,
   or deletes something meaningful, wrap it in a span named
   `my_app.<context>.<operation>`. No library knows your business operations.

2. **Every unwrapped external API call gets a manual span.** Calls to payment
   providers, media providers, or any third-party not already covered by an
   instrumentation gem must produce a span with service-specific attributes.

3. **Jobs inherit the trace automatically.** The contrib ActiveJob/Sidekiq
   instrumentation propagates context from the enqueuing request — do not
   hand-roll inject/extract unless you enqueue outside those paths.

4. **Every business-significant event gets a metric.** Resource viewed,
   subscription created, webhook delivered — if you'd put it on a dashboard,
   `ActiveSupport::Notifications.instrument` it.

5. **Every log line carries context.** `request_id`, `trace_id`, `span_id`, and
   `my_app.account.id` / `my_app.user.id` belong in structured log fields for
   every request and job — never interpolated into the message string.

6. **Don't hand-roll spans around already-instrumented operations.** HTTP
   (Rack/Rails/Sinatra), ActiveRecord/pg, Faraday, ActiveJob/Sidekiq, and Redis
   are covered by auto-instrumentation. Manual spans are for multi-step business
   logic and external calls a gem does not wrap. **Don't double-wrap.**

7. **No PII in spans or logs.** IDs only — never emails, names, tokens, or card
   data. PII in the telemetry pipeline is a compliance risk.

---

## OpenTelemetry Bootstrap

Auto-instrumentation does most of the work. Initialize it **before** the first
request is served.

### Dependencies

Use pessimistic `~>` ranges so patch/minor updates flow in — **never pin exact
minor versions**, especially for the fast-moving OTel packages. Verify latest on
[rubygems.org](https://rubygems.org). Contrib instrumentation gems are
**pre-1.0** (0.x) — pin the minor line.

```ruby
# Gemfile — current ~> ranges (verify latest; do NOT pin exact minors)
gem "opentelemetry-sdk",            "~> 1.8"   # stable
gem "opentelemetry-exporter-otlp",  "~> 0.30"  # pre-1.0 — pin the minor line

# Either the umbrella meta-gem (simplest)…
gem "opentelemetry-instrumentation-all", "~> 0.76"  # pre-1.0

# …or specific instrumentation gems (smaller footprint, explicit):
# gem "opentelemetry-instrumentation-rails",       "~> 0.36"  # Rails only
# gem "opentelemetry-instrumentation-sinatra",     "~> 0.25"  # Sinatra only
# gem "opentelemetry-instrumentation-rack",        "~> 0.26"  # both (HTTP layer)
# gem "opentelemetry-instrumentation-active_record","~> 0.9"  # Rails only
# gem "opentelemetry-instrumentation-pg",          "~> 0.30"  # raw pg / Sinatra
# gem "opentelemetry-instrumentation-faraday",     "~> 0.27"
# gem "opentelemetry-instrumentation-active_job",  "~> 0.8"   # Rails jobs
# gem "opentelemetry-instrumentation-sidekiq",     "~> 0.26"
# gem "opentelemetry-instrumentation-redis",       "~> 0.26"
```

> Sources: [opentelemetry-ruby](https://github.com/open-telemetry/opentelemetry-ruby),
> [opentelemetry-ruby-contrib (instrumentation)](https://github.com/open-telemetry/opentelemetry-ruby-contrib),
> [OTel Ruby getting started](https://opentelemetry.io/docs/languages/ruby/).

### Configure — Rails

Put the config in an initializer. `use_all` activates every installed
instrumentation gem.

```ruby
# config/initializers/opentelemetry.rb
require "opentelemetry/sdk"
require "opentelemetry/instrumentation/all"

OpenTelemetry::SDK.configure do |c|
  c.service_name = "my_app"
  c.use_all   # or c.use "OpenTelemetry::Instrumentation::Rails", {} per-gem
end
```

### Configure — Sinatra

Sinatra has no initializers dir — require and configure in your boot file
(`config.ru` or `app.rb`) before the app class loads, so Rack is wrapped first.
A pure Sinatra app must also add `gem "activesupport"` if you use
`ActiveSupport::Notifications` (see below).

```ruby
# config.ru (top, before require_relative "app")
require "opentelemetry/sdk"
require "opentelemetry/instrumentation/all"

OpenTelemetry::SDK.configure do |c|
  c.service_name = "my_app"
  c.use "OpenTelemetry::Instrumentation::Rack"
  c.use "OpenTelemetry::Instrumentation::Sinatra"
  c.use "OpenTelemetry::Instrumentation::PG"      # if using pg directly
  c.use "OpenTelemetry::Instrumentation::Faraday"
  c.use "OpenTelemetry::Instrumentation::Sidekiq" # if using Sidekiq
end

require_relative "app"
run MyApp::App
```

### Exporter / endpoint

The OTLP exporter honors the standard spec env vars — the collector address is
an **ops concern, not a code change**.

```bash
# runtime env — never hardcode the endpoint in source
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318
OTEL_TRACES_EXPORTER=otlp
OTEL_SERVICE_NAME=my_app          # overrides service_name above if set
```

> Sources: [OTel Ruby exporters](https://opentelemetry.io/docs/languages/ruby/exporters/),
> [OTel exporter env spec](https://opentelemetry.io/docs/specs/otel/protocol/exporter/).

### Auto- vs manual instrumentation

Adopt the auto-instrumentation gems for the layers they own; reserve manual
spans for what they cannot see.

| Layer | Covered by (auto) | You write |
|---|---|---|
| Inbound HTTP request | `-rack` + `-rails` / `-sinatra` | nothing |
| DB query (ActiveRecord / pg) | `-active_record` / `-pg` | nothing |
| Outbound HTTP (Faraday) | `-faraday` | nothing |
| Background job (ActiveJob / Sidekiq) | `-active_job` / `-sidekiq` | nothing |
| Redis | `-redis` | nothing |
| Multi-step business logic | — | manual span |
| External call no gem wraps | — | manual span |

```ruby
# ✅ Manual span around a business operation no gem can see
tracer.in_span("my_app.billing.cancel_subscription") { ... }

# ❌ Manual span wrapping a plain AR query — -active_record already covers it
tracer.in_span("my_app.accounts.get_user") { User.find(id) }
```

> Source: [OTel Ruby instrumentation](https://opentelemetry.io/docs/languages/ruby/instrumentation/).

---

## Manual Spans

Acquire a tracer once per class, then open spans with `in_span`. The block's
`span` is the current span; nested instrumented calls attach automatically.

```ruby
module MyApp
  module Billing
    class CancelSubscription
      TRACER = OpenTelemetry.tracer_provider.tracer("my_app.billing")

      def call(account:, subscription:)
        TRACER.in_span("my_app.billing.cancel_subscription") do |span|
          span.set_attribute("my_app.account.id", account.id)
          # ... multi-step work; child spans (AR, Faraday) nest under this one
          result
        end
      end
    end
  end
end
```

Enrich the current span anywhere downstream without passing it around:

```ruby
span = OpenTelemetry::Trace.current_span
span.set_attribute("my_app.invoice.id", invoice.id)
span.add_event("dunning email queued")
```

### Error handling on a span

```ruby
TRACER.in_span("my_app.payments.charge") do |span|
  charge!
rescue Stripe::CardError => e
  span.record_exception(e)
  span.status = OpenTelemetry::Trace::Status.error(e.message)
  raise
end
```

> Source: [OTel Ruby instrumentation](https://opentelemetry.io/docs/languages/ruby/instrumentation/).

---

## ActiveSupport::Notifications — the in-process event bus

Use `ActiveSupport::Notifications` as the in-process event/metrics bus. Emit a
named event at the business-significant moment; subscribers turn events into
metrics, audit entries, or log lines — without the emitter knowing. Available
standalone outside Rails — a pure Sinatra app adds `gem "activesupport"`.

Event names follow the `event.library` convention: `<operation>.my_app`.

```ruby
# Emit — at the business moment (no PII in the payload, IDs only)
ActiveSupport::Notifications.instrument(
  "subscription_created.my_app",
  account_id: account.id, plan: plan.code
) do
  # optional: wrap work to capture duration automatically
end

# Subscribe — once at boot (Rails initializer / Sinatra boot file)
ActiveSupport::Notifications.subscribe("subscription_created.my_app") do |name, start, finish, _id, payload|
  MyApp::Metrics.increment("subscription.created", tags: payload)
end
```

> Source: [ActiveSupport instrumentation guide](https://guides.rubyonrails.org/active_support_instrumentation.html).

---

## Span Naming Convention

```
my_app.<context>.<operation>
```

Examples:
- `my_app.content.create_resource`
- `my_app.billing.create_checkout`
- `my_app.billing.cancel_subscription`
- `my_app.accounts.invite_member`
- `my_app.webhooks.dispatch`
- `my_app.imports.process_record`

External services use the service name:
- `my_app.video_provider.create_upload_url`
- `my_app.payment_provider.create_subscription`

Jobs (when you add an enrichment span):
- `my_app.job.webhook_event_processor`
- `my_app.job.analytics_aggregation`

---

## Span Attributes

### Business attributes — namespace under `my_app.*`

```ruby
span.set_attribute("my_app.account.id", account.id)  # tenant/org scope
span.set_attribute("my_app.user.id", user.id)        # user-initiated ops
```

### External API calls

```ruby
span.add_attributes(
  "my_app.service" => "video_provider",
  "my_app.idempotency_key" => key
)
```

### Jobs

```ruby
span.add_attributes(
  "my_app.account.id" => args["account_id"],
  "messaging.system" => "sidekiq",   # semconv, usually auto-set
  "my_app.job.attempt" => attempt
)
```

### Semantic conventions vs custom attributes

HTTP and DB spans use the OpenTelemetry **semantic convention** names
(`http.request.method`, `http.response.status_code`, `url.path`, `db.system`,
`db.statement`, …). These are **auto-emitted** by the rack/rails/sinatra and
active_record/pg instrumentation — so backends recognize them out of the box.

For your own business attributes, namespace under `my_app.*`. Do **not** re-emit
a semconv attribute under a custom name, and do not duplicate one the
auto-instrumentation already sets.

```ruby
# ✅ semconv for HTTP/DB (auto), my_app.* for business attrs
span.set_attribute("my_app.account.id", account.id)

# ❌ duplicating a semconv attribute under a custom name
span.set_attribute("my_app.http_status", 200)  # http.response.status_code already set
```

> Sources: [OTel semantic conventions](https://opentelemetry.io/docs/specs/semconv/),
> [HTTP span conventions](https://opentelemetry.io/docs/specs/semconv/http/http-spans/).

### No PII

```ruby
# ✅ ID only
span.set_attribute("my_app.user.id", user.id)

# ❌ PII in the telemetry pipeline
span.set_attribute("my_app.user.email", user.email)
```

---

## Trace Propagation Through Jobs

The contrib ActiveJob and Sidekiq instrumentation **propagates trace context
automatically**: the span created when a job runs links to the request that
enqueued it. You write nothing for context plumbing — just enrich the active
span with business attributes inside the job.

**Rails (ActiveJob):**

```ruby
class WebhookEventJob < ApplicationJob
  queue_as :default

  def perform(account_id:, event_id:)
    OpenTelemetry::Trace.current_span.set_attribute("my_app.account.id", account_id)
    MyApp::Current.account_id = account_id   # see Current section below
    # ... process; trace already linked to the enqueuing request
  end
end
```

**Sinatra (Sidekiq):**

```ruby
class WebhookEventWorker
  include Sidekiq::Job

  def perform(account_id, event_id)
    OpenTelemetry::Trace.current_span.set_attribute("my_app.account.id", account_id)
    # ... process
  end
end
```

**Manual enqueue (outside ActiveJob/Sidekiq paths only):** inject context on
enqueue, extract on run.

```ruby
# enqueue
carrier = {}
OpenTelemetry.propagation.inject(carrier)
MyQueue.push(args.merge(otel_context: carrier))

# run
ctx = OpenTelemetry.propagation.extract(args["otel_context"])
OpenTelemetry::Context.with_current(ctx) { perform(args) }
```

> Source: [opentelemetry-ruby-contrib](https://github.com/open-telemetry/opentelemetry-ruby-contrib).

---

## Metrics

Emit a metric on every business-significant event. Route through
`ActiveSupport::Notifications` so the emit site stays decoupled from the metrics
backend (StatsD / Prometheus / OTel metrics).

| Event | Notification |
|---|---|
| Resource viewed | `resource_viewed.my_app` |
| Upload initiated | `upload_initiated.my_app` |
| Subscription created | `subscription_created.my_app` |
| Subscription canceled | `subscription_canceled.my_app` |
| Webhook delivered | `webhook_delivered.my_app` |
| External API call | `external_api_call.my_app` |
| Payment failed | `payment_failed.my_app` |

Adapt the table to your domain. The pattern — one metric per significant
business event, emitted via Notifications, translated by a subscriber — is
universal.

```ruby
# Subscriber at boot translates events → your metrics backend
%w[subscription_created subscription_canceled payment_failed].each do |evt|
  ActiveSupport::Notifications.subscribe("#{evt}.my_app") do |_n, _s, _f, _id, payload|
    MyApp::Metrics.increment(evt, tags: payload)  # no PII in tags
  end
end
```

When adding a new feature with a business-significant event:
1. `instrument` the event at the call site.
2. Subscribe it to the metrics backend (or extend an existing subscriber).
3. Add a test that the event fires with the right payload (see Testing).

---

## Structured Logging

Never interpolate context into the message — emit structured fields. Every
request and job log carries `request_id`, `trace_id`, `span_id`, and the
`my_app.account.id` / `my_app.user.id` in scope.

```ruby
# ✅ structured, searchable
logger.info("resource created", resource_id: r.id, account_id: account.id)

# ❌ interpolated, not searchable
logger.info("Resource #{r.id} created for account #{account.id}")
```

### Rails

Use **`lograge`** (one structured line per request) or **`semantic_logger`** /
`rails_semantic_logger`. `lograge` is **Rails-only** — it unhooks the default
ActionController/ActionView log subscribers.

```ruby
# config/initializers/lograge.rb
Rails.application.configure do
  config.lograge.enabled   = true
  config.lograge.formatter = Lograge::Formatters::Json.new
  config.lograge.custom_options = lambda do |event|
    span = OpenTelemetry::Trace.current_span.context
    {
      request_id: event.payload[:request_id],
      trace_id:   span.hex_trace_id,
      span_id:    span.hex_span_id,
      account_id: MyApp::Current.account_id,
      user_id:    MyApp::Current.user_id
    }
  end
end
```

> Sources: [lograge](https://github.com/roidrage/lograge),
> [rails_semantic_logger](https://github.com/reidmorrison/rails_semantic_logger).

### Sinatra

`lograge` does **not** apply. Replace `Rack::CommonLogger` with a structured
logger — `semantic_logger` standalone, or a small Rack middleware that emits one
JSON line per request with the same fields.

```ruby
# app.rb
require "semantic_logger"
SemanticLogger.add_appender(io: $stdout, formatter: :json)

class MyApp::App < Sinatra::Base
  disable :logging                       # turn off Rack::CommonLogger default
  use Rack::CommonLogger, SemanticLogger["MyApp"]  # or a custom structured middleware

  before do
    span = OpenTelemetry::Trace.current_span.context
    SemanticLogger.tagged(
      request_id: request.env["HTTP_X_REQUEST_ID"],
      trace_id:   span.hex_trace_id,
      account_id: MyApp::Current.account_id
    )
  end
end
```

> Source: [semantic_logger](https://github.com/reidmorrison/semantic_logger).

### Log levels

- `debug` — query params, idempotency keys, detailed trace info
- `info` — business events (resource created, webhook delivered)
- `warn` — recoverable issues (retry triggered, rate limit approaching)
- `error` — failures needing attention (external API error, payment failed)

---

## Current Attributes → Span / Log Enrichment

Set the account/user/request id **once** per request or job, then read it
anywhere — span attributes, log fields, metric tags — instead of threading it
through every method signature.

### Rails — `ActiveSupport::CurrentAttributes`

```ruby
# app/models/current.rb
module MyApp
  class Current < ActiveSupport::CurrentAttributes
    attribute :account_id, :user_id, :request_id
  end
end

# app/controllers/application_controller.rb
before_action do
  MyApp::Current.request_id = request.request_id
  MyApp::Current.account_id = current_account&.id
  MyApp::Current.user_id    = current_user&.id
  OpenTelemetry::Trace.current_span.add_attributes(
    "my_app.account.id" => MyApp::Current.account_id,
    "my_app.user.id"    => MyApp::Current.user_id
  )
end
```

Rails **resets `CurrentAttributes` automatically** between requests — no leak.

### Sinatra — fiber/thread-local store with a reset hook

Sinatra has no `Current`. Use a fiber-local store and **reset it in an `after`
hook** — threaded servers (Puma) reuse threads, so an un-reset store leaks one
request's identity into the next.

```ruby
module MyApp
  module Current
    def self.account_id = Thread.current[:my_app_account_id]
    def self.account_id=(v) = (Thread.current[:my_app_account_id] = v)
    def self.reset! = Thread.current[:my_app_account_id] = nil
  end
end

class MyApp::App < Sinatra::Base
  before do
    MyApp::Current.account_id = current_account&.id
    OpenTelemetry::Trace.current_span.set_attribute(
      "my_app.account.id", MyApp::Current.account_id
    ) if MyApp::Current.account_id
  end

  after { MyApp::Current.reset! }   # REQUIRED — prevent cross-request leak
end
```

---

## Testing Observability Code

### What to test

- **Custom Notifications fire and carry the right payload.** Assert with
  `ActiveSupport::Notifications.subscribed`:

  ```ruby
  events = []
  ActiveSupport::Notifications.subscribed(->(*args) { events << args }, "subscription_created.my_app") do
    MyApp::Billing::CreateSubscription.new.call(account: account, plan: plan)
  end
  payload = events.first.last
  assert_equal account.id, payload[:account_id]
  refute payload.key?(:email)   # no PII in payload
  ```

- That a span wrapper passes the wrapped return value / raised error through
  unchanged (instrumentation must not alter behavior).

### What NOT to test

- **The OpenTelemetry SDK itself** — span creation, export, attribute storage.
  That's the SDK maintainers' job.
- Auto-instrumentation behavior (rack/rails/active_record spans).
- Exact log output format — brittle, changes with formatter config.

---

## New Feature Checklist

- [ ] Business mutations wrapped in a `my_app.<context>.<operation>` span
- [ ] Span attributes include `my_app.account.id` for tenant/user-scoped ops
- [ ] External API calls span with `my_app.service` + idempotency key
- [ ] No manual span around an already-auto-instrumented operation
- [ ] Jobs enrich the active span (context propagation is automatic)
- [ ] Business-significant events `instrument`ed → metrics subscriber
- [ ] Logs use structured fields (`request_id`, `trace_id`, ids), not interpolation
- [ ] `Current` (Rails) / fiber-local + `reset!` (Sinatra) set once per request
- [ ] No PII in any span attribute, log field, or metric tag
- [ ] Error paths call `record_exception` + set span status `error`
- [ ] Test: custom Notifications fire with the right payload (not the SDK)
