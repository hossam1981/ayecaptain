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

## Responsive row/column layout (Flutter)

Applies to any panel laying out rows of mixed text content (hourly/forecast tables, lists with
labels+values) — not just the one that prompted this section.

- Never size a text-bearing cell with a guessed fixed-pixel `SizedBox`/`Container` width. Text
  that's one glyph wider than the guess, or one step up in system text-scale, clips or wraps
  mid-word. This broke `HourlyTable`'s predecessor (`SizedBox` widths of 46/40/70/42px —
  "Rough" clipped to "Roug"/"h", "10 AM" wrapped unevenly, wind direction ran into gust).
- For a set of rows that need **aligned columns**, use `Table` with
  `columnWidths: {n: IntrinsicColumnWidth()}` for every column — it measures each column's
  actual widest cell across all rows, so nothing needs to guess ahead of the content.
  `TableRow` is not a `Widget`, so row-content logic that needs both a `TableRow` (wide) and a
  plain `Widget` (narrow, stacked) form has to live in a small helper class instead of a
  `StatelessWidget`.
- Use `LayoutBuilder` + `constraints.maxWidth` to pick a breakpoint between the wide
  (`Table`) and narrow (stacked `Column`/`Wrap`) layouts — don't assume a fixed screen width.
- In the narrow/stacked form, only bundle the elements onto one `Row` that the spec actually
  requires together (e.g. time + condition label). Anything else — icon+temp, wind, gust —
  belongs in a `Wrap`, not another fixed `Row`: a `Row` with a `Spacer` still overflows if its
  non-flexible children alone exceed the available width (caught at 320lp/200% text scale,
  where `Row(children:[time, condition, Spacer(), iconTemp])` overflowed by up to 29px —
  `Spacer` can't create space that doesn't exist). `Wrap` degrades by moving the overflowing
  item to its own line instead of overflowing.
- Never fix overflow/clipping by shrinking font size, disabling text-scaling, or clipping —
  let the row grow taller instead (`Wrap`'s `runSpacing`, unconstrained `Column` height).

**Widget-testing this**: `flutter-add-widget-test` is adopted — `flutter-web/test/` exists,
`dev_dependencies: flutter_test` is in `pubspec.yaml`. Two non-obvious gotchas hit while
building `test/hourly_table_responsive_test.dart`:
1. This file imports `package:web` (for `beforeinstallprompt`), which only compiles on the
   `chrome` test platform, not the VM default — run
   `flutter test --platform=chrome --dart-define-from-file=.env test/...`
   (needs `CHROME_EXECUTABLE` set to the real Chrome binary; the VM run fails with
   `JSObject`/`.toJS`/`.jsify()` compile errors from `package:web`'s interop internals).
2. A plain `SizedBox(width: N)` inside `pumpWidget` **cannot** simulate a narrower screen —
   the root tree gets a *tight* constraint from the test binding's fixed default surface
   (800×600), and `BoxConstraints.constrain()` clamps a child's requested width back to that
   tight bound regardless of what `SizedBox` asks for. (First pass at this test silently
   passed all 12 width×scale cases because every one of them rendered at 800×600 — confirmed
   via byte-identical golden PNGs.) Actually resize the surface itself:
   `tester.view.physicalSize = Size(width, height); tester.view.devicePixelRatio = 1.0;` +
   `addTearDown(tester.view.reset)`.
3. Capturing real screenshots from a `chrome`-platform test can't use
   `RenderRepaintBoundary.toImage()` + `dart:io` `File.writeAsBytesSync` — the browser sandbox
   has no real filesystem (`UnsupportedError: _Namespace`). Use
   `await expectLater(find.byKey(k), matchesGoldenFile('goldens/name.png'))` with
   `--update-goldens` instead; Flutter's golden-file protocol bridges the write to the host
   process outside the browser sandbox, which works under `--platform=chrome`.
4. Golden-captured text renders as solid placeholder blocks (Flutter's deterministic test
   font), not real glyphs, on any platform — fine for proving layout geometry (no overflow,
   no overlap, correct wrapping), not for eyeballing specific string legibility. For that,
   verify live in the real browser instead.

## Dart/Flutter skills (`.agents/skills/`, from `dart-lang/skills` + `flutter/skills`)

Before starting non-trivial Flutter work, scan this list for a fit — check it every time,
don't rely on memory of what's here:

**Use regularly:**
- `flutter-fix-layout-issues` — RenderFlex overflows, unbounded constraints. Matches the
  recurring class of sizing bug this branch keeps hitting (e.g. the tide-card mess, the
  `HourlyTable` narrow-row overflow — see "Responsive row/column layout" below).
- `flutter-build-responsive-layout` — `LayoutBuilder`/`MediaQuery` patterns; explicitly warns
  against hardcoding a fixed aspect ratio instead of sizing to actual content/available space
  — would have caught the `childAspectRatio` bug directly.
- `flutter-add-widget-test` — adopted (`flutter-web/test/`); catches structural regressions
  without a live browser. See "Responsive row/column layout" below for the platform/surface-
  size/golden-file gotchas specific to this project.
- `dart-run-static-analysis` — run `flutter analyze` locally when the SDK is available in the
  current session (confirmed present and working as of 2026-10-03 — don't assume it's missing
  without checking `which flutter` first); this is exactly what catches the two recurring bugs
  above automatically instead of by manual review.

**Adopt once it applies:**
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
