# External Service Integration

Pattern for wrapping any third-party API — payment processors, media providers,
email/SMS services, object storage, etc. — into a testable, swappable client
class. The pattern is provider-agnostic; the running examples use a generic media
provider.

> **Optional module.** Include this pattern when your app integrates an external
> API. Skip if no external service integration is needed.

> **Baseline:** Wrap every third-party API behind a client class · Faraday (~> 2) for HTTP with retry/timeout middleware · verify webhook signatures over the raw body, then process async via a background job · secrets via ENV/credentials.

This is the foundation that `payment-integration.md` and
`object-storage-integration.md` specialize.

---

## Client Architecture

### One client class per service: `MyApp::SomeService::Client`

All calls to a given external service go through **one** class. No controller,
route, model, service object, or job may call the vendor SDK / raw HTTP directly.

```ruby
# app/clients/my_app/media/client.rb
module MyApp
  module Media
    class Client
      def create_asset(params)        = post("/assets", params, idempotent: true)
      def create_upload_url(params)   = post("/upload_urls", params, idempotent: true)
      def get_asset(asset_id)         = get("/assets/#{asset_id}")
      def delete_asset(asset_id)      = delete("/assets/#{asset_id}")

      # ... Faraday connection + handle_response below ...
    end
  end
end
```

Apply the same shape to every service type:

| Service type   | Example class                       |
|----------------|-------------------------------------|
| Payment        | `MyApp::Billing::Client`            |
| Email          | `MyApp::Notifications::EmailClient` |
| SMS            | `MyApp::Notifications::SmsClient`   |
| Object storage | `MyApp::Storage::Client`            |
| Media / video  | `MyApp::Media::Client`              |

### Inject the client so tests can stub it

Don't hard-reference `MyApp::Media::Client` from a service object. Inject it (or
resolve it from config) so a spec can pass a double. Ruby has no compile-time
behaviour/interface, so the *contract* is the set of public methods plus specs —
keep the public method list small and stable.

```ruby
# ✅ injectable — spec passes a double
module MyApp
  module Media
    class CreateAsset
      def self.call(...) = new(...).call

      def initialize(actor:, attrs:, client: MyApp::Media::Client.new)
        @actor, @attrs, @client = actor, attrs, client
      end

      def call
        @client.create_asset(@attrs)  # returns a tagged Result
      end
    end
  end
end
```

```ruby
# ❌ untestable without hitting the network — no seam to stub
def call
  MyApp::Media::Client.new.create_asset(@attrs)
end
```

For a process-wide swap (e.g. a fake in `test`), resolve from a config point
instead of a literal:

```ruby
# config/initializers/clients.rb
MyApp.config.media_client = ENV["RAILS_ENV"] == "test" ? MyApp::Media::FakeClient : MyApp::Media::Client
```

### Always return tagged Results, never raw HTTP responses

The client maps transport outcomes to the same tagged Results the rest of the app
uses (see `separation-of-concerns.md` / `architecture-decisions.md`). Callers
branch on `:not_found`, never on an HTTP status integer.

```ruby
Success(body)
Failure([:not_found])
Failure([:external_service_error, { status: 500, body: body }])
```

---

## HTTP Client: Default to Faraday

