# Frontend Map

> Template — fill in with your app's actual routes, controllers, views, Stimulus controllers, Turbo usage, and layouts. Replace every `<placeholder>` and the example rows.

> **Baseline:** Rails 8 (resourceful routes, Hotwire). Keep this map current — it's how Claude navigates the UI.

Quick-reference for navigating `MyApp`'s frontend layer. It is the first stop for any
developer — or Claude — orienting to the UI. When routes, views, Stimulus controllers, or
Turbo frames change, update this file in the same commit.

---

## Stack

State the frontend stack this app uses so readers know which sections apply.

- **Framework:** Rails 8
- **Front-end:** Hotwire (Turbo + Stimulus) via importmap / jsbundling, or your bundler
- **Templating:** ERB / ViewComponent / Slim / Haml (pick what `my_app` uses)
- **CSS:** Tailwind / Propshaft + plain CSS / Sass (note which)

---

## Layout Hierarchy

Document the nesting of your layouts and which controllers/actions render inside each. A
typical app has one application layout plus shells differentiated by audience (public,
authenticated, admin).

Layouts live in `app/views/layouts/`. Controllers select a layout via `layout "name"`.

```
application.html.erb                  ← HTML skeleton, meta tags, <%= yield %>, asset tags
├── layouts/public.html.erb           ← Public shell: header, nav, footer
│   └── Public controllers            ← e.g. HomeController, PostsController#index/#show
├── layouts/admin.html.erb            ← Admin shell: sidebar + main
│   └── Admin::* controllers          ← e.g. Admin::DashboardController, Admin::PostsController
└── layouts/auth.html.erb             ← Minimal shell for auth flows
    └── Sessions / Registrations / Passwords controllers
```

Replace these with your actual layout files. Add or remove branches to match your
audience splits.

---

## Route → Controller/Action Map

List every significant route. Group by audience. Note auth requirements and special
behavior. Keep the "Notes" column to one phrase per route.

> **Rails:** routes are defined in `config/routes.rb`. Use `bin/rails routes` to dump the
> full table. See <https://guides.rubyonrails.org/routing.html>.

### Public Routes

Accessible to unauthenticated visitors, or with optional auth.

| Path & verb            | Controller#action                            | Auth | Notes |
|------------------------|----------------------------------------------|------|-------|
| `GET /`                | `<HomeController#index>`                      | None | Landing page |
| `GET /<resources>`     | `<ResourcesController#index>`                 | None | Browse/search |
| `GET /<resources>/:id` | `<ResourcesController#show>`                  | None | Single resource detail |
| `GET /sign_up`         | `<RegistrationsController#new>`               | None | New user signup |
| `GET /sign_in`         | `<SessionsController#new>`                    | None | Login form |

_Example row (delete when filled):_
| `GET /posts`           | `PostsController#index`                       | None | Paginated public post list |

### Authenticated User Routes

Require a logged-in user.

| Path & verb                  | Controller#action                   | Notes |
|------------------------------|--------------------------------------|-------|
| `GET /account`               | `<AccountsController#edit>`          | Profile, email, password |
| `GET /<resources>/new`       | `<ResourcesController#new>`          | Create form |
| `POST /<resources>`          | `<ResourcesController#create>`       | Create resource |
| `GET /<resources>/:id/edit`  | `<ResourcesController#edit>`         | Edit owned resource |
| `PATCH /<resources>/:id`     | `<ResourcesController#update>`       | Update owned resource |

_Example row (delete when filled):_
| `GET /posts/new`             | `PostsController#new`                | Author-only create form |

### Admin Routes (`/admin/*` — requires admin role)

| Path & verb                       | Controller#action                    | Notes |
|-----------------------------------|---------------------------------------|-------|
| `GET /admin`                      | `<Admin::DashboardController#index>`  | Platform overview, KPIs |
| `GET /admin/<resources>`          | `<Admin::ResourcesController#index>`  | List + manage all |
| `GET /admin/<resources>/new`      | `<Admin::ResourcesController#new>`    | Admin create |
| `GET /admin/<resources>/:id`      | `<Admin::ResourcesController#show>`   | Admin detail |
| `GET /admin/<resources>/:id/edit` | `<Admin::ResourcesController#edit>`   | Admin edit |
| `GET /admin/users`                | `<Admin::UsersController#index>`      | User management |
| `GET /admin/settings`             | `<Admin::SettingsController#edit>`    | App-wide config |

