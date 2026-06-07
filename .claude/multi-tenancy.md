# Multi-Tenancy Rules

> **Optional module.** Include only if your app is multi-tenant (shared-schema). Single-tenant apps can skip this.

> **Baseline:** Shared-schema row-level scoping by `account_id` is the default; `Current.account` carries the tenant; query prefixes/schema-per-tenant (ros-apartment) reserved for strong isolation. Scope = data boundary, not authorization.

Load this file when working on any feature that touches tenant-scoped data.

Baseline: Ruby 3.3+ · **Rails 8**. Tenant model = `Account` (FK column `account_id`). Scoping lives in models/services, never controllers/routes (see `separation-of-concerns.md`). Errors are dry-monads `Success`/`Failure([:tag])`; authorization is Pundit.

---

## Core Principle

A multi-tenant app shares one database and one set of tables across all tenants.
Isolation is enforced at the **application layer**, not the database layer. The
tenant model in this guide is `Account` — your app may call it `Organization`,
`Workspace`, or `Tenant`; the rules are identical.

### Isolation strategy — pick by isolation need

Shared-schema with an `account_id` foreign key is the **default**, threaded through
`Current.account`. Reserve heavier strategies for strong-isolation/compliance
requirements — they cost operational complexity (migrations per schema, connection
juggling, separate backups).

