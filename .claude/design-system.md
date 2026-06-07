# Design System

> Template — fill in with your project's design tokens, components, and tone. Replace every `<placeholder>` and the `MyApp` / `my_app` names.

This file is the authoritative reference for all frontend work on `<project name>`. Read it before writing any template, component, view, or CSS. Follow conventions already established in the codebase — discover before building.

> **Baseline:** Tailwind CSS (tailwindcss-rails on Rails, standalone CLI on Sinatra) · CSS custom properties for tokens · ViewComponent (Rails) for reusable components · ERB templates. Tokens are CSS variables — overridable per tenant.

**Maturity tags:** **[core]** apply to every project · **[recommended]** strong default, skip only with reason · **[optional]** include only if the app needs it.

---

## Identity — fill in

`<Project name>` is a `<one-sentence description of the product and audience>`.

Aesthetic: `<describe the intended look and feel — e.g., "clean and professional", "warm and editorial", "bold and playful">`. The user should feel `<emotional goal — e.g., "in control", "at home", "delighted">`.

Tone: `<adjectives — e.g., "direct, friendly, confident">`. Not `<what it should NOT feel like>`.

---

## Stack — dual-framework **[core]**

The token system, component principles, and accessibility rules are identical across both frameworks. Only the build tooling and the component primitive differ.

