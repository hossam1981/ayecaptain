---
name: ayecaptain-glass-design
description: Apply AyeCaptain/Bayside's neon-glow glass visual language and single-shell state-driven panel architecture when building, restyling, or reviewing any HUD badge, banner, rail button, or bottom-sheet-style panel in flutter-web/lib/main.dart. Use whenever a new overlay/panel/card is being added to the Flutter map screen, or an existing one is being reskinned.
---

# AyeCaptain glass design system

Source of truth for the visual direction: `~/Downloads/ayecaptain_flutter/design_references/`
(8 reference PNGs + a schematic Flutter prototype at `lib/main.dart`, inspected 2026-10-02/03).
That prototype is inspiration only — unverified, no real data, not production code
(see its own README). Treat the PNGs as the visual spec and the real `flutter-web/lib/main.dart`
as the functionality spec, same as the PWA-parity rule in the top-level `CLAUDE.md`.

## 1. The glass recipe

Every HUD badge, warning banner, rail accent, and sheet panel uses the **same layered
recipe**, just retinted per severity. It already exists and ships today as a reusable
`_GlassSurface` widget (composing `_WarningGlassSurface`/`_WarningEdgeGlow`) in
`flutter-web/lib/main.dart` — **use `_GlassSurface(severity:..., borderRadius:... or
circular: true, child:...)` directly, don't hand-nest `CustomPaint`/`ClipRRect or
ClipOval`/`BackdropFilter`/`CustomPaint` again** (that nesting used to be duplicated three
times — `GlassWarningCard`, `_RouteBar`, the rail buttons — before being extracted).
For a circular shape, leave `edgeRadius` unset: `_WarningEdgeGlow` auto-clamps an
oversized radius down to a true half-size circle, so you don't need to know the exact
pixel size of whatever you're wrapping.

Layer order (back to front):
1. **Tinted base fill** — a dark, mostly-opaque color wash (not black) behind a blur.
2. **Vertical tint gradient** — same hue, top brighter than bottom (`.40 → .08 → .03 → .26` opacity stops).
3. **Diagonal white sheen** — a faint light-raking streak across the face (`.16 → .02 → transparent → .10 → transparent`).
4. **Pooled corner reflections** — 4 soft radial "light" blobs at the corners (`_WarningGlassSurface.light()`), not one uniform glow.
5. **Crisp gradient rim** — a ~1-1.2px stroke that goes `core → color → color → core` diagonally, not a flat single-color border.
6. **Outer bloom** — a blurred, low-opacity colored stroke/shadow behind the crisp rim, plus a couple of brighter "hotspot" glints along the rim (`_WarningEdgeGlow.hotspot()`).

### Color tokens by severity

| Severity | Use for | Tint base | Glow/edge | Core (bright highlight) |
|---|---|---|---|---|
| Amber | NWS alerts (`_AlertBanner`) | `#162932` ~43% | `#FFAA24` / `#FFB52E` | `#FFF3B0` / `#FFFFBC` |
| Red (warning) | Boat-conditions warning (`_BoatWarningBanner`, "too rough") | `#30182C` ~43% | `#FF304B` | `#FFEEEE` |
| Blue/cyan (nav) | Top HUD, basemap switcher, route/nav bottom sheet — **not yet ported to `_RouteBar`/`_NavBar`, still flat today** | `#041E32` ~75-80% | `#19C8FF`, subtle glow (thinner/dimmer than the other severities — this one should read as calm, not alarming) | light cyan, e.g. `#D7F3FF` |
| Red (MOB) | MOB sheet state — **deliberately distinct from the warning red above**, darker/more saturated | `#190A15` / `#210B17` | `#FF4055`, tight glow + larger faint bloom | — (less emphasis on a bright core than the warning cards; MOB should feel urgent/dark, not glossy) |

Don't reuse the warning-red tokens for MOB or vice versa — they're intentionally different
reds for different urgency registers (a dismissible alert vs. an active emergency mode).

### HTML/CSS prototyping equivalent

When previewing a glass surface before touching Dart (see workflow below), the layered
recipe above translates to CSS as:

```css
.glass::before{ /* layers 1-4: stacked radial-gradient "light pools" + linear tint + diagonal sheen + blur */
  backdrop-filter: blur(6-9px);
  background:
    radial-gradient(ellipse at corner1, light1, transparent 70%),
    radial-gradient(ellipse at corner2, light2, transparent 70%),
    radial-gradient(ellipse at corner3, light3, transparent 70%),
    radial-gradient(ellipse at corner4, light4, transparent 70%),
    linear-gradient(135deg, sheen-stops...),
    linear-gradient(180deg, tint-top, tint-mid, tint-bot),
    base-tint-color;
}
.glass::after{ /* layers 5-6: gradient-mask border trick + outer bloom */
  border: 1-1.2px solid transparent;
  background: linear-gradient(135deg, core, glow, glow, core) border-box;
  -webkit-mask: linear-gradient(#fff 0 0) padding-box, linear-gradient(#fff 0 0);
  -webkit-mask-composite: xor; mask-composite: exclude;
  box-shadow: 0 0 Npx glow-color; /* outer bloom */
}
```

Working examples of this exact pattern: artifacts `55091e25-4b6b-43ca-88f4-683b3160354b`
(neon glass, blue+red variants) and `b83ec157-7818-44a0-bafa-737d617cbdd9` (corrected sheet
architecture, exact nav/MOB hex values) published earlier this session.

## 2. Panel architecture: one shell, swapped content — never stacked