_Example row (delete when filled):_
| `GET /admin/posts`                | `Admin::PostsController#index`        | Manage all posts across users |

### Auth Routes

| Path & verb            | Controller#action                     | Notes |
|------------------------|----------------------------------------|-------|
| `GET /sign_up`         | `<RegistrationsController#new>`        | New user signup |
| `POST /sign_up`        | `<RegistrationsController#create>`     | Create account |
| `GET /sign_in`         | `<SessionsController#new>`             | Login form |
| `POST /sign_in`        | `<SessionsController#create>`          | Create session |
| `DELETE /sign_out`     | `<SessionsController#destroy>`         | Log out |
| `GET /password/reset`  | `<PasswordsController#new>`            | Request reset |

### API / Non-HTML Routes

| Path & verb              | Controller#action                    | Notes |
|--------------------------|---------------------------------------|-------|
| `POST /webhooks/<svc>`   | `<Webhooks::ServiceController#create>`| Inbound webhook receiver |
| `GET /up`                | Rails health check (built-in)         | Liveness probe (`/up` ships with Rails 8) |
| `GET /api/<resources>`   | `<Api::ResourcesController#index>`    | JSON API, if applicable |

_Example row (delete when filled):_
| `POST /webhooks/stripe`  | `Webhooks::StripeController#create`   | Stripe event receiver |

---

## Views / Templates

List your view directories and notable templates/partials by area. For ViewComponent
projects, list components instead of (or alongside) partials.

> **Rails:** templates live in `app/views/<controller>/<action>.html.erb`; partials are
> `_name.html.erb`; ViewComponents live in `app/components/`. See
> <https://guides.rubyonrails.org/action_view_overview.html>.

| Area / view             | File                                         | Purpose |
|-------------------------|----------------------------------------------|---------|
| Public layout shell     | `app/views/layouts/public.html.erb`          | Header, nav, footer |
| Admin layout shell      | `app/views/layouts/admin.html.erb`           | Sidebar, top bar |
| Shared flash            | `app/views/shared/_flash.html.erb`           | `aria-live` flash region |
| Resource list           | `app/views/<resources>/index.html.erb`       | Listing + pagination |
| Resource card partial   | `app/views/<resources>/_card.html.erb`       | Reused in index + search |
| Resource form partial   | `app/views/<resources>/_form.html.erb`       | Shared by new + edit |

_Example row — ViewComponent (delete when filled):_
| Post card component     | `app/components/post_card_component.rb` (+ `.html.erb`) | Reusable post preview, used in index + search |

---

## Stimulus Controllers

List every Stimulus controller, where it lives, what DOM it attaches to, and what it does.
Keep behavior thin — controllers are DOM/JS bridges, not business logic.

> **Rails:** controllers live in `app/javascript/controllers/`, named `<name>_controller.js`,
> attached via `data-controller="<name>"`. See <https://stimulus.hotwired.dev/handbook/introduction>.

| Controller (`data-controller`) | File                                       | Targets / actions | Purpose |
|--------------------------------|--------------------------------------------|-------------------|---------|
| `<name>`                       | `app/javascript/controllers/<name>_controller.js` | `<targets>` / `<actions>` | `<what it does>` |

_Example rows (delete when filled):_
| `dropdown`                     | `controllers/dropdown_controller.js`       | `menu` target; `toggle` action | Toggles a disclosure menu, manages `aria-expanded` |
| `infinite-scroll`              | `controllers/infinite_scroll_controller.js`| `sentinel` target              | Loads next page when sentinel enters viewport |
| `clipboard`                    | `controllers/clipboard_controller.js`      | `source` target; `copy` action | Copies text to clipboard, shows confirmation |

For each controller, note the `data-action` events it binds and any `data-*-value` inputs it reads.

---

## Turbo Frames & Streams

Document where Hotwire Turbo is used so partial-update behavior is discoverable.

> **Rails:** see <https://turbo.hotwired.dev/handbook/frames> and
> <https://turbo.hotwired.dev/handbook/streams>. Streams are typically delivered via
> `turbo_stream` responses or broadcast over Action Cable.

### Turbo Frames

