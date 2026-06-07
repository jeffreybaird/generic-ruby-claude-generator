# Stimulus Controllers

Load this file when working on Stimulus controllers, Turbo Frames/Streams, third-party JS
widget integration, or any client-side JavaScript in a Hotwire app.

> **Baseline:** Hotwire (Turbo + Stimulus) on Rails 8 via importmap (default) or jsbundling; Stimulus standalone on Sinatra. Turbo first; Stimulus for client behavior; no business logic in controllers.

This is the Ruby/Hotwire analog of the Elixir template's LiveView JS hooks doc. The
principle is identical: **client-side code is a thin DOM/JS bridge — never a place for
business logic.** Decisions, data shaping, and authorization live on the server.

### Maturity tags

Each feature/section is tagged so you know how safe it is to lean on:

| Tag             | Meaning                                                                 |
|-----------------|-------------------------------------------------------------------------|
| `[stable]`      | Core Hotwire/Stimulus API, framework-agnostic, unlikely to change       |
| `[rails-default]` | Ships out of the box in a new Rails 8 app (importmap + Hotwire)       |
| `[rails-alt]`   | Supported Rails path, but not the default (jsbundling/esbuild, TS)      |
| `[sinatra]`     | Requires manual wiring — Sinatra has no first-party Hotwire integration |

---

## 1. Turbo-first principle `[stable]`

Reach for the server before you reach for JavaScript. Most "interactive" UI on Hotwire is
server-driven HTML over the wire, not client state.

