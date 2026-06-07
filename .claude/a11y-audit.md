---
description: Audit UI changes for WCAG 2.1 AA accessibility compliance and fix all violations.
---

# Accessibility Audit

> **Baseline:** Rails 8 (ERB/ViewComponent, Hotwire) · WCAG 2.1 AA. HTML rules with Rails notes that call out `button_to`/`link_to`, `form.label`, and Turbo Stream `aria-live`.

Every UI addition or modification in `MyApp` MUST fully comply with WCAG 2.1 AA. This is
not optional — accessibility violations are bugs.

Audit all UI changes in the current diff (or the files specified below). For every
violation found, **fix it directly** — do not just report it. Then list a summary of changes.

$ARGUMENTS

This checklist covers ERB / HTML output for Rails 8, with notes that call out Rails helpers
and Hotwire.

Authoritative source: WCAG 2.1 — <https://www.w3.org/WAI/WCAG21/quickref/>.

## What to Audit

Every template, partial, ViewComponent, layout, CSS rule, and Stimulus controller that
touches rendered HTML — files under `app/views/`, `app/components/`,
`app/javascript/controllers/`, and `app/assets/stylesheets/`.

## Requirements

### Semantic HTML

- Interactive elements MUST be `<button>`, `<a>`, `<input>`, `<select>` — never a `<div>`
  or `<span>` with a click handler.
  - **Rails:** use `button_to` (for actions/forms) or `link_to` (for navigation). Never
    attach a Stimulus `data-action="click->..."` to a non-interactive `<div>`/`<span>`;
    put it on a real `<button>`/`<a>`. See
    <https://guides.rubyonrails.org/action_view_helpers.html>.
- Headings (`<h1>`–`<h6>`) MUST follow a logical hierarchy with no skipped levels
  (WCAG 1.3.1, 2.4.6).
- Landmark regions — `<nav>`, `<main>`, `<header>`, `<footer>`, `<aside>`, `<section>` —
  MUST be used correctly. Exactly one `<main>` per page (WCAG 1.3.1).
- Lists MUST use `<ul>`/`<ol>`/`<li>`.
- Data tables MUST use `<th scope="col">` / `<th scope="row">`; provide a `<caption>` where
  the table needs a title (WCAG 1.3.1).

### Keyboard Navigation (WCAG 2.1.1, 2.1.2, 2.4.3, 2.4.7)

- All interactive elements MUST be reachable and operable via Tab.
- Custom widgets (modals, dropdowns, menus, dialogs, tabs) MUST support arrow keys, Escape,
  and Enter/Space as appropriate.
- Focus order MUST match visual order.
- No keyboard traps — Escape MUST close modals/overlays and return focus to the trigger.
- Every focusable element MUST have a **visible focus indicator** — never `outline: none`
  without an equally visible replacement (WCAG 2.4.7).
- Skip links MUST exist for repeated navigation blocks (e.g. a "Skip to content" link that
  targets `#main`) (WCAG 2.4.1).

### ARIA (prefer semantic HTML first)

- Elements without visible text (icon buttons, image links) MUST have `aria-label` or
  `aria-labelledby` (WCAG 4.1.2).
- Disclosure/toggle controls MUST set `aria-expanded`, and where applicable `aria-controls`
  and `aria-haspopup`. Keep `aria-expanded` in sync from the Stimulus controller that
  toggles the widget.
- The active navigation link MUST have `aria-current="page"`.
- Use `role` only when native semantics are insufficient — prefer semantic HTML over ARIA.
- Never add redundant ARIA (e.g. `role="button"` on a `<button>`). See
  <https://www.w3.org/WAI/ARIA/apg/practices/read-me-first/>.

### Dynamic Content (Hotwire / Turbo)

- Content that updates without a full page load MUST be announced. Turbo Stream updates,
  flash messages, and loading states MUST live in or update an `aria-live` region
  (`aria-live="polite"` for status, `assertive`/`role="alert"` for errors) (WCAG 4.1.3).
- Turbo navigations (`turbo-frame`, full Turbo Drive visits) change content without a
  traditional page load — ensure the page `<title>` updates and that an `aria-live` status
  region announces meaningful changes. See <https://turbo.hotwired.dev/handbook/drive>.
- Async loading states MUST expose `aria-busy="true"` or a visible, announced indicator.
- A Turbo Stream that injects content into an `aria-live` region will announce on update —
  verify the target region carries the `aria-live` attribute, not the streamed fragment alone.

### Forms (WCAG 1.3.1, 3.3.1, 3.3.2, 4.1.2)

- Every input MUST have a visible `<label>` linked via `for`/`id` (or a wrapping label).
  - **Rails:** use `form.label :field` paired with `form.text_field :field` (matching ids
    are generated automatically). See
    <https://guides.rubyonrails.org/form_helpers.html>.
- Required fields MUST be indicated both visually and programmatically (`required` or
  `aria-required="true"`).
- Error messages MUST be linked to their input via `aria-describedby`.
- Form-level error summaries MUST use `role="alert"` or `aria-live="assertive"`.
- Placeholder text MUST NOT be the only label.

### Images & Media (WCAG 1.1.1, 1.2.x)

- Every `<img>` MUST have a meaningful `alt` (or `alt=""` if purely decorative).
  - **Rails:** `image_tag "logo.png", alt: "MyApp"` — never omit `alt`.
- Icon-only buttons MUST have `aria-label`.
- Decorative inline SVGs/icons MUST have `aria-hidden="true"` (and the surrounding control
  carries the label).
- Video/audio MUST have captions or a transcript (flag if missing).

### Color & Contrast (WCAG 1.4.1, 1.4.3, 1.4.11)

- Text contrast MUST be >= 4.5:1 for normal text, >= 3:1 for large text (>= 18px, or
  >= 14px bold).
- UI component boundaries (buttons, inputs, focus rings) MUST have >= 3:1 contrast against
  adjacent colors.
- Information MUST NOT be conveyed by color alone — pair with text, icon, or pattern.
- All themes (light, dark, custom) MUST meet contrast requirements.

### Motion & Animation (WCAG 2.2.2, 2.3.1)

- Auto-advancing or animated content MUST respect `prefers-reduced-motion`.
- Auto-playing content MUST have a visible pause/stop control.
- No content may flash more than 3 times per second.

### Touch & Pointer (WCAG 2.5.5)

- Touch targets MUST be at least 44x44 CSS pixels.
- No functionality may require hover-only interaction — tooltips and menus need
  keyboard/focus equivalents.

### Modals & Dialogs

- Modals MUST trap focus while open and return focus to the trigger on close.
- Use `<dialog>` or `role="dialog"` with `aria-modal="true"` and an accessible name via
  `aria-labelledby`.
- Escape MUST close the modal (see Keyboard Navigation).

## Output

For each violation:

1. State the file, line, and element.
2. State the WCAG criterion violated (e.g. "1.4.3 Contrast").
3. Fix it in place.

After all fixes, list a summary of changes.
</content>
