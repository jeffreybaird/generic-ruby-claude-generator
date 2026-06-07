# Theming

> CSS-variable theming is universal; per-tenant theme loading is optional (include if multi-brand/multi-tenant).

Load this file when working on visual customization, template/layout selection, or branding configuration.

See also: `design-system.md` for token conventions, `multi-tenancy.md` for per-tenant data scoping.

> **Baseline:** Tailwind CSS (tailwindcss-rails) · CSS custom properties for tokens · ViewComponent for reusable components · ERB templates. Tokens are CSS variables — overridable per tenant.

**Maturity tags:** **[core]** apply to every project · **[recommended]** strong default, skip only with reason · **[optional]** include only if the app needs it (e.g. multi-tenant / multi-brand).

---

## Approach — CSS variables are the single customization point **[core]**

Theming is **CSS custom properties** set from a stored theme configuration. Templates and components consume those variables; they never hold hardcoded colors, fonts, or radii.

This gives you **one CSS bundle for every brand**. The only thing that changes per brand or tenant is the `:root` / `[data-theme]` variable block injected into the layout. No asset rebuild, no per-tenant stylesheet.

- **Single-brand apps:** write the variable block once, statically, in your compiled CSS or layout `<head>`.
- **Multi-brand / multi-tenant apps:** load values from a stored `Theme` record per tenant and server-render them at request time.

```erb
<%# ✅ component reads variables — re-brands for free %>
<style>.card { background: var(--surface); border-radius: var(--radius); color: var(--text-primary); }</style>

<%# ❌ hardcoded — bypasses theming, cannot be overridden per tenant %>
<style>.card { background: #1a1a1a; border-radius: 12px; }</style>
```

Tailwind layout utilities (flex, grid, spacing, breakpoints) are fine. The variable rule applies only to **brand-customizable** properties: colors, fonts, radii, and similar identity values.

---

## Per-tenant theming — server-render a `:root` block **[optional]**

For multi-tenant apps, render an inline `<style>` `:root` block in the layout from the tenant's stored `Theme`. Inline injection means **zero latency** — styles apply on first paint, no extra request, no flash of unbranded content.

```erb
<%# app/views/layouts/application.html.erb %>
<!DOCTYPE html>
<html data-theme="<%= Current.theme.base_theme || "light" %>">
  <head>
    <%= stylesheet_link_tag "tailwind", "data-turbo-track": "reload" %>
    <% theme = Current.theme %>
    <style>
      :root {
        --accent:       <%= theme.brand_primary %>;
        --accent-2:     <%= theme.brand_secondary %>;
        --surface:      <%= theme.surface %>;
        --text-primary: <%= theme.text_primary %>;
        --font-body:    "<%= theme.font_body %>", system-ui, sans-serif;
        --font-display: "<%= theme.font_display %>", system-ui, sans-serif;
        --radius:       <%= theme.border_radius %>;
      }
    </style>
    <link rel="icon" href="<%= theme.favicon_url %>">
  </head>
  <body><%= yield %></body>
</html>
```

Resolve `Current.theme` in a `before_action` from the request's tenant (`Current` attributes per [guides.rubyonrails.org/active_support_core_extensions.html#current-attributes](https://guides.rubyonrails.org/active_support_core_extensions.html)). All values are HTML-escaped by ERB; validate/sanitize color and URL fields on write so the inline block can't be used for injection.

This composes with the `data-theme` light/dark switch from `design-system.md`: `data-theme` picks the light/dark base, the inline `:root` block re-tints brand tokens on top.

---

## Theme schema **[optional]**

Store one row per tenant/brand. The fields map 1:1 to the CSS variables above.

```ruby
create_table :themes do |t|
  t.references :organization, foreign_key: true   # omit for single-brand

  # Colors
  t.string :brand_primary,   default: "#1a73e8", null: false
  t.string :brand_secondary, default: "#174ea6", null: false
  t.string :surface,         default: "#ffffff", null: false
  t.string :background,      default: "#fafafa", null: false
  t.string :text_primary,    default: "#111111", null: false
  t.string :text_secondary,  default: "#555555", null: false
  t.string :accent,          default: "#e8901a", null: false
  t.string :base_theme,      default: "light",   null: false  # light | dark

  # Typography
  t.string :font_display, default: "Inter"
  t.string :font_body,    default: "Inter"

  # Shape
  t.string :border_radius,      default: "8px"
  t.string :card_border_radius, default: "12px"

  # Assets — URLs, not blobs
  t.string :logo_url
  t.string :favicon_url

  # Structure
  t.string :template_name, default: "default", null: false

  t.timestamps
end
```

Validate color fields (hex/oklch) and URL fields on write.

---

## Asset storage — logos & favicons **[optional]**

Never store binary file data in Postgres. Store an object-store URL on the theme row.

| Upload mechanism | Reference |
|---|---|
| **Active Storage** → S3 / Tigris / R2 service; persist `logo.url` (or a signed/CDN URL) on the theme | [guides.rubyonrails.org/active_storage_overview.html](https://guides.rubyonrails.org/active_storage_overview.html) |

```ruby
# app/models/my_app/theme.rb
class MyApp::Theme < ApplicationRecord
  has_one_attached :logo
  has_one_attached :favicon
  def logo_url = logo.attached? ? url_for(logo) : self[:logo_url]
end
```

For an MVP, accepting a hosted URL (admin pastes a link) is fine — wire direct upload later without changing the layout, since the layout only reads `theme.logo_url`.

---

## Layout / template variants — structure only **[optional]**

A stored `template_name` selects a layout/structure variant. Variants control **structure only** — they all consume the same CSS variables, so brand colors/fonts stay consistent across templates.

```ruby
# app/controllers/concerns/themed_layout.rb
module ThemedLayout
  extend ActiveSupport::Concern
  included { layout :resolve_template }
  private
  def resolve_template = "templates/#{Current.theme&.template_name || "default"}"
end
```

```
app/views/layouts/templates/
├── default.html.erb
├── minimal.html.erb
└── bold.html.erb        # each is layout structure only; all use the same tokens
```

### Template rules **[core]**

- Every variant implements the same required files/blocks. Missing file → fall back to `default`.
- Templates control structure and layout only. **No business logic** — no DB queries, no API calls, no auth/subscription conditionals. That lives in the controller/handler; the template renders passed-in locals/assigns.
- All variants consume the same CSS custom properties for color and typography.

```erb
<%# ❌ business logic in a template %>
<% if current_user.subscription.active? && Order.where(user: current_user).any? %> … <% end %>

<%# ✅ controller computed it; template just renders %>
<% if @show_orders %> … <% end %>
```

---

## Absolute Rules — Never Violate **[core]**

- Never hardcode brand colors/fonts/radii in templates — read CSS variables.
- Never store binary asset data in Postgres — store object-store URLs.
- Never put business logic in a layout/template variant.
- Never inject unvalidated theme values into the inline `<style>` block — validate color/URL fields on write.
- Ship one CSS bundle; per-tenant change is the `:root` variable block only.