For providers **without** a maintained Ruby SDK, build the client on
[Faraday](https://github.com/lostisland/faraday) (`~> 2`)
<span title="stable">`[stable]`</span> — the community-default HTTP client. Its
middleware stack lets auth, retries, JSON encoding, and instrumentation be
composable layers rather than scattered code.

> **SDK-wrapped providers own their own HTTP.** When a provider ships a
> maintained Ruby gem (e.g. `stripe`, `aws-sdk-s3`), that gem owns the HTTP layer
> internally. You still wrap it in one `MyApp::<Service>::Client` class — you just
> don't add Faraday on top. Faraday is for providers you call over raw HTTP.

### Connection with retry, timeout, JSON, instrumentation

```ruby
require "faraday"
require "faraday/retry"   # gem "faraday-retry", "~> 2"

module MyApp
  module Media
    class Client
      RETRYABLE = [Faraday::TimeoutError, Faraday::ConnectionFailed].freeze

      def initialize(conn: nil)
        @conn = conn || build_connection
      end

      private

      def build_connection
        Faraday.new(url: base_url) do |f|
          f.request :json                       # encode request bodies as JSON
          # Retry ONLY safe/idempotent verbs by default; honor Retry-After.
          f.request :retry,
            max: 3,
            interval: 0.5,
            backoff_factor: 2,                   # exponential backoff
            retry_statuses: [429, 502, 503, 504],
            methods: %i[get head options],       # NOT post/put unless idempotency-keyed
            exceptions: RETRYABLE,
            retry_block: ->(env:, **) { honor_retry_after(env) }
          f.response :json                       # parse JSON responses
          f.request :instrumentation             # ActiveSupport::Notifications hook
          f.options.timeout      = 10            # total read timeout (s)
          f.options.open_timeout = 5             # connection open timeout (s)
          f.headers["Authorization"] = "Bearer #{api_key}"
        end
      end

      def post(path, body, idempotent: false)
        headers = idempotent ? { "Idempotency-Key" => SecureRandom.uuid } : {}
        handle_response(@conn.post(path, body, headers))
      rescue Faraday::Error => e
        Failure([:external_service_error, e.message])
      end

      def get(path)  = handle_response(@conn.get(path))

      def handle_response(res)
        case res.status
        when 200..299 then Success(res.body)
        when 404      then Failure([:not_found])
        else Failure([:external_service_error, { status: res.status, body: res.body }])
        end
      end

      def base_url = ENV.fetch("MEDIA_API_URL")
      def api_key  = ENV.fetch("MEDIA_API_KEY")
    end
  end
end
```

[`faraday-retry`](https://github.com/lostisland/faraday-retry) is a separate gem
in Faraday 2 — it is not bundled. It honors the `Retry-After` header and applies
exponential backoff with jitter.

### Alternatives

| Library | When |
|---|---|
| **Faraday** `~> 2` <span title="stable">`[stable]`</span> | Default. Middleware composition, swappable adapter, broad ecosystem. |
| `Net::HTTP` (stdlib) | Zero dependencies, one-off internal call. No retry/backoff out of the box. |
| `HTTParty` | Simple scripts; thinner middleware story than Faraday. |
| `Typhoeus` | Parallel/concurrent request fan-out (libcurl). Niche. |

Pick one per client. Don't mix HTTP libraries inside a single client class.

---

## Retries and Circuit Breakers

Three layers, each for a different failure mode. Combine them; don't conflate.

| Concern | Where it lives |
|---|---|
| Transient blip (one bad request) | Faraday `:retry` middleware (safe verbs only, exp backoff, honors `Retry-After`) |
| Non-idempotent mutation retry | Only with an `Idempotency-Key` so the provider dedupes server-side |
| Sustained outage / fail fast | Circuit breaker — [`stoplight`](https://github.com/bolshakov/stoplight) `~> 4` <span title="stable">`[stable]`</span> or [`circuitbox`](https://github.com/yammer/circuitbox) <span title="stable">`[stable]`</span> |
| Durable retry of critical work | Background-job retries (ActiveJob/Solid Queue `retry_on` · Sidekiq `sidekiq_options retry:`) |

### Idempotent retries only

GET/HEAD can be replayed safely. **POST/PUT/DELETE cannot** — replaying a
non-idempotent mutation can double-charge or double-create. Retry mutations only
when they carry an `Idempotency-Key` header so the provider deduplicates
server-side ([Stripe's convention](https://stripe.com/docs/api/idempotent_requests)).
The example above scopes Faraday retries to `%i[get head options]` for exactly
this reason.

### Circuit breaker sits upstream of retries

Retries handle a blip; a **circuit breaker** handles a sustained outage by
failing fast instead of hammering a dead dependency.

```ruby
def create_asset(params)
  Stoplight("media-create-asset")
    .with_fallback { Failure([:external_service_error, :circuit_open]) }
    .run { post("/assets", params, idempotent: true) }
end
```

For critical paths, layer all three: Faraday retries collapse a flaky network,
the circuit breaker stops cascading failures, and a background-job retry survives
a process or node crash.

---

## Webhooks

Inbound webhooks are the inverse direction: the provider calls **you**. The rule
set is fixed and identical across providers:

1. Read the **raw request body** before any param parsing touches it.
2. Verify the HMAC signature over those exact bytes.
3. Reject with `400` if invalid — never process an unverified payload.
4. Enqueue a background job and respond `200` fast. No business logic in the
   request cycle.
5. Make processing **idempotent** via a stored event id (including account id).

### Verify over the RAW body, before parsing

JSON round-tripping reorders keys and re-serializes — the HMAC will no longer
match. You must verify over the exact bytes the provider signed.

Read `request.raw_post`. Skip CSRF and avoid letting param parsing
consume the body first.

```ruby
class WebhooksController < ActionController::Base
  skip_before_action :verify_authenticity_token   # CSRF is for browser forms, not webhooks

  def media
    payload   = request.raw_post                  # raw bytes — read before parsing
    signature = request.headers["X-Provider-Signature"]

    unless MyApp::Media::Client.valid_signature?(payload, signature)
      return head :bad_request                    # 400, reject unverified
    end

    event = JSON.parse(payload)
    MyApp::Media::WebhookJob.perform_later(
      provider_event_id: event["id"],
      account_id:        event.dig("data", "account_id"),
      event_type:        event["type"],
      payload:           event
    )
    head :ok                                       # respond fast; job does the work
  end
end
```

HMAC verification helper (constant-time compare):

```ruby
def self.valid_signature?(payload, signature)
  expected = OpenSSL::HMAC.hexdigest("SHA256", ENV.fetch("MEDIA_WEBHOOK_SECRET"), payload)
  signature.present? && Rack::Utils.secure_compare(expected, signature)
end
```

### Async processing via a background job

| Job runner | Enqueue | Read raw body |
|---|---|---|
| ActiveJob on Solid Queue (default) | `perform_later` | `request.raw_post` |

The job is where the work happens — create/update records, emit events, dispatch
side effects. The controller/route only verifies + enqueues.

### Idempotency — DB guard, not job uniqueness

Providers redeliver the same webhook (retries, at-least-once delivery). Processing
must be idempotent. **Do not rely on a "unique job key"** — ActiveJob/Solid Queue
has no built-in job-level uniqueness. The portable, correct mechanism is a
**data-layer guard**: a unique index on the provider event id, scoped by account.

```ruby
# Migration — the source of truth for "have we seen this event?"
create_table :webhook_events do |t|
  t.string  :provider_event_id, null: false
  t.bigint  :account_id,        null: false
  t.string  :event_type,        null: false
  t.timestamps
end
add_index :webhook_events, %i[provider_event_id account_id], unique: true
```

```ruby
class MyApp::Media::WebhookJob < ApplicationJob   # ActiveJob
  queue_as :webhooks
  retry_on Faraday::TimeoutError, wait: :polynomially_longer, attempts: 5

  def perform(provider_event_id:, account_id:, event_type:, payload:)
    WebhookEvent.create!(
      provider_event_id:, account_id:, event_type:
    )                                              # unique index = the lock
    handle(event_type, payload)
  rescue ActiveRecord::RecordNotUnique
    # already processed — safe no-op
  end
end
```

The unique index does the deduplication regardless of how many times the job
runs or how it was enqueued — the DB guard is the guarantee.

### Generic webhook events

Adapt to your provider's actual event names:

| Event category    | Typical action                                   |
|-------------------|--------------------------------------------------|
| `resource.created`| Create or link the local record                 |
| `resource.ready`  | Mark record active, store final metadata         |
| `resource.failed` | Mark record errored, log provider error details  |
| `resource.deleted`| Soft-delete or clean up the local record         |

---

## Secrets

Provider credentials come from the environment, never from source.

| Mechanism | When |
|---|---|
| **ENV** (`ENV.fetch("MEDIA_API_KEY")`) | Default. Pairs with `dotenv` in dev. |
| **Rails encrypted credentials** (`Rails.application.credentials.media[:api_key]`) | Rails apps that prefer committed-but-encrypted config + a `RAILS_MASTER_KEY`. |

```ruby
# ❌ secret in source
API_KEY = "sk_live_abc123"

# ✅ from the environment, fail loud if missing
def api_key = ENV.fetch("MEDIA_API_KEY")
```

Store the actual values in your deployment platform's secret store. Never commit
them.

| Variable | Required | Purpose |
|---|---|---|
| `MEDIA_API_KEY` | Yes | Provider API authentication |
| `MEDIA_API_SECRET` | If provider needs it | API secret |
| `MEDIA_WEBHOOK_SECRET` | Yes | Webhook signature verification |

---

## Testing

Never hit a real API in a spec. Stub the injected client, and for the HTTP layer
itself use [WebMock](https://github.com/bblimke/webmock) /
[VCR](https://github.com/vcr/vcr).

### Stub the client in service/request specs

```ruby
RSpec.describe MyApp::Media::CreateAsset do
  it "persists the asset returned by the provider" do
    client = instance_double(MyApp::Media::Client)
    allow(client).to receive(:create_asset)
      .and_return(Success({ "id" => "asset_123" }))

    result = described_class.call(actor: actor, attrs: { title: "Clip" }, client: client)

    expect(result).to be_success
    expect(client).to have_received(:create_asset).with(hash_including(title: "Clip"))
  end
end
```

### Block real HTTP; assert the request shape

```ruby
# spec/spec_helper.rb
WebMock.disable_net_connect!(allow_localhost: true)

it "sends an idempotency key on creates" do
  stub = stub_request(:post, "https://api.media.example/assets")
           .with(headers: { "Idempotency-Key" => /.+/ })
           .to_return(status: 200, body: { id: "asset_123" }.to_json,
                      headers: { "Content-Type" => "application/json" })

  MyApp::Media::Client.new.create_asset(title: "Clip")
  expect(stub).to have_been_requested
end
```

### Webhook jobs — build the payload by hand, call the job directly

No HTTP. Construct the args and invoke `perform` / `new.perform`.

```ruby
it "marks the asset ready and ignores a redelivered event" do
  asset = create(:asset, provider_status: "preparing")
  args  = { provider_event_id: "evt_1", account_id: asset.account_id,
            event_type: "resource.ready",
            payload: { "id" => "evt_1", "data" => { "asset_id" => asset.provider_id } } }

  MyApp::Media::WebhookJob.new.perform(**args)
  expect(asset.reload.provider_status).to eq("ready")

  # redelivery is a safe no-op (unique index)
  expect { MyApp::Media::WebhookJob.new.perform(**args) }.not_to raise_error
end
```

For signature verification, compute the HMAC over your test payload with the test
secret and assert that a tampered body is rejected with `400`.

---

## Cross-References

| Topic | File |
|---|---|
| Payment provider integration | `payment-integration.md` |
| Object storage integration | `object-storage-integration.md` |
| Result tuples, events, audit | `architecture-decisions.md` |
| Where client calls belong | `separation-of-concerns.md` |
| Testing patterns | `testing.md` |
