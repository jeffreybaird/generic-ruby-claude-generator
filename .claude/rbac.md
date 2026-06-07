# RBAC & the Authentication Boundary — Roles, Policies, Three Layers

Load this file when adding login/signup, a role check, a Pundit policy, an admin
namespace, or any "can this user do X" decision. This is where the project draws
the line between **who you are**, **which rows you can touch**, and **which
actions you may perform** — and keeps all three out of the controller.

> **Baseline:** Authentication via Rails 8 built-in generator (or Devise); authorization via Pundit (policies). Roles on the Membership join (per-account). Authorization (actions) is separate from tenant scoping (data) and authentication (identity).

Maturity tags: <span title="stable">`[stable]`</span> ship it · <span title="mature">`[mature]`</span> proven, heavier · <span title="emerging">`[emerging]`</span> verify before relying.

---

## The three layers — keep them distinct

This is the conceptual spine. A request passes through all three; each answers a
different question and lives in a different place. **A valid scope still needs
authorization** — being able to *see* a row does not mean you may *act* on it.

| Layer | Question | Where it lives | Failure |
|---|---|---|---|
| **Authentication** | *Who are you?* | Rails auth generator / Devise; session or token. Sets `Current.user`. | redirect to login / `401` |
| **Tenant scoping** | *Which rows may you touch?* | The current-account association (`Current.account.posts`). See `multi-tenancy.md`. | `404`/`:not_found` (row not in scope) |
| **Authorization** | *Which actions may you perform?* | Pundit policies, checked in the service. | `403`/`:forbidden` |

```ruby
# ❌ collapsing the layers — "found it, so let them edit it"
post = Current.account.posts.find(params[:id])   # scope only
post.update!(post_params)                          # no authorization!

# ✅ scope finds the row; the policy decides the action
post = Current.account.posts.find(params[:id])     # tenant scope
authorize post                                     # authorization (Pundit)
post.update!(post_params)
```

The sibling `separation-of-concerns.md` (lines on `Current` / scope-vs-auth) is
the authority on the controller boundary; **this file is the authority on all
three layers together**. Cross-link, don't contradict: scoping rides the
association, authorization rides the policy, both belong in the service.

---

## 1. Authentication

Authentication establishes identity only. It never decides what an identity may
do — that's authorization (§3).

### Built-in generator (default) <span title="stable">`[stable]`</span>

Rails 8 ships an authentication generator. Prefer it for new apps; no dependency.

```sh
bin/rails generate authentication
```