- **Turbo Drive** turns links/forms into background requests that swap `<body>` — no JS.
  ([Turbo](https://turbo.hotwired.dev/))
- **Turbo Frames** scope navigation/replacement to a region of the page — no JS.
  ([Turbo Frames](https://turbo.hotwired.dev/handbook/frames))
- **Turbo Streams** push fragment updates (append/prepend/replace/remove) from a form
  response or over a WebSocket/SSE — no JS.
  ([Turbo Streams](https://turbo.hotwired.dev/handbook/streams))
- **Stimulus** is for behavior that is *genuinely client-side* and has no server round-trip:
  toggles, menus, autocomplete UX, copy-to-clipboard, keyboard shortcuts, initializing a
  third-party widget, reading `prefers-reduced-motion`.
  ([Stimulus](https://stimulus.hotwired.dev/))

```
Does it need fresh data or a server decision?
├─ yes → Turbo Frame / Turbo Stream (server renders HTML)
└─ no  → Is it pure DOM/JS behavior (toggle, widget, keyboard)?
         ├─ yes → Stimulus controller
         └─ no  → you probably still want Turbo
```

✅ A "Load more" button that fetches the next page → Turbo Frame with `loading="lazy"` or a
`turbo_stream` append.
❌ A Stimulus controller that `fetch`es `/api/posts?page=2`, parses JSON, and builds DOM
nodes by hand.

---

## 2. Stimulus controller anatomy `[stable]`

A controller is a JS class connected to DOM via `data-controller`. Stimulus instantiates it
when a matching element enters the DOM and tears it down when it leaves — including across
Turbo navigations. ([Handbook: Introduction](https://stimulus.hotwired.dev/handbook/introduction),
[Reference: Controllers](https://stimulus.hotwired.dev/reference/controllers))

```javascript
// app/javascript/controllers/clipboard_controller.js
import { Controller } from "@hotwired/stimulus"

// data-controller="clipboard" connects this class to the element.
export default class extends Controller {
  static targets = ["source", "button"]      // this.sourceTarget, this.buttonTargets, this.hasSourceTarget
  static values  = { successText: String }    // this.successTextValue, typed + reactive
  static classes = ["copied"]                 // this.copiedClass <- data-clipboard-copied-class

  connect() {
    // element entered the DOM — set up state, listeners, widgets
  }

  disconnect() {
    // element left the DOM — tear down (see §4)
  }

  copy() {
    // an action method, wired via data-action (below)
    navigator.clipboard.writeText(this.sourceTarget.value)
    this.buttonTarget.classList.add(this.copiedClass)
  }
}
```

```erb
<%# app/views/posts/show.html.erb (Rails) — markup wires everything declaratively %>
<div data-controller="clipboard"
     data-clipboard-success-text-value="Copied!"
     data-clipboard-copied-class="is-copied">
  <input type="text" value="<%= @post.share_url %>"
         data-clipboard-target="source" readonly aria-label="Share URL">
  <%# data-action = "event->controller#method" %>
  <button type="button"
          data-clipboard-target="button"
          data-action="click->clipboard#copy">Copy</button>
</div>
```

| Convention            | Rule                                                                          |
|-----------------------|-------------------------------------------------------------------------------|
| File path             | `app/javascript/controllers/<name>_controller.js`                             |
| Identifier            | filename `foo_bar_controller.js` → `data-controller="foo-bar"`                 |
| Targets               | `static targets = ["x"]` → `data-<id>-target="x"`, read via `this.xTarget`     |
| Values                | `static values = { y: Number }` → `data-<id>-y-value="3"`, read `this.yValue`  |
| Classes               | `static classes = ["z"]` → `data-<id>-z-class="..."`, read `this.zClass`       |
| Actions               | `data-action="event->id#method"` (default event inferred for buttons/inputs)   |
| Lifecycle             | `connect()` / `disconnect()`; also `initialize()`, `xTargetConnected()`        |

References: [Targets](https://stimulus.hotwired.dev/reference/targets),
[Values](https://stimulus.hotwired.dev/reference/values),
[CSS Classes](https://stimulus.hotwired.dev/reference/css-classes),
[Actions](https://stimulus.hotwired.dev/reference/actions),
[Lifecycle](https://stimulus.hotwired.dev/reference/lifecycle-callbacks).

---

## 3. No business logic — controllers are thin bridges `[stable]`

A Stimulus controller manages DOM and JS-library bindings. It does **not** decide what a
user may see, filter or transform domain data, or own a copy of server state. Those
decisions belong to the server (`MyApp` controllers/services), surfaced as rendered HTML or
as `data-*`/`values`. (Replace the `MyApp` / `my_app` placeholders with your real
application module and snake_case app name throughout.)

```javascript
// ✅ CORRECT — report intent; let the server decide and re-render
export default class extends Controller {
  static values = { url: String }
  archive() {
    // POST a Turbo-aware form; server authorizes + responds with turbo_stream
    this.element.requestSubmit()
  }
}
```

```javascript
// ❌ WRONG — client makes an authorization/data decision
export default class extends Controller {
  toggle() {
    if (this.userRole === "admin") {      // ❌ auth belongs on the server
      this.rows = this.rows.filter(r => r.active)   // ❌ filtering belongs on the server
      this.render(this.rows)                        // ❌ rebuilding DOM by hand
    }
  }
}
```

Rule of thumb: if removing the JavaScript would let someone bypass a check or see data they
shouldn't, that check was in the wrong place. The server is the source of truth.
([Rails security guide](https://guides.rubyonrails.org/security.html))

---

## 4. Clean up in `disconnect()` `[stable]`

Turbo navigations swap DOM without a full page reload, so a controller's element can be
removed and a new one connected many times in one "page" lifetime. Anything you set up in
`connect()` (or `initialize()`) that outlives the element must be torn down in
`disconnect()`, or it leaks. ([Lifecycle callbacks](https://stimulus.hotwired.dev/reference/lifecycle-callbacks))

```javascript
export default class extends Controller {
  connect() {
    this.onKeydown = this.onKeydown.bind(this)
    document.addEventListener("keydown", this.onKeydown)        // listener on document
    this.timer = setInterval(() => this.tick(), 30000)          // timer
    this.picker = new ThirdPartyDatePicker(this.element)        // 3rd-party instance
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)     // ✅ remove
    clearInterval(this.timer)                                   // ✅ clear
    this.picker.destroy()                                       // ✅ destroy
  }

  onKeydown(e) { if (e.key === "Escape") this.close() }
  tick() { /* ... */ }
}
```

✅ Listeners added to `window`/`document`, intervals/timeouts, `IntersectionObserver`,
`MutationObserver`, third-party widget instances → all torn down in `disconnect()`.
❌ Listeners added directly to `this.element` or its children are removed automatically when
the element is GC'd, but tearing them down explicitly is still safe and clearer.

---

## 5. No global / module state `[stable]`

State lives on the controller instance (`this`) or in `values`, scoped to the element
lifecycle. Never store state in module-level variables, on `window`, or in a singleton — two
instances of the same controller would clobber each other, and state would survive a Turbo
navigation it shouldn't.

```javascript
// ✅ CORRECT — per-instance state
export default class extends Controller {
  static values = { open: Boolean }   // reactive, reflected to the DOM, survives only with the element
  connect() { this.observer = new IntersectionObserver(this.onSee.bind(this)) }
}
```

```javascript
// ❌ WRONG — module-level state shared across every instance + leaks across navigations
let isOpen = false
let observer
export default class extends Controller {
  toggle() { isOpen = !isOpen }
}
```

Prefer **`values`** over ad-hoc instance fields when the state should be readable from
markup, reactive (`<name>ValueChanged`), or reflected back to the DOM.
([Values](https://stimulus.hotwired.dev/reference/values))

---

## 6. Server communication — Turbo and `values`, not hand-rolled `fetch` `[stable]`

Controllers talk to the server the Hotwire way:

- **Submit forms** (`this.element.requestSubmit()` / `<form data-turbo="true">`) and let the
  server respond with a `turbo_stream` or a redirect. Turbo applies it.
  ([Turbo Streams](https://turbo.hotwired.dev/handbook/streams))
- **Navigate** with `Turbo.visit(url)` when you need a programmatic visit.
  ([Turbo Drive](https://turbo.hotwired.dev/handbook/drive))
- **Read configuration** the server rendered, via `values` / `data-*` — not by fetching it.

```erb
<%# Server hands the controller its config; no client fetch needed %>
<div data-controller="poller"
     data-poller-interval-value="15000"
     data-poller-url-value="<%= dashboard_metrics_path %>"></div>
```

```javascript
export default class extends Controller {
  static values = { interval: Number, url: String }
  connect() { this.timer = setInterval(() => Turbo.visit(this.urlValue, { frame: "metrics" }), this.intervalValue) }
  disconnect() { clearInterval(this.timer) }
}
```

**Only** reach for raw `fetch`/`XMLHttpRequest` for **direct-to-third-party** calls that must
not pass through `MyApp` — e.g. a presigned **direct upload to S3** or to a media provider's
ingest endpoint. Never hand-roll `fetch` to your own backend to dodge Turbo; that re-creates
the business-logic-in-the-client antipattern from §3.

```javascript
// ✅ acceptable exception — presigned upload straight to the storage vendor
async upload(file, signedUrl) {
  await fetch(signedUrl, { method: "PUT", body: file })   // bypasses MyApp by design
}
```

(Rails' own `@rails/request.js` / `FetchRequest` is a fine wrapper if you must request your
own server directly, but prefer Turbo-driven forms.)

---

## 7. Registration `[rails-default]` / `[rails-alt]` / `[sinatra]`

### Rails 8 — importmap (default) `[rails-default]`

`bin/rails stimulus:install` wires Hotwire's Stimulus into a new app. It pins the packages
and sets up eager loading. ([stimulus-rails](https://github.com/hotwired/stimulus-rails),
[importmap-rails](https://github.com/rails/importmap-rails))

```ruby
# config/importmap.rb
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
```

```javascript
// app/javascript/controllers/index.js
import { application } from "controllers/application"
import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"
eagerLoadControllersFrom("controllers", application)
// or: lazyLoadControllersFrom("controllers", application) to load on first DOM appearance
```

`pin_all_from` auto-pins every controller file, and `eagerLoadControllersFrom` discovers and
registers them — you **do not** hand-write a `register(...)` per controller. Generate new
ones with `bin/rails generate stimulus <name>`. Manage third-party JS pins with
`bin/importmap pin <pkg>` / `bin/importmap unpin <pkg>` (edits `config/importmap.rb`).
([importmap-rails](https://github.com/rails/importmap-rails))

### Rails 8 — jsbundling / esbuild `[rails-alt]`

With `jsbundling-rails` (esbuild/rollup/webpack), there is no importmap; controllers are
imported in an index file. The Stimulus generator (or `bin/rails stimulus:manifest:update`)
rewrites `app/javascript/controllers/index.js` with the current imports. esbuild bundles it.
([jsbundling-rails](https://github.com/rails/jsbundling-rails))

```javascript
// app/javascript/controllers/index.js (bundled build — generator keeps this in sync)
import { application } from "./application"
import ClipboardController from "./clipboard_controller"
application.register("clipboard", ClipboardController)
```

### Sinatra 4 — Stimulus standalone `[sinatra]`

Sinatra has **no first-party Hotwire integration** — there is no `stimulus:install`, no
`importmap.rb`. Wire it manually one of two ways
([Stimulus: Installing](https://stimulus.hotwired.dev/handbook/installing)):

**A. Small bundle (esbuild) — recommended for real apps.** Add `@hotwired/stimulus` (and
optionally `@hotwired/turbo`) to `package.json`, register controllers explicitly, and serve
the bundle from `public/`:

```javascript
// frontend/application.js  → esbuild → public/assets/application.js
import { Application } from "@hotwired/stimulus"
import ClipboardController from "./controllers/clipboard_controller"

window.Stimulus = Application.start()
Stimulus.register("clipboard", ClipboardController)
```

**B. No build step — ESM via CDN/importmap-in-HTML.** Fine for prototypes; you still
`register()` each controller manually:

```html
<%# Sinatra view (ERB/Haml) — no Node toolchain %>
<script type="module">
  import { Application, Controller } from "https://unpkg.com/@hotwired/stimulus/dist/stimulus.js"
  window.Stimulus = Application.start()
  Stimulus.register("hello", class extends Controller {
    static targets = ["name"]
    connect() {}
  })
</script>
```

"importmap without the Rails gem" means a native `<script type="importmap">` in your layout
pointing at the Stimulus ESM build, plus the `Application.start()` / `register(...)` calls
above — you own the registration that `stimulus-loading` would otherwise automate on Rails.

| Setup                          | Discovery / registration                                   | Tag              |
|--------------------------------|------------------------------------------------------------|------------------|
| Rails importmap (default)      | `pin_all_from` + `eagerLoadControllersFrom` (auto)         | `[rails-default]`|
| Rails jsbundling/esbuild       | generated `index.js` with `application.register(...)`      | `[rails-alt]`    |
| Sinatra esbuild bundle         | manual `Application.start()` + `register(...)`             | `[sinatra]`      |
| Sinatra CDN/ESM, no build      | inline `<script type="module">` + manual `register(...)`   | `[sinatra]`      |

---

## 8. TypeScript (optional) `[rails-alt]` / `[sinatra]`

TypeScript controllers require a bundler — they are **not** available on the importmap
default (importmap serves JS as-is, no transpile). Use them only with jsbundling/esbuild on
Rails, or with the esbuild Sinatra setup.

- Author controllers as `*_controller.ts`; esbuild strips types and bundles.
- esbuild does **not** type-check — run `tsc --noEmit` as a **separate CI step**.
- Stimulus ships type definitions; extend `Controller` and type your targets/values.

```typescript
// app/javascript/controllers/clipboard_controller.ts
import { Controller } from "@hotwired/stimulus"

export default class extends Controller<HTMLElement> {
  static targets = ["source"]
  static values  = { successText: String }

  declare readonly sourceTarget: HTMLInputElement
  declare readonly successTextValue: string

  copy(): void {
    navigator.clipboard.writeText(this.sourceTarget.value)
  }
}
```

```jsonc
// tsconfig.json — drives the editor + the `tsc --noEmit` CI step (esbuild ignores it when bundling)
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "noEmit": true,
    "esModuleInterop": true,
    "skipLibCheck": true
  },
  "include": ["app/javascript/**/*.ts"]
}
```

Declare target/value accessors with `declare readonly` (as above) so TS knows about the
properties Stimulus generates at runtime without emitting initializers that would shadow
them. ([Values](https://stimulus.hotwired.dev/reference/values))

---

## 9. Decision table — Turbo Frame vs Turbo Stream vs Stimulus vs custom JS `[stable]`

Pick the **least powerful** tool that does the job. Power increases left→right; so does cost.

| Need                                                                 | Use                  | Why / why not the others                                                                 |
|----------------------------------------------------------------------|----------------------|------------------------------------------------------------------------------------------|
| Replace **one region** on navigation/submit; one target at a time     | **Turbo Frame**      | Self-contained, lazy-loadable, zero JS. Can't touch multiple disjoint regions.           |
| Update **several disjoint regions** from one response, or **push** updates (created/destroyed rows, broadcasts) | **Turbo Stream**     | Append/prepend/replace/remove across the page; works over WS/SSE. Server renders the HTML. |
| **Client-only** behavior, no server data (toggle, menu, autocomplete UX, copy, keyboard, init a widget) | **Stimulus controller** | Lives with the markup, lifecycle-managed, testable. Overkill if Turbo already does it.   |
| Logic that **doesn't fit** Stimulus conventions: a reusable lib, complex canvas/WebGL, a big 3rd-party SDK | **Custom JS module** imported **into** a Stimulus controller | Keep the DOM bridge in Stimulus (`connect`/`disconnect`); put algorithmic code in a plain module. Never bypass Stimulus' lifecycle. |

Tie-breakers:
- Needs fresh data or an auth decision → **server** (Frame/Stream), never Stimulus (§3).
- Needs the same fragment in many places or pushed in real time → **Stream**.
- Pure presentation interaction → **Stimulus**.
- If you're writing `document.createElement` / templating HTML in JS → stop; render it
  server-side and Turbo-stream it instead.

---

## Companion docs (planned)

This template's `.claude/` set is being built out. When present, these are the natural
cross-references for client-side work:

- `separation-of-concerns.md` — where controller logic ends and server logic begins
- `external-service-integration.md` — third-party API/SDK and direct-upload patterns
- `theming.md` — passing theme tokens from server to controller via `data-*` / `values`
- `testing.md` — `data-test` selectors, system/E2E tests for Stimulus behavior
