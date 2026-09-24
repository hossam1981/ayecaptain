# Bayside Flutter — remaining work

Tracked on the `flutter` branch. Shipped so far: A.5, B.5, B.6, B.7, Batch C part 1
(sun/moon edge marker, MOB pulse/arrow/smoke/vibrate, wake-lock resume), plus a follow-up
parity-fix batch (smart-routes default, boat Draft field, visible wind/rain FX, moon-marker
shadow), wake spray behind the boat, a panel colour-theme fix (sheet + boat profile modal
were wrongly dark-navy, PWA is light paper/gradient with ink text), and a structural split
of the route-summary pill into its own `_RouteBar` widget (PWA's `#routebar` is a separate
fixed element, not nested inside `#sheet` — index.html:66-74,316-321) — all live at
flutter--frabjous-sprinkles-9eb441.netlify.app.

## Next up

1. **GPX import** — parse `rtept`/`trkpt`/`wpt` from an uploaded `.gpx` file into waypoints
   (`file_picker` package). Currently a placeholder snackbar.
2. **GPX export** — build route XML, trigger a browser download.
3. **PWA install prompt** — capture `beforeinstallprompt`, show "Add Bayside to home screen".
4. **Snow FX** — extend `FxCanvas` to draw snow particles on snow weather codes.
5. **Fog FX** — whitewash overlay on fog weather codes.
6. **Lightning FX** — flash overlay during thunderstorms.
7. ~~**Wake spray**~~ — done (`3d22e8b`). Particle trail astern of the boat, anchored at the
   boat's own LatLng + heading rotation, no camera projection needed.
8. **Distinct boat-3d.png sprite** — blocked on a second source image (current
   `boat.png`/`boat-3d.png` are byte-identical, so the Start-ride crossfade is a no-op).
9. **Real 3D camera (MapLibre GL swap)** — replace `flutter_map` with `maplibre_gl` for true
   pitch/tilt/bearing. Big rewrite, touches every map layer. Do this last, once everything
   else is stable.
10. **Phone spot-check** — GPS-gated behavior (anchor drag alarm, fuel ring circle, live route
    drop) has never been tested with real location; background QA agents can't grant it.
