# Bayside architecture — PWA vs native (Flutter), what we can and can't do

Written after checking Savvy Navvy's public GitHub org for reference (github.com/savvy-navvy:
14 repos, all forks — the useful signal is *what they depend on*, not their app source).

## The stack we picked, on purpose

Bayside is a **Progressive Web App (PWA)** — a single-page website (HTML + Leaflet + inline JS)
served as static files off Netlify, installable to a phone's home screen. No app store, no
native compile, no backend. The deploy path is "push to `main`, Netlify serves it 60 s later."

The trade-off with a fully native app (Savvy Navvy is **Flutter** — one Dart codebase compiling
to Android and iOS binaries distributed through the app stores) is real. Some features are
cheap in native and either impossible or a heavy lift in a PWA.

## What we CAN do in the PWA

- Real-time GPS via `navigator.geolocation.watchPosition` — works well when the screen is on.
- **Screen Wake Lock** to keep the screen (and therefore GPS updates) alive during active nav —
  now shipped as the "Start ride" flow.
- Full offline once installed (service worker precache): app shell, chart-tiles-you've-viewed,
  pre-baked land data (`data/land-njny.json`).
- Live weather / tides / NWS alerts via free public APIs (Open-Meteo, NOAA CO-OPS, weather.gov).
- Water-grid land-avoidance routing on pre-baked NOAA ENC polygons (the smart-routes toggle).
- Route drawing, weather-graded route colouring, boat marker with heading, animated wake spray,
  MOB, anchor watch, fuel range ring, etc. — all pure JS/Canvas.
- **A CSS-perspective "3D-lean" view** during active nav (~45° rotateX tilt on the map + fx
  canvas). Reads as a driving-nav view; not a real 3D camera.

## What we CANNOT easily do in the PWA (and how Savvy Navvy do it)

| Capability | Savvy Navvy (Flutter) | Us (PWA) | To match, we'd need to |
|---|---|---|---|
| **True 3D map tilt / pitch / bearing** | Mapbox Vector Tiles + Mapbox GL native — real camera pitch, extruded polygons, DEM terrain, hillshade | Leaflet is 2D-only — can't tilt the camera. Our 45° "3D-lean" is a CSS transform trick | Swap **Leaflet → MapLibre GL** (full rewrite of every marker/layer/popup). |
| **Background GPS** (locks after screen is off; keeps ticking with app in background) | Native foreground location service; unrestricted by OS | Wake Lock keeps the screen on and GPS alive, but the moment the tab hides, the OS suspends geolocation | Native app (Flutter or React Native) with a foreground service. No web workaround exists. |
| **Native notifications** (route alerts, weather push while app closed) | Firebase push, native OS notifications | Web push works but requires HTTPS + user opt-in; noticeably less reliable than native | Add Web Push infra + a push service (small); or go native. |
| **Unlimited offline storage** (chart tiles for whole coasts) | Files on disk, gigabytes fine | Service Worker Cache ~50 MB soft-limit on iOS Safari; Android allows more but user can wipe | Native app, or an IndexedDB tile cache with user-managed quota. |
| **App store presence** (discovery, ratings, one-tap install) | Play Store + App Store | "Add to home screen" flow, no discovery | Publish native builds — Apple $99/yr + review cycles, Google $25 one-time. |
| **Full-fidelity BLE** (rangefinder / instrument integration) | Native BLE, unrestricted | Web Bluetooth exists on Chrome Android; iOS Safari no support | iOS requires native. |
| **Continuous heading from device compass, tuned** | Native `CoreMotion` / Android sensors, low-level access | Web `DeviceOrientation` API works, but permission model on iOS is fiddly | Keep using the web API; native gets a small quality win. |

Nothing else is really out of reach on the web. Charts, weather, tides, routing, navigation —
all doable, and doable well.

## Why we deliberately picked the PWA path

- Zero distribution overhead: Netlify serves static files, deploys in a minute.
- Zero app-store friction: no reviews, no yearly fees, no signing certificates, no sign-in.
- Everyone on iPhone and Android can open a URL. No install unless they want the home-screen
  icon.
- Iteration speed: any commit is live in a minute, easy for a personal / small-user project.
- One codebase, no cross-platform matrix. Native Flutter is close (single codebase → both
  platforms) but still needs the app-store dance.
- The list above shows the tradeoffs — for a personal chart plotter used by the author on
  their own boat, all of them are acceptable.

## When it becomes worth going Flutter

If any of these ever becomes a hard requirement, that's the signal to consider the native
rewrite:

1. **True 3D pitch/tilt view of the chart** (real Mapbox-style camera, not the CSS trick) —
   this is where Savvy Navvy visually beat any web app. If matching that becomes a must-have,
   swap Leaflet → MapLibre GL (still web, keeps the PWA), OR go Flutter (unlocks even more).
2. **Continuous background GPS tracking** — logging a trip while the phone is locked in a
   pocket. Wake Lock keeps the screen on but eats battery; native background location is more
   power-efficient and doesn't need the screen at all.
3. **A real user base with real churn** where being on the app store matters more than being
   at a URL. For a personal app that's never going to be true; for a product it eventually is.

Rough estimate for a full Flutter rewrite of the current feature set: 2–3 months solo if you
already know Flutter, longer if not. Plus app-store review cycles for every meaningful update.

## Where we stand now

Pretty deliberately at the sweet spot: everything achievable in a PWA is here or planned; the
things that aren't achievable in a PWA are the things listed above. Nothing surprising, nothing
lost by mistake — we know exactly what we gave up by picking the web platform, and it's a
reasonable trade for a project scoped to one user (the author) on their own boat.
