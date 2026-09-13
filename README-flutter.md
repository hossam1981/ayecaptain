# Bayside — Flutter Web branch

This branch (`flutter`) is a **starter, not a rewrite**. It exists to verify the "push branch →
Netlify serves it at a live URL" workflow for Flutter Web, and to give a visual baseline before
deciding whether to invest in feature parity with the PWA on `main`.

The PWA on `main` is unaffected — this branch just adds a `flutter-web/` subfolder and swaps the
root `netlify.toml` to build Flutter Web from that subfolder. Netlify uses whichever `netlify.toml`
is on the branch it's deploying, so the two coexist cleanly.

## To make it show up at a live URL

Netlify has to be told to build this branch. One of these two setups (one-time click, no code):

**Option A — branch deploys on the existing site (simplest, free)**
1. Netlify dashboard → the `frabjous-sprinkles-9eb441` site.
2. Site configuration → Build & deploy → Deploy contexts → **Branch deploys** → "Let me add
   individual branches" → add `flutter`.
3. Save. Next push to `flutter` builds; the preview URL will be
   `flutter--frabjous-sprinkles-9eb441.netlify.app`.

**Option B — a second Netlify site pointing at the same repo but tracking `flutter`**
1. Netlify dashboard → Add new site → Import from Git → pick the same GitHub repo.
2. Set the production branch to `flutter`.
3. Save. Netlify gives it its own randomized subdomain (e.g. `bayside-flutter-abc123.netlify.app`)
   which can be renamed in Site settings → Domain management.

Either works. Option A is faster; Option B gives you a permanent independent URL.

## What's in the skeleton

- `flutter-web/pubspec.yaml` — Flutter package config. `flutter_map` (Leaflet-like) as the map
  engine, `geolocator` for GPS, `http` for weather/tide calls later.
- `flutter-web/lib/main.dart` — a single-file starter: dark theme, Raritan Bay initial center,
  Esri street map tiles (matches the PWA's default), a **"lock on my location"** button that
  requests browser GPS and drops a marker.
- `flutter-web/web/index.html` + `manifest.json` — Flutter Web shell + PWA install manifest.
- `netlify.toml` — build script that installs Flutter into the Netlify build sandbox, runs
  `flutter build web --release`, publishes `flutter-web/build/web`.

First build on Netlify takes ~4-6 min (clones Flutter SDK). Later builds are similar because
Netlify doesn't persist that clone between builds — this is fine for a preview branch.

## What it doesn't have yet

Deliberately minimal, so we can see the pipeline works end-to-end. When ready to invest more,
port over from the PWA in this order:
1. Weather / tide APIs (`http` package + async loading, mirror the PWA's Open-Meteo & NOAA calls).
2. Boat marker with heading + wake spray.
3. Route drawing (`PolylineLayer` in flutter_map).
4. Smart-routes / pre-baked land data (JSON is portable; drop `data/land-njny.json` into
   `flutter-web/web/assets/` and load via `rootBundle.loadString`).
5. If we want the **real** 3D pitch/tilt that Savvy Navvy have, swap `flutter_map` for
   `maplibre_gl` — that requires a Mapbox / MapLibre style URL but is otherwise a drop-in.

See `NOTES-architecture.md` (on `main`) for the broader PWA-vs-Flutter tradeoff writeup.
