# Payment / Billing Integration

> **Optional module.** Include only if your app charges money.

Load this file when working on subscriptions, plans, checkout, or payment webhook
processing.

This specializes the base pattern in `external-service-integration.md` (one client
class + injectable seam + raw-body webhook verification + async job + DB-guard
idempotency). The running example uses **Stripe**; the patterns apply equally to
Paddle, Braintree, or any provider with a webhook-driven subscription model.

> **Baseline:** Wrap every third-party API behind a client class · Faraday (~> 2) for HTTP with retry/timeout middleware · verify webhook signatures over the raw body, then process async via a background job · secrets via ENV/credentials.

---

## Client Architecture

### One client class: `MyApp::Billing::Client`

All payment calls go through this class. **No `Stripe::` calls scattered** across
controllers, models, or jobs — they all funnel through here.

The official [`stripe`](https://github.com/stripe/stripe-ruby) gem (`~> 13`)
<span title="stable">`[stable]`</span> owns its own HTTP layer (it does **not**
use Faraday), so you wrap it rather than layering Faraday on top. The wrapper is
what makes billing swappable and testable — specs stub `MyApp::Billing::Client`,
never `Stripe::Checkout::Session`.

```ruby
# app/clients/my_app/billing/client.rb
module MyApp
  module Billing
    class Client
      def initialize(sdk: Stripe)
        @sdk = sdk
        Stripe.api_key = secret_key
      end

      def create_customer(email:, account_id:)
        wrap { @sdk::Customer.create(email:, metadata: { account_id: }) }
      end

      def create_checkout_session(customer_id:, price_id:, success_url:, cancel_url:)
        wrap do
          @sdk::Checkout::Session.create(
            mode: "subscription",
            customer: customer_id,
            line_items: [{ price: price_id, quantity: 1 }],
            success_url:, cancel_url:,
            idempotency_key: SecureRandom.uuid          # mutation → idempotent
          )
        end
      end

      def cancel_subscription(subscription_id)
        wrap { @sdk::Subscription.cancel(subscription_id) }
      end

      def billing_portal_url(customer_id:, return_url:)
        wrap { @sdk::BillingPortal::Session.create(customer: customer_id, return_url:).url }
      end

      private

      def wrap
        Success(yield)
      rescue Stripe::InvalidRequestError => e
        Failure([:validation, e.message])
      rescue Stripe::StripeError => e
        Failure([:external_service_error, e.message])
      end

      def secret_key = ENV.fetch("STRIPE_SECRET_KEY")
    end
  end
end
```

### Inject it so specs never call Stripe

```ruby
# ✅ service object takes the client; spec passes a double
module MyApp
  module Billing
    class StartCheckout
      def self.call(...) = new(...).call

      def initialize(user:, plan:, client: MyApp::Billing::Client.new)
        @user, @plan, @client = user, plan, client
      end

      def call
        @client.create_checkout_session(
          customer_id: @user.stripe_customer_id,
          price_id:    @plan.stripe_price_id,
          success_url: success_url, cancel_url: cancel_url
        )
      end
    end
  end
end
```

---

## Data Model

| Schema | Purpose |
|---|---|
| `Plan` | A subscription tier (name, `stripe_price_id`, amount, interval) |
| `Subscription` | A user's/account's active subscription to a plan |

### Provider identifiers stored locally

| Field | On | Purpose |
|---|---|---|
| `stripe_customer_id` | `User` (or `Account`) | Customer record in Stripe |
| `stripe_price_id` | `Plan` | Stripe price/product ID |
| `stripe_subscription_id` | `Subscription` | Stripe subscription object ID |

> **Marketplace note.** For Stripe Connect (each tenant has its own connected
> account), add a `stripe_account_id` to the tenant and thread it through `Client`
> calls. Don't bake a single-account assumption into the billing context.

---

## Subscription Flow — Hosted Checkout

Use Stripe **Checkout Sessions** (hosted page). You never touch card data.

```
User clicks Subscribe
  → StartCheckout service calls Client.create_checkout_session
  → redirect user to session.url (Stripe-hosted page)
  → user pays on Stripe
  → Stripe redirects back to success_url
  → Stripe sends `checkout.session.completed` webhook
  → BillingWebhookJob creates the local Subscription
```

The redirect is **not** where you create the subscription — the webhook is. The
success_url may never be hit (user closes the tab) but the webhook always fires.

```ruby
class CheckoutsController < ApplicationController
  def create
    result = MyApp::Billing::StartCheckout.call(user: Current.user, plan: plan)
    case result
    in Success(session) then redirect_to(session.url, allow_other_host: true)
    in Failure([:external_service_error, _]) then redirect_to plans_path, alert: "Could not start checkout."
    end
  end
end
```

---

## Webhook Processing

Same five rules as `external-service-integration.md`: raw body → verify → reject
400 → enqueue → respond fast → DB-guard idempotency. Stripe provides a single call
that verifies **and** parses.

### Signature verification — over the raw body

[`Stripe::Webhook.construct_event(payload, sig_header, secret)`](https://stripe.com/docs/webhooks/signatures)
checks the `Stripe-Signature` HMAC against the raw body and returns the parsed
`Stripe::Event`, raising `Stripe::SignatureVerificationError` on mismatch.

```ruby
module MyApp
  module Billing
    class Client
      def self.construct_event(payload, sig_header)
        Stripe::Webhook.construct_event(payload, sig_header, ENV.fetch("STRIPE_WEBHOOK_SECRET"))
      rescue Stripe::SignatureVerificationError, JSON::ParserError
        nil                                       # caller rejects with 400
      end
    end
  end
end
```

Read `request.raw_post` before param parsing consumes it.

```ruby
class WebhooksController < ActionController::Base
  skip_before_action :verify_authenticity_token

  def stripe
    event = MyApp::Billing::Client.construct_event(
      request.raw_post,                           # raw bytes
      request.headers["Stripe-Signature"]
    )
    return head :bad_request if event.nil?        # 400 on invalid signature

    MyApp::Billing::WebhookJob.perform_later(
      stripe_event_id: event.id,
      account_id:      event.data.object.metadata["account_id"],
      event_type:      event.type,
      payload:         event.data.object.to_hash
    )
    head :ok
  end
end
```

### Async via background job

| Job runner | Enqueue |
|---|---|
| ActiveJob on Solid Queue (default) | `perform_later` |

### Key events

| Event | Action |
|---|---|
| `checkout.session.completed` | Create the local `Subscription` (link `stripe_subscription_id`) |
| `customer.subscription.updated` | Sync status (`active`, `past_due`, `canceled`) |
| `customer.subscription.deleted` | Mark subscription canceled |
| `invoice.payment_succeeded` | Extend access / record paid period |
| `invoice.payment_failed` | Mark `past_due`, notify user |

### Idempotency — DB guard keyed on the Stripe event id

Stripe redelivers events and event ids are **globally unique** — perfect for a
unique index. As with the base pattern, do **not** lean on a job-runner
"unique key" feature (ActiveJob/Solid Queue has none). The lock is the index.

```ruby
add_index :webhook_events, %i[provider_event_id account_id], unique: true
```

```ruby
class MyApp::Billing::WebhookJob < ApplicationJob
  queue_as :billing

  def perform(stripe_event_id:, account_id:, event_type:, payload:)
    WebhookEvent.create!(provider_event_id: stripe_event_id, account_id:, event_type:)
    handle(event_type, payload)
  rescue ActiveRecord::RecordNotUnique
    # already processed — safe no-op
  end

  private

  def handle("checkout.session.completed", obj)
    MyApp::Billing::ActivateSubscription.call(
      customer_id: obj["customer"], subscription_id: obj["subscription"]
    )
  end
  # ... other event_types ...
end
```

---

## Subscription Gating

Reads of `stripe_customer_id` / `stripe_subscription_id` decide access. Gate at
the request boundary; the rule lives in a policy/service, not inline.

Use a `before_action` plus a Pundit-adjacent check.

```ruby
class ApplicationController < ActionController::Base
  private

  def require_active_subscription
    return if Current.account.subscription&.active?
    redirect_to plans_path, alert: "An active subscription is required."
  end
end

class ReportsController < ApplicationController
  before_action :require_active_subscription
end
```

```ruby
# Pundit policy — authorization logic out of the controller
class ReportPolicy < ApplicationPolicy
  def index? = user.account.subscription&.active?
end
```

Store `active?` as a method on `Subscription` driven by the synced status — never
re-query Stripe on every request.

```ruby
class Subscription < ApplicationRecord
  ACTIVE_STATUSES = %w[active trialing].freeze
  def active? = status.in?(ACTIVE_STATUSES)
end
```

---

## Secrets

| Variable | Required | Purpose |
|---|---|---|
| `STRIPE_SECRET_KEY` | Yes | Stripe API secret key |
| `STRIPE_WEBHOOK_SECRET` | Yes | Webhook signature verification (`whsec_…`) |
| `STRIPE_PUBLISHABLE_KEY` | If using Stripe.js | Client-side publishable key |

ENV by default; Rails apps may use encrypted credentials
(`Rails.application.credentials.stripe[:secret_key]`). Never in source or
committed plaintext config. Set values in your deployment secret store.

```ruby
# ❌
Stripe.api_key = "sk_live_..."

# ✅
Stripe.api_key = ENV.fetch("STRIPE_SECRET_KEY")
```

---

## Testing

Stub `MyApp::Billing::Client`. **Never call Stripe in a spec.**

```ruby
RSpec.describe MyApp::Billing::StartCheckout do
  it "starts a checkout session for the user's plan" do
    client = instance_double(MyApp::Billing::Client)
    allow(client).to receive(:create_checkout_session)
      .and_return(Success(double(url: "https://checkout.stripe.com/c/test")))

    result = described_class.call(user: user, plan: plan, client: client)

    expect(result.value!.url).to include("checkout.stripe.com")
    expect(client).to have_received(:create_checkout_session)
      .with(hash_including(price_id: plan.stripe_price_id))
  end
end
```

### Webhook jobs — build the payload by hand, call the job

No HTTP, no Stripe. Construct the args and invoke the job. Assert redelivery is a
no-op.

```ruby
it "creates a subscription on checkout.session.completed and ignores redelivery" do
  user = create(:user, stripe_customer_id: "cus_123")
  plan = create(:plan, stripe_price_id: "price_abc")
  args = { stripe_event_id: "evt_1", account_id: user.account_id,
           event_type: "checkout.session.completed",
           payload: { "customer" => "cus_123", "subscription" => "sub_1" } }

  MyApp::Billing::WebhookJob.new.perform(**args)
  expect(user.account.reload.subscription).to be_active

  expect { MyApp::Billing::WebhookJob.new.perform(**args) }.not_to raise_error
end
```

For signature verification, you may use Stripe's
[`Stripe::Webhook::Signature`](https://github.com/stripe/stripe-ruby) test helpers
to build a validly-signed header over a fixture payload, or simply assert that a
bad signature yields `400` at the controller. Don't reach the network.

---

## Cross-References

| Topic | File |
|---|---|
| Base client / webhook pattern | `external-service-integration.md` |
| Object storage integration | `object-storage-integration.md` |
| Result tuples, events, audit | `architecture-decisions.md` |
| Subscription gating / authorization | `separation-of-concerns.md` |
| Testing patterns | `testing.md` |