**Implemented** as `_NavShell` (route planning / waypoint navigation / MOB — see the gap
list below). The map screen must never show two permanent panels doing the same job (e.g.
a route bar *and* a separate MOB panel both visible at once). Instead:

- There is **one bottom-sheet region** whose content is driven by app state, not multiple
  independent widgets stacked vertically. Model it as an enum-like set of states
  (route planning / waypoint navigation / MOB / weather) — reuse whatever state the app
  already tracks (`_navigating`, `_picking`, `_mobPoint`, `_waypoints`) rather than inventing
  a parallel enum if the equivalent booleans already exist.
- Switching state **replaces** the sheet's content; it does not add a second card below or
  above it.
- The floating right-rail (Follow / Go-to / Locate / More / **MOB**) is separate from the
  sheet and stays on screen regardless of sheet state — the MOB button lives there
  (`_RightRail._mobButton()`), not inside the sheet itself. Tapping it switches the
  *existing* sheet into MOB state; it doesn't spawn a new widget.
- Mode entry must never be gated on `_me != null` (GPS) — actions like Start/MOB take
  effect without GPS, so the mode switch must too. Pass `_me ?? _homeCenter` as the
  position and let content gracefully show `—` for anything that genuinely can't be
  computed (e.g. ETA at 0 speed), rather than hiding the whole mode change.
- Sheet height is **content-driven** (wrap its content, cap with a max-height only for
  genuinely long scrollable content like the weather/hourly panel) — never a fixed tall box
  with empty space to "make room" for buttons that could just sit in their own row.
- The **weather/boat-profile sheet stays light** (PWA-exact, `main.dart:3504-3509` /
  `index.html:79`) — the dark glass treatment is for the nav/route/MOB region only, not the
  weather content. Confirmed from the reference set's own 3rd panel (`Marine Navigation App
  UI Comparison.png`), which shows the weather/conditions panel as white, separate from the
  dark nav bar.

## 3. Workflow when applying this elsewhere

Same pattern already established this session — don't skip steps:

1. **Inspect the real code first.** Find the actual widget(s) involved and their real state
   fields/callbacks before designing anything. Don't guess field names or invent data a
   widget doesn't already compute. If a design calls for a value with no backing state
   (e.g. fuel-remaining-%, route-progress fraction), say so explicitly rather than faking it.
2. **Build an HTML/CSS preview first** (publish as an Artifact) using the recipe above,
   grounded in the real field names/values from step 1. Get it approved.
3. **Ask before touching `main.dart`.** Porting a preview into real Dart is still a code
   change — confirm first, same as the standing "ask before push" rule.
4. Port using the existing `_GlassSurface` widget (new severity tokens go in
   `_WarningGlassSurface`/`_WarningEdgeGlow`'s switch expressions, not a parallel
   implementation).

## Known gaps as of 2026-10-03 (update this list as they're closed)

- ~~`_RouteBar` is still flat solid navy~~ — **done.** `_RouteBar` (`main.dart:3329`) now uses
  `GlassSeverity.nav` via the shared `_WarningGlassSurface`/`_WarningEdgeGlow` painters
  (generalized from a `bool isAmber` to a `GlassSeverity severity` param + a `radius` param on
  `_WarningEdgeGlow` so callers with a different corner radius than the warning cards' 18 can
  pass their own). Amber/red output is pixel-identical to before — the new `nav` branch is
  additive, not a rewrite of the existing severities.
- ~~`_NavBar`/`_MobHud` live in the top HUD, not merged into one state-driven bottom
  shell~~ — **done.** `_RouteBar`/`_NavBar`/`_MobHud` are gone; replaced by `_NavShell`
  (`main.dart`, search `class _NavShell`), a single `_GlassSurface`-wrapped widget with 3
  mutually-exclusive modes (`_NavMode.planning/navigating/mob`) computed once from existing
  state (`_mobPoint`/`_navigating`/`_waypoints`) — no new state model introduced. MOB takes
  priority over navigating, which takes priority over planning. Mode entry is deliberately
  NOT gated on `_me != null` (an earlier draft was, and silently fell back to showing
  Planning again when Start/MOB was tapped without GPS — caught via live testing, fixed by
  passing `me: _me ?? _homeCenter`, the same fallback `_toggleMob` already used). Added a
  4th `GlassSeverity.mob` (distinct dark/saturated red, `#190A15`/`#FF4055`) since MOB is a
  different urgency register than the warning-red severity. ETA-to-MOB and live SOG (the
  previously-flagged `_MobHud` gap) are now both surfaced — both were already fully
  computable from existing real data (distance + live speed), just not previously exposed;
  ETA shows `—` rather than a fabricated number when speed is 0.
- Fuel burn-rate (GPH) and tank-remaining-% have no backing state anywhere yet — the
  Waypoint Navigation and MOB content intentionally omit the demo's fuel-burn-rate/%-
  remaining and route-progress-bar elements for this reason (still true, not newly closed).
- ~~`_RightRail` buttons are flat Material circles, no glass~~ — **done.** The 4 regular
  buttons (`_btn`, `main.dart:3069`) now use `GlassSeverity.nav` glass (circular, via
  `ClipOval` + the shared painters at `radius: 23`); active state is a filled accent disc
  behind the icon rather than swapping the whole button solid, since the glass ring alone
  reads too subtly as "on" at 46px. This is a deliberate PWA-parity departure (the old
  comment called the white-circle look out as PWA-exact) — flagged, not silent. `_mobButton`
  stays solid-fill (urgency, not translucency) but gained the spec'd subtle red `BoxShadow`
  bloom.
