# AyeCaptain / Bayside

Boat/chart-plotter PWA. Two coexisting builds on separate branches, same Netlify site
(`frabjous-sprinkles-9eb441.netlify.app`):

- **`main`** — the original, shipping PWA (`index.html`, vanilla JS + Leaflet). This is the
  **spec** for everything below. Deploys to the site's production URL.
- **`flutter`** — a from-scratch Flutter Web port living in `flutter-web/`, aiming for full
  parity with the PWA before any Flutter-specific improvements. Deploys to
  `flutter--frabjous-sprinkles-9eb441.netlify.app`. See `README-flutter.md` for the branch
  setup and `TODO.md` for the remaining parity backlog.

## The parity rule (flutter branch)

`index.html` on `main` is not a reference to approximate — it is the exact spec. When porting
a PWA feature to `flutter-web/lib/main.dart`:

- Read the actual CSS rule or JS function in `index.html` first (grep for the selector/function
  name) and copy its real numbers — colors, sizes, z-index, timing, thresholds — not a
  close guess.
- Match **structure**, not just appearance. If the PWA element is a separate, independently
  positioned DOM node (e.g. `#routebar` is `position:fixed`, not nested inside `#sheet`), the
  Flutter port must be a separate widget too — wrapping it inside another widget "because the
  colors match" is not parity, it's an approximation, and will be rejected.
- If a PWA element only shows/hides under certain conditions (e.g. `#routebar` is
  `display:none` until picking or a route exists), replicate the condition, not just the visual
  default state.
- When behavior is genuinely ambiguous or missing from the PWA (e.g. no direct equivalent for a
  CSS `filter: drop-shadow()` shape-following blur), say so and propose the closest Flutter
  technique rather than silently inventing different-looking behavior.

## Two recurring Dart bugs — check for both before every commit

These have broken the build multiple times. A code-review pass must explicitly check for them:

1. **Bare `Path()`** resolves ambiguously — this file imports both `dart:ui` and `latlong2`,
   and `latlong2` also exports a `Path<LatLng>`. Always write `ui.Path()`, never bare `Path()`.
2. **`.clamp(a, b)` returns `num`, not `double`** — even when called on a `double` receiver.
   Any `.clamp(...)` result feeding a strict `double`-typed parameter (`Colors.withOpacity()`,
   `Transform.scale(scale:)`, etc.) needs `.toDouble()` appended, or it won't compile.

## Workflow

- Commit freely. **Always ask before `git push`** — pushing to `main` or `flutter` triggers an
  automatic Netlify deploy on that branch's live URL.
- Run a code-review pass over the diff before every commit/push, specifically checking for the
  two bug classes above plus general correctness.
- After a push, Netlify needs a couple of minutes to build — verify live (browser tools) rather
  than assuming the push alone means it shipped.
- GPS-gated features (anchor drag, live position, fuel-range ring) can't be verified by an
  automated agent — no real location. They stay unverified until manually checked on a phone.
- End responses with a short recap of what changed and what's still open.

## Visual design system

Before building or restyling any HUD badge, warning banner, rail button, or bottom-sheet-style
panel, check `.claude/skills/ayecaptain-glass-design/SKILL.md` — the neon-glow glass recipe
(exact color tokens per severity, the existing `GlassWarningCard` painter pattern to extend
rather than duplicate) and the "one sheet shell, state-driven content, never stacked panels"
architecture rule. Source reference images: `~/Downloads/ayecaptain_flutter/design_references/`.

## Dart/Flutter skills (`.agents/skills/`, from `dart-lang/skills` + `flutter/skills`)

Before starting non-trivial Flutter work, scan this list for a fit — check it every time,
don't rely on memory of what's here:

**Use regularly:**
- `flutter-fix-layout-issues` — RenderFlex overflows, unbounded constraints. Matches the
  recurring class of sizing bug this branch keeps hitting (e.g. the tide-card mess).
- `flutter-build-responsive-layout` — `LayoutBuilder`/`MediaQuery` patterns; explicitly warns
  against hardcoding a fixed aspect ratio instead of sizing to actual content/available space
  — would have caught the `childAspectRatio` bug directly.
- `dart-run-static-analysis` — no local Flutter SDK in most sessions here to run
  `flutter analyze` (see Structure notes below), and this is exactly what would catch the two
  recurring bugs above automatically instead of by manual review.

**Adopt once it applies:**
- `flutter-add-widget-test` — would catch structural regressions (like the tide card) without
  needing a live browser, which is the actual bottleneck this branch keeps hitting.
- `flutter-apply-architecture-best-practices` — relevant once `main.dart`'s planned split
  (see Structure notes) actually happens.
- `dart-resolve-package-conflicts` — relevant now that `package:web` has been added.

**Situational:**
- `flutter-add-widget-preview` — iterating on one isolated widget (`GlassWarningCard`,
  `TidesSheet`) without relaunching the whole app.
- `flutter-implement-json-serialization` — this app hand-parses JSON (`Weather`, `TidePoint`,
  etc.); only worth it if that becomes a real pain point.
- `dart-fix-runtime-errors`, `dart-add-unit-test`, `dart-collect-coverage`,
  `dart-generate-test-mocks` — once real test coverage exists (currently zero).

**Not relevant to this project** — skip without checking: `dart-build-cli-app`,
`dart-setup-ffi-assets`, `dart-use-ffigen` (no CLI/native FFI here), `flutter-setup-declarative-
routing`, `flutter-setup-localization` (single-screen app, no i18n), `dart-migrate-to-checks-
package`, `dart-use-path-package`, `dart-write-documentation`, `dart-use-doc-examples`,
`dart-use-primary-constructors`, `dart-use-pattern-matching` (general style/hygiene, not worth
the overhead on a fast-iterating solo project).

## Structure notes

- `flutter-web/lib/main.dart` is a single file by design so far; `TODO.md` has the planned split
  (`screens/`, `widgets/`, `services/`) for once it's unwieldy — not a prerequisite for other work.
- No local Flutter SDK in most working environments here — compilation is verified via the
  Netlify build log after push, not `flutter analyze` locally, unless a session confirms the SDK
  is actually installed.