| Concern | Rails 8 | Sinatra 4 |
|---|---|---|
| Tailwind install | `tailwindcss-rails` (standalone, no Node) **or** `cssbundling-rails` (npm/esbuild) ([guides.rubyonrails.org/asset_pipeline](https://guides.rubyonrails.org/asset_pipeline.html)) | Tailwind standalone CLI ([tailwindcss.com/blog/standalone-cli](https://tailwindcss.com/blog/standalone-cli)) |
| Build command | `bin/rails tailwindcss:watch` (dev) / runs in `bin/dev` via Procfile | `tailwindcss -i app.css -o public/css/app.css --watch` |
| Reusable component | **ViewComponent** ([viewcomponent.org](https://viewcomponent.org/)) — testable, encapsulated | ERB partials + helper methods |
| Template engine | ERB (`.html.erb`) | ERB (`.erb`) via `erb`/Tilt |
| Client interactivity | Stimulus (Hotwire) ([stimulus.hotwired.dev](https://stimulus.hotwired.dev/)) | Stimulus standalone or plain JS modules |
| Icon set | `<e.g., Heroicons via heroicon gem / inline SVG partials>` | `<e.g., inline SVG partials>` |

- **tailwindcss-rails** ships the standalone binary — no Node toolchain required ([github.com/rails/tailwindcss-rails](https://github.com/rails/tailwindcss-rails)). Prefer it unless you already run a JS bundler, in which case use `cssbundling-rails`.
- Font sources: `<Google Fonts / self-hosted / system only>`. Custom font upload: `<supported / not supported>`.

---

## Codebase Conventions — Discover Before Building **[core]**

Before creating any file, component, or template, read the existing codebase to understand:

- **Rails:** how controllers/views are organized, where `ViewComponent`s live (`app/components/`), how `application.html.erb` and partials are structured, how routes map to actions.
- **Sinatra:** the route/handler layout (`app.rb` or modular `Sinatra::Base` subclasses), where `views/` and partials live, what layout file is in use.
- How CSS is built and where the compiled bundle is served from.
- How authentication and the current-tenant lookup work (relevant to per-tenant theming).

Follow existing conventions exactly. Do not introduce new organizational patterns unless none exists for the type of thing you are building.

---

## Color & Token System **[core]**

All design values — colors, surfaces, accents, type scale, radii, spacing accents — are **CSS custom properties**. Use semantic token names in templates and component CSS. Never write hardcoded hex/rgb/raw color in a template, component, or utility class.

### Where tokens live

Define tokens once in a **base CSS layer**, then expose them to Tailwind so utilities resolve to them.

- **Tailwind v4 (CSS-first):** there is no `tailwind.config.js`. Declare your theme with the `@theme` directive in your main CSS file, and base tokens in `@layer base` ([tailwindcss.com/docs/theme](https://tailwindcss.com/docs/theme), [tailwindcss.com/docs/functions-and-directives#theme-directive](https://tailwindcss.com/docs/functions-and-directives#theme-directive)).
- **Tailwind v3:** declare tokens as CSS variables in `@layer base`, and map them in `tailwind.config.js` `theme.extend.colors` (e.g. `surface: 'var(--surface)'`) ([v3.tailwindcss.com/docs/configuration](https://v3.tailwindcss.com/docs/configuration)).

Note both versions ship with `tailwindcss-rails`; check the gem version to know which directive set applies.

```css
/* app/assets/stylesheets/application.tailwind.css (Rails) or app.css (Sinatra) */

/* 1. Base token layer — single source of truth */
@layer base {
  :root {
    --bg:            oklch(98% 0 0);
    --surface:       oklch(100% 0 0);
    --elevated:      oklch(96% 0 0);
    --text-primary:  oklch(20% 0 0);
    --text-secondary:oklch(45% 0 0);
    --text-muted:    oklch(60% 0 0);
    --border:        oklch(90% 0 0);
    --accent:        oklch(55% 0.2 250);
    --accent-text:   oklch(99% 0 0);
    --radius:        0.5rem;
  }
}

/* 2a. Tailwind v4 — expose tokens to utilities */
@theme {
  --color-bg:           var(--bg);
  --color-surface:      var(--surface);
  --color-text-primary: var(--text-primary);
  --color-accent:       var(--accent);
  --radius-md:          var(--radius);
}
```

```js
// 2b. Tailwind v3 alternative — tailwind.config.js
module.exports = {
  theme: { extend: { colors: {
    bg: 'var(--bg)', surface: 'var(--surface)',
    'text-primary': 'var(--text-primary)', accent: 'var(--accent)',
  } } }
}
```

### Surface scale

| Token | Purpose | Value |
|---|---|---|
| `bg` | Page background | `<oklch value>` |
| `surface` | Cards, panels | `<oklch value>` |
| `elevated` | Inputs, dropdowns | `<oklch value>` |
| `overlay` | Modals, popovers | `<oklch value>` |

### Text scale

| Token | Purpose | Value |
|---|---|---|
| `text-primary` | Main readable text | `<oklch value>` |
| `text-secondary` | Supporting text | `<oklch value>` |
| `text-muted` | Metadata, labels | `<oklch value>` |

### Accent / brand — `<tenant-overridable / fixed>`

| Token | Purpose | Value |
|---|---|---|
| `accent` | Primary brand color | `<oklch value>` |
| `accent-hover` | Hover state | `<oklch value>` |
| `accent-text` | Text on accent backgrounds | `<oklch value>` |
| `accent-subtle` | Tinted accent background | `<oklch value>` |

### Status

| Token | Purpose | Value |
|---|---|---|
| `success` | Success state | `<oklch value>` |
| `warning` | Warning state | `<oklch value>` |
| `error` | Error / destructive state | `<oklch value>` |

```erb
<%# ✅ semantic token utility %>
<div class="bg-surface text-text-primary border border-border rounded-md">…</div>

<%# ❌ hardcoded color bypasses theming and per-tenant override %>
<div style="background:#1a1a1a;color:#fff;border-radius:12px">…</div>
```

Per-tenant brand overrides are documented in `theming.md` — the same `:root` variables are re-tinted at render time, so token-based components re-brand for free.

---

## Typography **[core]**

Define a small set of semantic font roles as CSS variables. Collapse roles you don't use.

| Role | Variable | Purpose |
|---|---|---|
| Display | `--font-display` | `<hero headlines, feature titles>` |
| Body | `--font-body` | `<prose, descriptions, long-form>` |
| UI | `--font-ui` | `<nav, buttons, labels, forms>` |
| Mono | `--font-mono` | `<codes, metadata, timestamps>` |

- Always declare **system fallbacks** in the variable default (e.g. `--font-ui: 'Inter', system-ui, sans-serif;`).
- Body: `<leading, min size — e.g., leading-relaxed, text-base minimum>`.
- For external fonts use `dns-prefetch` + `preconnect` + `preload as="style"` before the stylesheet link; provide a `<noscript>` fallback. Avoid render-blocking.

---

## Components **[core]**

### Rails → ViewComponent (reusable UI)

Use **ViewComponent** for any UI element reused across views, or any element with non-trivial logic/variants. ViewComponents are Ruby objects with a paired template — unit-testable in isolation and encapsulated from the surrounding view ([viewcomponent.org](https://viewcomponent.org/), [viewcomponent.org/guide/testing.html](https://viewcomponent.org/guide/testing.html)).

```ruby
# app/components/my_app/button_component.rb
class MyApp::ButtonComponent < ViewComponent::Base
  VARIANTS = { primary: "bg-accent text-accent-text",
               ghost:   "bg-transparent text-text-primary" }.freeze

  def initialize(variant: :primary, type: "button", **attrs)
    @variant = variant
    @type = type
    @attrs = attrs
  end

  private

  def classes = "inline-flex items-center rounded-md px-4 py-2 #{VARIANTS.fetch(@variant)}"
end
```

```erb
<%# app/components/my_app/button_component.html.erb %>
<button type="<%= @type %>" class="<%= classes %>" <%= tag.attributes(@attrs) %>>
  <%= content %>
</button>
```

- Use **partials** for simple, logic-free fragments (`render "shared/badge"`).
- Use a **ViewComponent** when there are variants, slots, conditional classes, or behavior worth a unit test. Every behavior-bearing component gets a `ViewComponent::TestCase` spec — per CLAUDE.md, every addition that adds behavior ships with a test.

### Sinatra → partials + helpers

Sinatra has no ViewComponent. Reusable UI is ERB partials rendered via `erb :partial, layout: false`, with logic extracted into helper methods.

```ruby
# Sinatra 4 modular app — helpers defined on the application class
class MyApp < Sinatra::Base
  helpers do
    def button(label, variant: :primary)
      classes = { primary: "bg-accent text-accent-text", ghost: "bg-transparent" }.fetch(variant)
      %(<button type="button" class="inline-flex rounded-md px-4 py-2 #{classes}">#{ERB::Util.html_escape(label)}</button>)
    end
  end
end
```

Always escape interpolated content (`ERB::Util.html_escape` / `<%= %>`, never `<%== %>` on user data).

---

## Semantic HTML over ARIA **[core]**

Use the right element; let the browser supply roles, focus, and keyboard handling for free.

```erb
<%# ✅ real interactive elements %>
<%= link_to "View order", order_path(@order) %>
<button type="button" data-action="modal#open">Edit</button>
<%= button_to "Delete", order_path(@order), method: :delete %>  <%# Rails: real <form>+<button> %>

<%# ❌ click handler on a non-interactive element — no keyboard, no role %>
<div data-action="click->modal#open">Edit</div>
<span onclick="…">Delete</span>
```

- Never put a click handler on `<div>`/`<span>`. Use `<button>`, `<a>` / `link_to`, or `button_to`.
- Use `<nav>`, `<main>`, `<header>`, `<footer>` for landmarks. Active nav links get `aria-current="page"`.
- See `guides.rubyonrails.org/action_view_helpers.html` for `button_to` vs `link_to` semantics ([guides.rubyonrails.org](https://guides.rubyonrails.org/action_view_helpers.html)).

---

## Animation **[core]**

- **Only animate `transform` and `opacity`.** Never animate layout properties (width, height, margin, padding, top, left) — they trigger reflow.
- Asymmetric timing: enter slightly faster than exit.
- **Respect `prefers-reduced-motion: reduce` — non-negotiable for WCAG 2.1 AA.** Disable transitions/animations globally:

```css
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
    scroll-behavior: auto !important;
  }
}
```

- Loading skeletons use a shimmer keyframe; their outer dimensions must match the loaded element.
- Drive show/hide from Stimulus controllers (Hotwire) or CSS-only `:target`/`details` where possible — keep logic out of templates.

---

## Iconography **[core]**

- **Icon-only controls must have an accessible name** — `aria-label` on the `<button>`/`<a>`. Decorative icons get `aria-hidden="true"`.
- Default size `<e.g., size-5 (20px)>`; compact `<size-4>`; emphasis `<size-6>`.

```erb
<%# ✅ %><button type="button" aria-label="Close" data-action="modal#close"><svg aria-hidden="true">…</svg></button>
<%# ❌ %><button type="button"><svg>…</svg></button>
```

---

## Contrast & Forms **[core]**

- Text ≥ **4.5:1**, large text ≥ 3:1, UI boundaries ≥ 3:1 ([w3.org/WAI/WCAG21/quickref](https://www.w3.org/WAI/WCAG21/quickref/)). Never convey info by color alone.
- Every input has a linked `<label>` (`label_tag`/`form.label` in Rails). Errors via `aria-describedby`. Required fields marked.
- Touch targets ≥ 44×44 CSS px. Flash/loading regions use `aria-live`.

---

## Dark Mode + Theme Switch **[recommended]**

Theme selection is a **`data-theme` attribute on `<html>`** plus CSS-variable blocks — not a hardcoded class toggle. This keeps tokens as the single switch point and composes cleanly with per-tenant brand overrides (see `theming.md`).

```css
@layer base {
  :root,
  [data-theme="light"] { --bg: oklch(98% 0 0); --text-primary: oklch(20% 0 0); }
  [data-theme="dark"]  { --bg: oklch(18% 0 0); --text-primary: oklch(96% 0 0); }
}
/* follow OS preference until the user explicitly chooses */
@media (prefers-color-scheme: dark) {
  :root:not([data-theme]) { --bg: oklch(18% 0 0); --text-primary: oklch(96% 0 0); }
}
```

Persist the choice in `localStorage` with a small Stimulus controller ([stimulus.hotwired.dev/handbook](https://stimulus.hotwired.dev/handbook/introduction)):

```js
// app/javascript/controllers/theme_controller.js
import { Controller } from "@hotwired/stimulus"
export default class extends Controller {
  connect() {
    const saved = localStorage.getItem("theme")
    if (saved) document.documentElement.setAttribute("data-theme", saved)
  }
  toggle() {
    const next = document.documentElement.getAttribute("data-theme") === "dark" ? "light" : "dark"
    document.documentElement.setAttribute("data-theme", next)
    localStorage.setItem("theme", next)
  }
}
```

```erb
<button type="button" data-controller="theme" data-action="theme#toggle" aria-label="Toggle dark mode">…</button>
```

For Sinatra without Hotwire, the same 15-line plain-JS module works — read `localStorage`, set the attribute on `connect`, toggle on click.

---

## Design Tokens & Tone — fill in **[core]**

> Replace this section with your project's concrete decisions.

### Spacing & layout
- Base unit: `<e.g., 4px (Tailwind default)>` · Max content width: `<e.g., 1280px>` · Page padding: `<e.g., px-4 mobile / px-8 desktop>`.

### Components inventory
For each reusable component document: purpose, variants, composition rules, skeleton.
- `<Card — purpose, variants, rules>`
- `<Button — variants: primary/secondary/ghost/destructive; always <button>/link_to; icon-only needs aria-label>`

### Tone of voice
- Principles: `<be direct / be human / be specific in errors>`.
- Error copy: explain what happened + what to do. Avoid "Something went wrong."

| Situation | ❌ Don't | ✅ Do |
|---|---|---|
| `<login failure>` | `<"Authentication failed">` | `<"No account found with that email">` |
| `<form validation>` | `<"Invalid input">` | `<"Email must include an @ symbol">` |

- Empty states: every list surface has one — encouraging, with a CTA.
- Buttons: verbs ("Save changes", not "Submit"); sentence case; no "click here".

---

## Absolute Rules — Never Violate **[core]**

- Never use hardcoded hex/rgb/raw color in templates or components — always semantic tokens.
- Never put click handlers on `<div>`/`<span>` — use `<button>`, `link_to`, or `button_to`.
- Never ship an icon-only control without `aria-label`.
- Never animate layout properties; never skip `prefers-reduced-motion`.
- Never remove focus outlines without a visible replacement.
- Never use placeholder-only labels — always a visible `<label>`.
- Never put business logic (queries, auth checks) in a ViewComponent template or ERB view — pass it in as assigns.
- `<Add project-specific rules here>`.
