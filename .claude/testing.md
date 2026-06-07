# Testing

Load this file when writing tests, setting up test infrastructure, or reviewing
test coverage. Generic Ruby template for **Rails 8**.

> **Baseline:** Ruby 3.3+ · RSpec (community default; Minitest is Rails' default) · FactoryBot · Capybara (system/E2E) · WebMock/VCR (HTTP) · data-testid selectors.

Maturity tags: **[stable]** = mature, safe to rely on · **[active]** =
maintained, evolving · **[optional]** = adopt only if the need exists.

Loose gem pins below use `~>` — pin to the minor you adopt, let patch float.
Replace `MyApp` / `my_app` with your real app/module names.

---

## 1. Tests Are a Contract, Not an Obstacle

Existing tests describe **intended behavior**. They are specifications, not
suggestions. These rules are absolute:

1. **Never modify an existing test to make it pass.** A previously-passing test
   that fails after your change means your change broke intended behavior. Fix
   the code, not the test. Only exception: a deliberate, explicitly-stated
   behavior change.
2. **Never weaken an assertion** to pass a failing test.
3. **Never delete a test to resolve a failure** — flag it for discussion.
4. **Never change existing function behavior to satisfy a new test** — add a new
   method/parameter instead.
5. **A new feature that breaks existing tests** carries the burden of proof —
   integrate without breaking existing behavior.
6. **If you believe a test is genuinely wrong**, flag it with a comment and ask
   before changing.
7. **Given a bug report**, write a failing test for the expected behavior first,
   then fix the code.
8. **Find the root cause** — don't take the shortest route around an error
   message.

The suite is a ratchet: it only moves forward.

---

## 2. Test Layout

### Rails (RSpec) — `[stable]`

```
spec/
├── models/          # validations, scopes, associations, callbacks
├── services/        # service objects / interactors: happy + error + authz + isolation
├── requests/        # full-stack route/controller behavior (ActionDispatch); fast
├── system/          # Capybara E2E; real browser only via :js; excluded from fast runs
├── jobs/            # ActiveJob / Sidekiq worker specs
├── factories/       # FactoryBot definitions
├── support/         # shared contexts, helpers, WebMock/VCR config
│   ├── factory_bot.rb
│   ├── capybara.rb
│   ├── vcr.rb
│   └── webmock.rb
├── fixtures/
│   └── vcr_cassettes/
│       └── webhooks/
│           ├── payment_succeeded.yml
│           └── asset_ready.yml
├── rails_helper.rb
└── spec_helper.rb
```

Mirrors RSpec's directory conventions ([rspec.info](https://rspec.info/),
[rspec-rails](https://github.com/rspec/rspec-rails)).

**Minitest equivalent (Rails' actual default)** — `[stable]`:
`test/models`, `test/controllers` (or `test/integration`), `test/system`,
`test/jobs`; cases subclass `ActiveSupport::TestCase` /
`ActionDispatch::IntegrationTest` / `ActionDispatch::SystemTestCase`. See the
[Rails testing guide](https://guides.rubyonrails.org/testing.html).

---

## 3. Default Tool Ladder

Escalate only when the rung below cannot cover the case. Reserve the browser for
JS-driven behavior (Turbo Streams, Stimulus controllers, drag-and-drop) — it is
slow and flaky compared to request specs.

| Scenario                                              | Tool                          | Maturity   |
|-------------------------------------------------------|-------------------------------|------------|
| Model validation / scope / association                | model spec                    | [stable]   |
| Business logic, authorization, tenant isolation       | service spec (unit)           | [stable]   |
| One route, full stack, no JS                          | request spec (ActionDispatch) | [stable]   |
| Multi-page flow, server-rendered, no JS               | request spec (chain requests) | [stable]   |
| JS / Turbo / Stimulus interaction, real browser       | system spec (Capybara `:js`)  | [active]   |
| CSS / visual rendering verification                   | system spec (Capybara `:js`)  | [active]   |

Ladder: **model + service unit specs → request specs (full stack, fast) →
system specs (Capybara, real browser only for JS/Turbo/Stimulus behavior).**

System specs default to the rack-test driver (no JS). Tag the browser ones `:js`
to switch to Selenium/Cuprite, and **exclude `:js` from the fast dev run**:

```ruby
# .rspec or CI: fast loop skips the browser
# bundle exec rspec --tag ~js
```

```ruby
# spec/support/capybara.rb
Capybara.javascript_driver = :selenium_chrome_headless
```

Capybara: [github.com/teamcapybara/capybara](https://github.com/teamcapybara/capybara) — `[stable]`.

---

## 4. Factories (FactoryBot)

Use [`factory_bot`](https://github.com/thoughtbot/factory_bot) (`~> 6.4`) —
`[stable]`; Rails apps add `factory_bot_rails`. Provide factories for the core
graph: account/tenant, user, membership-with-role, and resources with external
provider ids.

`build` vs `create`: prefer **`build`** (in-memory, no DB) for unit specs that
don't need persistence; use **`create`** only when the record must exist in the
DB (request/system specs, association lookups). `build_stubbed` is the fastest
when you need a record with an id but no DB write.

```ruby
# spec/factories/accounts.rb
FactoryBot.define do
  factory :account do                      # the tenant
    sequence(:name) { |n| "Test Org #{n}" }
    sequence(:slug) { |n| "test-org-#{n}" }
  end

  factory :user do
    sequence(:email) { |n| "user-#{n}@example.com" }
    password { "supers3cret!" }
  end

  factory :membership do
    user
    account
    role { :editor }

    trait(:admin)  { role { :admin } }
    trait(:viewer) { role { :viewer } }
  end

  # Resource carrying external provider ids (media/payment/etc.)
  factory :media_asset do
    account
    sequence(:title) { |n| "Asset #{n}" }
    sequence(:provider_asset_id)    { |n| "asset_#{n}" }
    sequence(:provider_playback_id) { |n| "playback_#{n}" }
    provider_status { "ready" }

    trait(:preparing) { provider_status { "preparing" } }
  end

  factory :subscription do
    account
    user
    sequence(:provider_subscription_id) { |n| "sub_#{n}" }
    status { :active }
  end
end
```

Use **traits** for variation (roles, statuses) rather than separate factories.

**Minitest equivalent:** Rails ships YAML fixtures (`test/fixtures/*.yml`) by
default. FactoryBot works with Minitest too (`include FactoryBot::Syntax::Methods`)
and is the common upgrade once relational graphs grow.

---

## 5. External Services — Never Hit Real APIs

Block all real outbound HTTP in the suite. Two complementary tools:

- **WebMock** ([github.com/bblimke/webmock](https://github.com/bblimke/webmock),
  `~> 3.23`) — `[stable]`. Disables real connections; stub specific
  request/response pairs explicitly.
- **VCR** ([github.com/vcr/vcr](https://github.com/vcr/vcr), `~> 6.3`) —
  `[stable]`. Records a real interaction once into a "cassette" (YAML) and
  replays it thereafter. Best for integration specs against a real provider's
  shape.

```ruby
# spec/support/webmock.rb — block ALL real HTTP up front
require "webmock/rspec"
WebMock.disable_net_connect!(allow_localhost: true)
```

```ruby
# spec/support/vcr.rb
require "vcr"
VCR.configure do |c|
  c.cassette_library_dir = "spec/fixtures/vcr_cassettes"
  c.hook_into :webmock
  c.filter_sensitive_data("<API_KEY>") { ENV["MYAPP_API_KEY"] }  # never record secrets
  c.configure_rspec_metadata!
end
```

Two valid strategies — pick per spec:

| Strategy                    | When                                                      |
|-----------------------------|-----------------------------------------------------------|
| Stub the **client class**   | Unit specs of code that calls your `MyApp::FooClient`; fast, no HTTP layer involved |
| Stub the **HTTP layer**     | Verifying the client itself builds the right request / parses the response (WebMock or VCR) |

```ruby
# Stub the client class (unit-level):
allow(MyApp::MediaClient).to receive(:get_asset)
  .with(asset.provider_asset_id)
  .and_return(duration: 120.5, max_resolution: "1080p")

# Or replay a recorded interaction (integration-level):
it "fetches the asset", :vcr do   # uses cassette named after the example
  expect(MyApp::MediaClient.new.get_asset("asset_123")).to include(status: "ready")
end
```

Rule: **no external API call ever fires for real in the suite**, and **no secret
is recorded into a cassette** (filter it).

---

## 6. Test Selectors — `data-testid` Mandatory

All interactive and conditionally-rendered elements get a `data-testid`
attribute. Tests target **these attributes, never CSS classes or DOM structure**
(classes change with styling; testids are a stable contract).

```erb
<%# ✅ CORRECT — test-stable selector %>
<button data-testid="delete-post-<%= post.id %>">Delete</button>
<div data-testid="empty-state" hidden="<%= posts.any? %>">No posts yet.</div>

<%# ❌ WRONG — fragile, breaks on restyle %>
<button class="btn btn-danger text-sm">Delete</button>
```

In Capybara, target the attribute directly:

```ruby
find('[data-testid="delete-post-1"]').click
expect(page).to have_css('[data-testid="empty-state"]')
```

Naming convention for `data-testid` values:
- Actions: `delete-post-{id}`, `subscribe-btn`, `save-resource-{id}`
- Containers: `post-list`, `resource-list`, `saved-items`
- Items: `post-{id}`, `resource-{id}`, `user-{id}`
- States: `empty-state`, `loading-state`, `error-state`
- Navigation: `nav-admin`, `nav-content`, `nav-analytics`

---

## 7. Background-Job Testing

Assert three things for every job: **(a) it gets enqueued** with the right args
(including scope/tenant id), **(b) idempotency** — running twice produces the
same result with no duplicate side effects, **(c) error handling** — malformed
payload or missing record returns/raises as designed.

### Rails — ActiveJob (`[stable]`)

`rspec-rails` provides the matchers; under the hood they wrap
`ActiveJob::TestHelper`. See the
[Rails job testing guide](https://guides.rubyonrails.org/testing.html#testing-jobs).

```ruby
# Assert enqueue (does not run the job):
expect {
  MyApp::PublishPost.call(account:, post:)
}.to have_enqueued_job(WebhookProcessorJob)
  .with(hash_including(account_id: account.id))   # scope id always present

# Run enqueued jobs to assert the full effect:
perform_enqueued_jobs do
  MyApp::PublishPost.call(account:, post:)
end
expect(post.reload).to be_published
```

Minitest equivalent: `assert_enqueued_jobs`, `assert_enqueued_with`,
`perform_enqueued_jobs` from `ActiveJob::TestHelper`.

### Sidekiq — `[stable]`

Framework-agnostic path. Use
[`Sidekiq::Testing`](https://github.com/sidekiq/sidekiq/wiki/Testing).

| Mode                      | Behavior                                              | Use for                          |
|---------------------------|-------------------------------------------------------|----------------------------------|
| `Sidekiq::Testing.fake!`  | Jobs pushed onto a `jobs` array, **not executed**     | Asserting enqueue without effects |
| `Sidekiq::Testing.inline!`| Jobs execute **synchronously** when enqueued          | Asserting full job effect end-to-end |

```ruby
require "sidekiq/testing"

it "enqueues the processor with the account id" do
  Sidekiq::Testing.fake! do
    MyApp::PublishPost.call(account:, post:)
    expect(WebhookProcessorWorker.jobs.size).to eq(1)
    expect(WebhookProcessorWorker.jobs.last["args"]).to eq([account.id, post.id])
  end
end

it "is idempotent" do
  args = [account.id, asset.id]
  expect { WebhookProcessorWorker.new.perform(*args) }.not_to raise_error
  expect { WebhookProcessorWorker.new.perform(*args) }  # second run, same result
    .not_to change { asset.reload.provider_status }
end

it "raises on a missing record" do
  expect { WebhookProcessorWorker.new.perform(0, 0) }
    .to raise_error(ActiveRecord::RecordNotFound)
end
```

---

## 8. Required Coverage

For every new feature, ALL applicable categories below are required before it is
considered complete.

### Models / data objects
- Valid attrs → valid
- Missing required fields → invalid with the expected error
- Invalid values → invalid
- Unique constraint / DB-level violations surfaced
- Each **scope** returns the right set (and excludes soft-deleted by default)

### Services / business logic
- Happy path
- **Every error path** (each failure return / raised error)
- **Authorization** — authorized actor succeeds, unauthorized denied
- **Tenant / per-user isolation** — actor in account A cannot read or mutate
  account B's data (see below). This is the highest-value port from the source.
- Edge cases (empty, nil, boundary values)

### Request specs (every route)
- Each route's success response (status + body/redirect)
- **Authorization** — wrong role / unauthenticated → denied or redirected
- Flash messages for success and failure
- Validation errors rendered
- Cross-tenant request → blocked (if multi-tenant)

### System specs (JS-only flows)
- Tagged `:js`, excluded from the fast run
- Only for behavior the request layer cannot exercise: Stimulus controllers,
  Turbo Stream/Frame updates, drag-and-drop, payment-provider redirect/return,
  CSS/visual rendering
- **Not** for anything a request spec can already cover

### Job specs
- Happy-path processing
- Idempotency (run twice → same result)
- Error handling (malformed payload, missing record)

### Tenant / per-user isolation

Express isolation through `current_account` / scoped queries / `acts_as_tenant`. The
assertion that matters: a query scoped to one account must never return another
account's row.

```ruby
it "isolates posts across accounts" do
  account       = create(:account)
  other_account = create(:account)
  post = create(:post, account: account)

  # The scoped finder must not find another account's record:
  expect {
    MyApp::Posts.find_for(other_account, post.id)
  }.to raise_error(ActiveRecord::RecordNotFound)
end
```

---

## 9. CI Gates

All must pass before merge/deploy. Run the fast suite locally before every
commit.

```bash
bundle exec rspec --tag ~js     # fast: unit + request + non-JS system specs
bundle exec rspec --tag js      # browser specs (separate CI job; needs Chrome)
bundle exec rubocop             # style + lint
bundle exec brakeman            # static security analysis (Rails)
bundle exec bundle-audit check --update   # dependency CVE scan
bundle exec erb_lint --lint-all # ERB lint (optional)
```

| Gate          | Gem / tool                                                              | Scope            | Maturity   |
|---------------|-------------------------------------------------------------------------|------------------|------------|
| Tests         | [rspec](https://rspec.info/) `~> 3.13` (or Minitest)                    | Rails            | [stable]   |
| Lint/style    | [rubocop](https://github.com/rubocop/rubocop) `~> 1.65`                 | Rails            | [stable]   |
| Security scan | [brakeman](https://brakemanscanner.org/) `~> 6.1`                       | Rails            | [stable]   |
| CVE audit     | [bundler-audit](https://github.com/rubysec/bundler-audit) `~> 0.9`      | Rails            | [stable]   |
| ERB lint      | [erb_lint](https://github.com/Shopify/erb_lint) `~> 0.5`                | template-based   | [optional] |

Notes:
- **Brakeman** is Rails-aware (it understands Rails routing/views).
- **Minitest** apps swap the first row for `bin/rails test` /
  `bin/rails test:system`; the remaining gates are identical.
- Run the suite, lint, security, and CVE gates green before any deploy. `main`
  is always releasable.