It creates `User` and `Session` models plus the controllers/views to log in,
adds the `bcrypt` gem, and wires `has_secure_password`
([Getting Started](https://guides.rubyonrails.org/getting_started.html),
[Rails 8.0 release notes](https://guides.rubyonrails.org/8_0_release_notes.html)).
It is session + password based and magic-link/password-reset ready.

```ruby
# The model the generator produces (shape)
class User < ApplicationRecord
  has_secure_password                       # bcrypt; provides #authenticate
  has_many :sessions, dependent: :destroy
  normalizes :email_address, with: ->(e) { e.strip.downcase }
end
```

`has_secure_password` is the building block either way — it adds `password`/
`password_confirmation` and `#authenticate`
([ActiveModel::SecurePassword](https://api.rubyonrails.org/classes/ActiveModel/SecurePassword/ClassMethods.html)).

### Devise (mature alternative) <span title="mature">`[mature]`</span>

Reach for Devise when you need confirmable/recoverable/lockable/OmniAuth out of
the box. Heavier; pin `~> 4.9` (the line that supports Rails 8)
([devise](https://github.com/heartcombo/devise)).

```ruby
gem "devise", "~> 4.9"   # mature; brings its own controllers/routes
```

---

## 2. Roles live on the Membership join — never on User

A user belongs to many accounts and holds a **different role per account**. Put
the role on the `Membership` (the `User` ↔ `Account` join), not on `User`.

```ruby
# ❌ role on the user — a global role makes no sense in a multi-account app
class User < ApplicationRecord
  enum :role, { member: 0, admin: 1 }   # admin of WHAT? every account?
end

# ✅ role on the membership — scoped to one account
class Membership < ApplicationRecord
  belongs_to :user
  belongs_to :account
  # hierarchy order matters: declare low → high for role_at_least?
  enum :role, { member: 0, editor: 1, admin: 2, owner: 3 }
end
```

Rails 8 documents the **positional** enum form `enum :role, { ... }` — prefer
it. The keyword form `enum role: { ... }` is the older syntax
([ActiveRecord::Enum](https://api.rubyonrails.org/classes/ActiveRecord/Enum.html)).

Enums give predicates and scopes (`membership.admin?`, `Membership.admin`) but
**no ordered comparison**. The hierarchy helper must be implemented explicitly,
and works only because the enum is declared in ascending order:

```ruby
class Membership < ApplicationRecord
  enum :role, { member: 0, editor: 1, admin: 2, owner: 3 }

  # owner > admin > editor > member
  def role_at_least?(min)
    self.class.roles.fetch(role) >= self.class.roles.fetch(min.to_s)
  end
end

membership.role_at_least?(:editor)   # admin → true; member → false
```

For a richer model (resource-scoped roles, dynamic role assignment), use
`rolify` <span title="mature">`[mature]`</span> (`~> 6.0`)
([rolify](https://github.com/RolifyCommunity/rolify)) — but keep roles attached
to the membership/account context, not floating globally.

**Exactly one owner per account.** Enforce with a partial unique index, and make
ownership transfer an **explicit, audited** action — never a plain role edit.

```ruby
# migration
add_index :memberships, :account_id, unique: true,
          where: "role = 3", name: "index_one_owner_per_account"
```

```ruby
# ✅ transfer is its own service, audited (see architecture-decisions.md)
MyApp::Accounts::TransferOwnership.call(account:, from:, to:, actor:)
# demotes old owner → admin, promotes new owner, in a transaction, audited
```

---

## 3. Authorization via Pundit (default)

Policy classes answer "may this actor do this?". One policy per resource; one
predicate per action.

### Pundit <span title="stable">`[stable]`</span> — community default

Pin `~> 2.3` ([pundit](https://github.com/varvet/pundit)).

```ruby
# app/policies/post_policy.rb
class PostPolicy < ApplicationPolicy
  def update?
    membership&.role_at_least?(:editor)   # uses the hierarchy helper, §2
  end

  def destroy?
    membership&.role_at_least?(:admin)
  end

  # policy_scope: which rows may this actor enumerate
  class Scope < ApplicationPolicy::Scope
    def resolve = scope.where(account: Current.account)
  end

  private

  # Look up the membership against the RECORD's account, not Current — so a
  # different-account actor resolves to nil (→ forbidden), and the policy is
  # spec-able in isolation. find_by returns nil, never raises.
  def membership
    record.account.memberships.find_by(user:)
  end
end
```

Controller usage — `authorize` raises `Pundit::NotAuthorizedError` (→ rescue to
`403`/`:forbidden`); `policy_scope` filters lists; `verify_authorized` /
`verify_policy_scoped` as `after_action` guarantee you didn't forget:

```ruby
class PostsController < ApplicationController
  after_action :verify_authorized, except: :index
  after_action :verify_policy_scoped, only: :index

  def index  = (@posts = policy_scope(Post))
  def update = (authorize(@post = Current.account.posts.find(params[:id])); ...)
end
```

### CanCanCan <span title="mature">`[mature]`</span> — alternative

Single central `Ability` class instead of per-resource policies. Pin `~> 3.5`
([cancancan](https://github.com/CanCanCommunity/cancancan)).

```ruby
class Ability
  include CanCan::Ability
  def initialize(user, account)
    m = account.memberships.find_by(user:)
    can :manage, :all if m&.role_at_least?(:owner)
    can [:update], Post if m&.role_at_least?(:editor)
  end
end
# controller: authorize! :update, @post   /   load_and_authorize_resource
```

### Pundit vs CanCanCan

| Want | Pick | Why |
|---|---|---|
| Per-resource policy objects, explicit `authorize` calls | **Pundit** | Logic co-located with the resource; easy to spec in isolation |
| One central ability map, `load_and_authorize_resource` | **CanCanCan** | Fewer files; abilities readable in one place |
| `policy_scope` for list filtering as a first-class idiom | **Pundit** | Scope is a named inner class per resource |
| Lots of similar rules across many models | **CanCanCan** | DRY central definition |
| Default for this template | **Pundit** | Matches `separation-of-concerns.md` baseline |

Don't run both. `authorize`, `policy_scope`, `verify_authorized` are the stable
Pundit surface.

---

## 4. Enforce in controllers AND re-check in services (defense in depth)

The controller is the first gate, **not the only gate**. A service may be called
by a Rails action today and a JSON API, an Active Job, or a CLI tomorrow — none
of which ran the controller's `authorize`. So the **service authorizes too**.

```ruby
# ✅ service is the real boundary — it authorizes regardless of caller
module MyApp::Posts
  class Update
    def self.call(...) = new(...).call

    def initialize(actor:, account:, post_id:, attrs:)
      @actor, @account, @post_id, @attrs = actor, account, post_id, attrs
    end

    def call
      post = @account.posts.find(@post_id)              # tenant scope
      Pundit.authorize(@actor, post, :update?)          # authorization
      post.update!(@attrs)
      Success(post)
    rescue ActiveRecord::RecordNotFound then Failure([:not_found])
    rescue Pundit::NotAuthorizedError   then Failure([:forbidden])
    rescue ActiveRecord::RecordInvalid => e then Failure([:validation, e.record.errors])
    end
  end
end
```

```ruby
# ❌ service trusts that "the controller already checked" — false for API/job/CLI callers
def call
  @account.posts.find(@post_id).update!(@attrs)   # no authorize → privilege escalation
  Success(...)
end
```

**Views** show/hide UI with the policy — never re-derive the rule:

```erb
<%# ✅ %>      <%= link_to "Edit", edit_post_path(@post) if policy(@post).update? %>
<%# ❌ %>      <%= link_to "Edit", edit_post_path(@post) if Current.membership.role == "admin" %>
```

---

## 5. Super admin — bypass scope only in an Admin namespace

A platform operator sometimes needs to cross tenant boundaries (support, billing
ops). Model it as a **platform-level flag** on `User` (not a membership role),
and let it bypass tenant scope **only inside an explicit `Admin::` namespace** —
never in tenant-facing code.

```ruby
class User < ApplicationRecord
  # platform flag — distinct from per-account Membership roles (§2)
  # `super_admin: boolean, default: false, null: false`
end
```

```ruby
# ❌ super-admin check leaking into tenant code — every read now branches on it
def index
  @posts = Current.user.super_admin? ? Post.all : Current.account.posts
end

# ✅ tenant controllers always scope; cross-tenant access is a separate namespace
module Admin
  class PostsController < Admin::BaseController
    before_action :require_super_admin            # the ONLY place scope is bypassed
    def index = (@posts = Post.all)               # documented cross-scope read
  end
end
```

Cross-scope `Admin::` access is the documented exception (see `multi-tenancy.md`
and the "Contexts are the public API" rule). Audit every super-admin action,
including impersonation context.

---

## 6. Anti-patterns — never compare role strings inline

A bare string/predicate comparison scattered through controllers and views is
the classic RBAC bug: the hierarchy is implicit, untestable, and drifts.

```ruby
# ❌ implicit hierarchy, duplicated everywhere, breaks when roles change
redirect_to root_path unless membership.role == "admin"
@can_edit = membership.role == "admin" || membership.role == "owner"
return head :forbidden unless %w[admin owner].include?(membership.role)
```

```ruby
# ✅ one helper / one policy owns the hierarchy
authorize @post                              # in a controller (Pundit)
membership.role_at_least?(:admin)            # the hierarchy helper (§2)
policy(@post).update?                        # in a view
```

| Smell | Fix |
|---|---|
| `role == "admin"` | `role_at_least?(:admin)` or a policy predicate |
| `%w[admin owner].include?(role)` | `role_at_least?(:admin)` (hierarchy) |
| Role check in a view | `policy(record).action?` |
| Role check in a controller `if` | `authorize record` |
| `super_admin?` inside tenant code | move to `Admin::` namespace (§5) |

---

## 7. Tests — three axes per protected action

Every protected action gets **three** tests. Authorization bugs hide in the gaps
between them, so all three are mandatory (this is the ported Phoenix rule).

| Axis | Setup | Expect |
|---|---|---|
| **Sufficient role succeeds** | actor with role ≥ required, in scope | `Success` / `2xx`/`3xx` |
| **Insufficient role denied** | actor in the account but role too low | `Failure([:forbidden])` / `403` |
| **Different account denied** | actor with a high role but in **another** account | `Failure([:not_found])` (scope) — not `403` |

The third axis is the one people forget: a different-account actor must be
rejected by **scope** (`:not_found`), proving authorization never even runs on
out-of-scope rows. That keeps layers 2 and 3 (§the three layers) honest.

### Pundit policy specs <span title="stable">`[stable]`</span>

```ruby
# spec/policies/post_policy_spec.rb
RSpec.describe PostPolicy do
  subject { described_class.new(user, post) }
  let(:post) { create(:post, account:) }
  let(:account) { create(:account) }

  context "editor in the account" do
    let(:user) { membership(account, :editor).user }
    it { is_expected.to permit_action(:update) }    # axis 1
    it { is_expected.to forbid_action(:destroy) }   # axis 2 (needs admin)
  end

  context "admin in a different account" do
    let(:user) { membership(create(:account), :admin).user }
    it { is_expected.to forbid_action(:update) }    # axis 3 — wrong account
  end
end
```

`permit_action` / `forbid_action` ship with `pundit/rspec`
([pundit — testing](https://github.com/varvet/pundit#rspec)). Spec the **scope**
class too (`PostPolicy::Scope`) — confirm it returns in-account rows and excludes
others. And per the project rule: every policy predicate and every `Failure`
branch in the service gets a test.

---

## Gem reference (loose pins)

| Gem | Pin | Maturity | Role |
|---|---|---|---|
| `pundit` | `~> 2.3` | <span title="stable">`[stable]`</span> | Authorization policies (default) |
| `cancancan` | `~> 3.5` | <span title="mature">`[mature]`</span> | Authorization (central ability, alt) |
| `devise` | `~> 4.9` | <span title="mature">`[mature]`</span> | Authentication (alt to the generator) |
| `rolify` | `~> 6.0` | <span title="mature">`[mature]`</span> | Dynamic/resource-scoped roles |
| `bcrypt` | `~> 3.1` | <span title="stable">`[stable]`</span> | Password hashing (`has_secure_password`) |

The Rails 8 auth generator needs **no gem** beyond `bcrypt`.

---

## Related docs

- `separation-of-concerns.md` — controller/route vs service boundary; where `authorize` is called; `Current` scope-vs-authorization
- `multi-tenancy.md` — tenant scoping, the current-account association, `Admin::` cross-scope exception
- `architecture-decisions.md` — Result/error tags (`:forbidden`, `:not_found`), audit logging (ownership transfer, super-admin actions)
- `testing.md` — RSpec/Minitest patterns, factories, request specs