| Frame `id`              | Rendered in (view)                    | Purpose / lazy-load src |
|-------------------------|----------------------------------------|--------------------------|
| `<frame_id>`            | `<view>`                               | `<inline edit / lazy load / pagination>` |

_Example row (delete when filled):_
| `post_<id>`             | `app/views/posts/_post.html.erb`       | Inline edit without full page reload |

### Turbo Streams

| Trigger / action               | Stream target & action          | Purpose |
|--------------------------------|----------------------------------|---------|
| `<action that emits stream>`   | `<append/replace/remove #id>`    | `<what updates>` |

_Example rows (delete when filled):_
| `PostsController#create`       | `append #posts`                  | Adds new post to the list without reload |
| `Comment` broadcast (Action Cable) | `prepend #comments`         | Live comment delivery to subscribers |

For each stream, note whether it is a direct response (`format.turbo_stream`) or a
broadcast (`broadcast_append_to` / `Turbo::StreamsChannel`). Streamed updates that change
visible content MUST land in an `aria-live` region — see `a11y-audit.md`.

---

## Layouts → Pages Map

State which layout each area renders under (mirror of the hierarchy above, but indexed by page).

| Area / controller            | Layout used                          | Notes |
|------------------------------|--------------------------------------|-------|
| Public pages                 | `layouts/public`                     | Header + footer, no auth chrome |
| Authenticated user pages     | `layouts/application`                | Includes user menu |
| Admin pages                  | `layouts/admin`                      | Sidebar nav |
| Auth flows                   | `layouts/auth`                       | Minimal, centered card |

---

## CSS Architecture

Describe your styling approach so contributors know where styles live and how to extend them.

- **Framework** — Tailwind / Sass / plain CSS. Where utility classes vs. component classes are used.
- **Pipeline** — Propshaft (Rails 8 default) / Sprockets / cssbundling. Entry file location.
- **Custom properties** — if you inject CSS custom properties for theming, document the
  prefix, where they are set, and what controls them.
- **File locations** — `app/assets/stylesheets/application.css` for global styles.
- **Conventions** — e.g. no hardcoded color values in templates; all colors via variables.

_Example (delete when filled):_
- Tailwind utility-first; component classes for repeated admin UI.
- Propshaft serving `app/assets/builds/`; Tailwind built via `bin/rails tailwindcss:build`.
- `--app-*` custom properties for theming, set on `.app-root`.
- No hardcoded hex values in templates — reference a CSS variable or Tailwind token.

---

## Authentication / Authorization

Document how auth is enforced at the request layer.

> **Rails:** typically `before_action` filters in `ApplicationController` and subclasses,
> or a concern. See <https://guides.rubyonrails.org/action_controller_overview.html#filters>.
> Rails 8 ships a built-in authentication generator (`bin/rails generate authentication`).

| Filter / before_action              | Applied to                  | Purpose |
|--------------------------------------|-----------------------------|---------|
| `<require_authentication>`           | `<authenticated controllers>` | Redirects to sign-in if no session |
| `<require_admin>`                    | `<Admin::* controllers>`    | 403 / redirect unless admin role |
| `<set_current_user>`                 | `ApplicationController`     | Loads current user from session if present |

_Example rows (delete when filled):_
| `before_action :require_authentication` | `AccountsController`     | Redirects unauthenticated users to `/sign_in` |
| `before_action :require_admin`          | `Admin::BaseController`  | Checks `Current.user.admin?`; redirects otherwise |

---

## Where to Find Things

Quick orientation index. Update paths to match your actual project structure.

| What you are looking for         | Where to look |
|----------------------------------|---------------|
| Route definitions                | `config/routes.rb` (`bin/rails routes` to dump) |
| Controllers                      | `app/controllers/` |
| Views / templates                | `app/views/` |
| Layouts                          | `app/views/layouts/` |
| ViewComponents (if used)         | `app/components/` |
| Stimulus controllers             | `app/javascript/controllers/` |
| JS entry / importmap             | `app/javascript/application.js`, `config/importmap.rb` |
| Global CSS                       | `app/assets/stylesheets/application.css` |
| Static assets                    | `app/assets/`, `public/` |
| Business logic (models/services) | `app/models/`, `app/services/` |
| System / integration tests       | `test/system/`, `test/integration/` (or `spec/`) |
</content>
</invoke>
