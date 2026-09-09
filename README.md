# Bayside

Chart plotter + weather + tides + NWS alerts for Raritan Bay. Pure PWA, no build step, no API keys.

## Put it on your phone (5 minutes)

1. Drag this whole folder onto https://app.netlify.com/drop (free) — or `vercel deploy` from the folder.
2. Open the URL it gives you in Chrome on your Android.
3. Tap the "Add Bayside to home screen" button in the app, or Chrome menu → Add to Home screen.

It must be served over https for GPS and install to work. Opening index.html directly from the file system will not give you GPS.

## Local test on your laptop

    cd bayside && python3 -m http.server 8080

Then open http://localhost:8080 (localhost counts as secure).

## Data sources (all free, no keys)

| What | Source |
|---|---|
| Nautical chart | NOAA Chart Display Service tiles |
| Base maps | CARTO (light/dark), Esri World Imagery |
| Wind, rain, temp, sunset | Open-Meteo forecast API |
| Waves, water temp | Open-Meteo marine API (can be empty inside bays) |
| Tides | NOAA CO-OPS, nearest prediction station |
| Alerts | api.weather.gov active alerts at your position |

## What's in v1

- Boat icon rotates with heading, 10-minute wake trail, speed in knots
- Chart / Satellite / Dark layers
- Wind particles animated from live wind speed and direction; rain, fog, lightning, and a red pulsing border when an NWS alert is active
- Hourly forecast with a Calm / Fair / Rough score per hour, 5 days
- Tide curve with next highs and lows
- Tap-to-plan routes with distance and ETA, GPX export and import
- Offline: app shell and any tiles you've already viewed

## Not in v1 (real work, tell me which first)

- Auto-routing around depth contours
- Tide-adjusted depth numbers on the chart
- Marinas, community spots, friends on map (needs accounts + backend, Supabase)
- Native background GPS (needs Expo / React Native)