| Strategy | When to use | Trade-off | Maturity |
|---|---|---|---|
| **Row-level (`account_id` FK)** — *default* | Almost all SaaS apps; thread via `Current.account` | App-layer isolation; a missed `where` leaks data | Stable, no dependency |
| **Schema-per-tenant (Postgres schemas)** | Stronger isolation, one DB, per-tenant schema ([ros-apartment](https://github.com/rails-on-services/apartment)) | Migrations run per schema; cross-tenant queries awkward; heavier ops | Maintained fork; loose pin `~> 3.0` |
| **Separate database per tenant** | Regulatory hard isolation, large enterprise tenants | Highest ops cost; connection + migration fan-out | ros-apartment `:database` strategy or Rails multi-DB |

> Most apps should not move past row #1. If you think you need schemas, confirm the
> driver is a compliance/contractual requirement, not a hypothetical.

---

## 1. Schema Rules (framework-agnostic)

### Every tenant-scoped table has `account_id`

No exceptions. If data belongs to a tenant, it carries an `account_id` foreign key
**with an index**. The only tables without it are `accounts` itself and system-level
tables (e.g. background-job tables, global feature flags).

```ruby
# ✅ CORRECT — migration: FK + index, cascade on account deletion
create_table :posts do |t|
  t.references :account, null: false, foreign_key: { on_delete: :cascade }
  t.string :title, null: false
  t.string :slug, null: false
  t.timestamps
end

add_index :posts, [:account_id, :slug], unique: true
```

Use `on_delete: :cascade` on the `account_id` FK so deleting an `Account` cascades
cleanly. Never leave orphaned tenant rows — orphaned tenant data is a data-integrity bug.
(Consider whether your app prefers soft-deleting accounts instead; if so, cascade is moot
and you scope out soft-deleted accounts in queries.)

### Composite uniqueness is scoped to the account

Any uniqueness constraint (slug, plan name, external ref) must be scoped to the
account. A globally unique slug is wrong — two accounts must be free to use the same one.
Enforce in **both** the model and the database.

```ruby
# ✅ CORRECT — model validation + matching DB unique index
class Post < ApplicationRecord
  belongs_to :account
  validates :slug, uniqueness: { scope: :account_id }
end
# add_index :posts, [:account_id, :slug], unique: true   (from migration above)

# ❌ WRONG — globally unique slug blocks two accounts from sharing one
validates :slug, uniqueness: true
```

The model validation gives a friendly error; the DB unique index is the real guarantee
under a race ([Rails Guides — uniqueness](https://guides.rubyonrails.org/active_record_validations.html#uniqueness)).

---

## 2. Request-scoped tenant via `Current.account`

The resolved tenant is carried for the duration of the request in a request-local, set
**once** after resolution and **reset** at request end. Models/services read
`Current.account` rather than receiving it from controllers.

### `ActiveSupport::CurrentAttributes`

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :account, :user
end
```

Rails resets `Current` automatically between requests **via the executor** — no manual
reset needed in a normal Rails request/job ([CurrentAttributes](https://api.rubyonrails.org/classes/ActiveSupport/CurrentAttributes.html)).

---

## 3. Scope every query (framework-agnostic)

Models and services apply the `account_id` filter. **Controllers/routes never build the
tenant filter** (see `separation-of-concerns.md`). Prefer association scoping off
`Current.account`; fall back to `where(account_id: Current.account.id)`.

```ruby
# ✅ CORRECT — scoped through the association; cannot reach another account's rows
Current.account.posts.find(id)
Current.account.posts.where(published: true).order(created_at: :desc)

# ✅ ALSO CORRECT — explicit filter when there is no convenient association
Post.where(account_id: Current.account.id).find(id)

# ❌ WRONG — fetches by global id, leaks across all tenants
Post.find(id)

# ❌ WRONG — returns every tenant's rows
Post.all
```

In a service object, return tagged Results, not raised exceptions, for expected misses:

```ruby
# ✅ service: scope first, then act
def call
  post = Current.account.posts.find_by(id: @id)
  return Failure([:not_found]) unless post
  # ...
  Success(post)
end
```

---

## 4. `acts_as_tenant` — automatic scoping (community option)

[`acts_as_tenant`](https://github.com/ErwinM/acts_as_tenant) (maturity: stable, widely
used; loose pin `~> 1.0`) installs an automatic default scope from the current tenant and,
in strict mode, **raises on any unscoped query** — turning a silent leak into a loud error.

```ruby
# model
class Post < ApplicationRecord
  acts_as_tenant(:account)   # auto-scopes all queries to ActsAsTenant.current_tenant
end
```

### Setting the current tenant

```ruby
# controller macro (resolves by subdomain, sets the tenant per request)
class ApplicationController < ActionController::Base
  set_current_tenant_by_subdomain(:account, :subdomain)
  # or, resolve it yourself:
  #   set_current_tenant_through_filter
  #   before_action { set_current_tenant(resolve_account!) }
end
```

### Strict mode + the escape hatch

```ruby
# config/initializers/acts_as_tenant.rb
ActsAsTenant.configure do |config|
  config.require_tenant = true   # raises ActsAsTenant::Errors::NoTenantSet on unscoped query
end
```

```ruby
# ✅ escape hatch — the ONLY sanctioned cross-tenant path (admin/system code)
ActsAsTenant.without_tenant do
  Post.count   # bypasses tenant scoping for this block
end

# block-scoped tenant switch (jobs, rake tasks)
ActsAsTenant.with_tenant(account) { ... }
```

> `acts_as_tenant`'s default scope still has the `default_scope` caveats below — but it
> is purpose-built for them and adds the strict-mode safety net, which is why it's
> preferred over a hand-rolled `default_scope`.

---

## 5. Schema-per-tenant alternative — `ros-apartment`

[`ros-apartment`](https://github.com/rails-on-services/apartment) (maturity: the
**maintained fork** of the dead `influitive/apartment`; you still `require 'apartment'`;
loose pin `~> 3.0`) gives each tenant its own **Postgres schema** (or a separate
database) for strong isolation/compliance. Heavier ops: every migration runs per tenant,
and cross-tenant reads need an explicit switch.

```ruby
# config/initializers/apartment.rb
Apartment.configure do |config|
  config.use_schemas = true                      # Postgres schema-per-tenant (vs separate DB)
  config.tenant_names = -> { Account.pluck(:subdomain) }
end
```

```ruby
# switching (block form — preferred in app code)
Apartment::Tenant.switch(account.subdomain) do
  Post.all   # only the tenant's schema is visible
end

Apartment::Tenant.create(account.subdomain)   # provision a new tenant's schema
```

### Tenant resolution via elevator middleware

```ruby
# config/application.rb
config.middleware.use Apartment::Elevators::Subdomain   # or ::Domain, ::Generic
```

### Decision table

| Approach | Isolation | Ops cost | Use when |
|---|---|---|---|
| Row-level `account_id` (default) | App-layer | Lowest | Almost always |
| `ros-apartment` schemas (`use_schemas = true`) | Postgres schema | Migrations × tenants | Strong isolation, one DB, moderate tenant count |
| `ros-apartment` separate DB (`use_schemas = false`) | Physical DB | Highest | Regulatory hard isolation, large tenants |

---

## 6. `default_scope` caveats

A hand-rolled `default_scope { where(account_id: Current.account&.id) }` is tempting but
leaks in surprising ways ([Rails Guides — default_scope](https://guides.rubyonrails.org/active_record_querying.html#applying-a-default-scope)):

- It applies to `new`/`create`, silently stamping attributes you may not intend.
- It is inherited by associations and bites you in unexpected joins.
- `unscoped` strips it entirely — easy to forget you've removed tenant isolation.
- It evaluates `Current.account` at query time; in a job with no tenant set, it scopes
  to `account_id IS NULL` and silently returns nothing (or everything, if mis-built).

```ruby
# ❌ AVOID — hand-rolled tenant default_scope
class Post < ApplicationRecord
  default_scope { where(account_id: Current.account.id) }   # leaks into new/create, unscoped, joins
end

# ✅ PREFER — explicit scoping (§3) or acts_as_tenant (§4), which manages these caveats for you
```

Rule: **prefer explicit `Current.account.posts` scoping or `acts_as_tenant` over a
hand-rolled tenant `default_scope`.**

---

## 7. Tenant resolution

Resolve the tenant from the request, set `Current.account` (or 404), in this order:
custom domain → subdomain → 404.

### `before_action` + `request.subdomain`

```ruby
class ApplicationController < ActionController::Base
  before_action :set_current_account

  private

  def set_current_account
    account =
      Account.find_by(custom_domain: request.host) ||
      Account.find_by(subdomain: request.subdomain)

    return head :not_found unless account
    Current.account = account
  end
end
```

`request.subdomain` / `request.host` come from Action Dispatch
([Action Controller Overview](https://guides.rubyonrails.org/action_controller_overview.html)).

The request-level `before_action` is the single resolution point. Individual
controllers never re-resolve the tenant.

---

## 8. No unscoped queries except a documented Admin layer

The only code allowed to query across tenants is an explicit, clearly-namespaced
system/admin layer.

```ruby
# ✅ acceptable — clearly marked as system-level, lives in an Admin namespace
module Admin
  # System-level: returns ALL accounts. Not for tenant-facing code.
  def self.all_accounts
    Account.all
  end
end

# with acts_as_tenant strict mode, cross-tenant admin reads MUST use the escape hatch:
ActsAsTenant.without_tenant { Post.where(flagged: true) }
```

Any cross-tenant query outside this layer is a bug. Scoping is a **data boundary, not
authorization** — a valid scope says *which rows are visible*, never *which actions are
permitted*. Pair scoping with **Pundit** policies for the verbs:

```ruby
# ❌ WRONG — scope treated as the authorization check
post = Current.account.posts.find(id)   # visible, yes — but may THIS user delete it?
post.destroy

# ✅ CORRECT — scope for visibility, Pundit for the action
post = Current.account.posts.find(id)
authorize(post, :destroy?)              # Pundit
post.destroy
```

| Concern | Question | Mechanism |
|---|---|---|
| **Scoping** | Which records are visible to this request? | `Current.account` / `account_id` filter |
| **Authorization** | Which actions may this user perform on them? | Pundit policy |

---

## 9. Test Isolation

### Every test builds its own account

Never rely on a shared/global account. Each example creates its own.

```ruby
# ✅ CORRECT — each test owns its account
let(:account_a) { create(:account) }
let(:account_b) { create(:account) }
```

### Mandatory cross-tenant isolation spec per read

For **every** read path, assert that account A cannot see account B's rows. This is not
optional — it is the most important category of test in a multi-tenant system.

```ruby
it "does not return another account's posts" do
  account_a = create(:account)
  account_b = create(:account)
  mine   = create(:post, account: account_a)
  _other = create(:post, account: account_b)

  Current.account = account_a
  result = Posts::List.new.call.value!   # or Current.account.posts

  expect(result).to contain_exactly(mine)
ensure
  Current.reset
end
```

With `acts_as_tenant`, the same intent is expressed by setting the tenant and asserting
strict mode raises on an unscoped query:

```ruby
it "raises when no tenant is set under strict mode" do
  ActsAsTenant.current_tenant = nil
  expect { Post.count }.to raise_error(ActsAsTenant::Errors::NoTenantSet)
end
```
