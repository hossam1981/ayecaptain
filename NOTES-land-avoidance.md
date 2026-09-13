# Land-avoidance routing — what was tried, and why it's reverted for now

The route line is back to plain straight lines between manually-placed waypoints, colored
green/amber/red by conditions — exactly how it worked before any of this. This file is the
record of what was attempted, so a future try doesn't repeat the same dead ends. All the code
described below is fully intact in git history (see commit range at the bottom) — nothing was
lost, it was just removed from the live file.

## Why this started

A screenshot showed a route line cutting straight across Point Comfort (a real peninsula near
Keansburg, NJ) — impossible for an actual boat, and it made the distance/time/fuel estimates
wrong. The ask: bend routes around land so those numbers are realistic.

## Attempt 1 — recursive nudge-off-nearest-vertex heuristic

On a straight-line crossing, nudge a point off the nearest coastline vertex by a buffer distance
and recurse on the two new sub-legs. Simple to reason about, but didn't converge reliably near a
concave coastline/inlet — it kept re-hitting the same crossing no matter how the buffer size or
recursion depth were tuned. Replaced by explicit request to "invest in real pathfinding" instead
of continuing to patch a heuristic that didn't converge.

## Attempt 2 — OSM visibility-graph + Dijkstra

The standard algorithm for routing around polygon obstacles: candidate waypoints are the actual
coastline vertices near a crossing (from OpenStreetMap's `natural=coastline`, via the free
Overpass API), edges connect any two mutually-visible nodes, Dijkstra finds the shortest path
through the graph. Worked well for simple point/peninsula cases like the original Point Comfort
screenshot.

Two real bugs found and fixed along the way:
- Every candidate node **is** a coastline vertex, so a naive line-intersection test misread a
  line ending exactly at a vertex as "crossing" that vertex's own neighboring segments — fixed
  with an epsilon that excludes touches exactly at either segment's endpoint.
- A transient Overpass fetch failure was getting **permanently cached as a confirmed clear
  route** (the fallback-on-error path returned the same shape as a real "checked, clear" result,
  and whichever landed first got cached with no retry). Fixed by making the fetch throw on
  failure instead of returning an empty result, so the cache is never written on a failure and
  the next redraw retries for real.

## The fatal gap in attempt 2

OSM's `natural=coastline` tag only marks the ocean-facing edge of the mainland — it never covers
tidal river or inlet banks. A route to Red Bank, NJ (up the Navesink River) got a confident
straight line drawn across several miles of township streets, because the router had zero
awareness that any land existed between the bay and the river. Confirmed directly: no usable
OSM water-polygon data exists for that river either.

## Attempt 3 — channel-snapping on OSM buoy/beacon data

Layered on top of attempt 2: fetch OSM's lateral buoy/beacon marks (the red/green channel
markers boaters actually steer by) plus any official `recommended_track`/`navigation_line`,
auto-pair nearby port/starboard marks into "gates", and thread the route through them instead of
just avoiding the coastline. Worked well near Sandy Hook — but it was still built on the same
OSM coastline data underneath, so it didn't fix the river gap.

## Attempt 4 — NOAA ENC nautical chart data

Switched the whole data source to NOAA's own chart vector service
(`gis.charttools.noaa.gov/arcgis/rest/services/encdirect/`, free, no key, CORS-open — the same
host already used for this app's "Chart" basemap tiles). Confirmed via direct API testing:
NOAA's `Land_Area` polygon layer genuinely covers river/inlet banks — querying it with the exact
Port Monmouth → Red Bank line as input geometry returned real land polygons crossing that line,
proving this data source catches what OSM missed. Also gave richer channel data: buoy/beacon
side read directly from the chart's `CATLAM` attribute (1=port, 2=starboard) instead of parsing
OSM tag strings, plus real `Recommended_Track_line`/`Navigation_Line` data.

This genuinely fixed the Red Bank case.

## New bugs surfaced by NOAA's much denser data

1. **Point-in-polygon numerical instability at boundaries.** Ray-casting point-in-polygon tests
   are unstable for points sitting exactly on or very near a polygon's boundary — and routing
   waypoints necessarily are boundary vertices, by construction (they're picked from the
   obstacle's own outline). Fixed by keeping sample points away from edge endpoints (a margin on
   each side of any sampled segment).
2. **NOAA clips land features at chart-cell boundaries.** Nautical charts are produced and
   maintained cell by cell. A single real landmass that straddles a cell edge — confirmed case:
   **Point Comfort itself** — gets recorded as two separate `Land_Area` polygons with a small
   (tens of meters) artificial gap between them that isn't real water.

## Fixes attempted for the chart-cell-seam problem, in order

1. Widen the sampling margin away from edge endpoints (helped the boundary-instability bug, not
   the seam bug).
2. A verify-then-repair retry loop: build the graph fast with a cheap edge test, verify the
   Dijkstra result with a thorough (point-sampled) check, and if a specific edge turns out to be
   a false "clear," remove just that edge and re-solve. Retry budgets of 20, 40, 150, and 200
   attempts were all tried.
3. Trust consecutive vertices of the *same* polygon ring as guaranteed-safe edges (walking the
   actual charted boundary can't cross land) — always available as a fallback "hug the shore"
   path even when shortcuts fail verification.
4. Trust short hops (under ~60m) between close vertices from *different* chart-cell rings — an
   attempt to bridge the artificial seam gap directly, since it's only ever tens of meters wide.

Each of these fixed something real: Sandy Hook's channel-snapping and Red Bank's river case both
ended up correct and safe. **Point Comfort specifically never converged on a valid detour**
within any retry budget tried — there was always some other invalid "shortcut" edge nearby that
the retry loop tried and correctly rejected before it could have reached a working path, if one
even existed in the searched area. It never drew a wrong line — every failure mode built into
this system surfaces as an explicit "unverified, add a manual waypoint" state rather than a
silent bad line — but it also never fully solved this one case.

## Where it was left

Shipped once (the NOAA-based rebuild, "unverified" fallback included) as an honest, non-lying
degradation. After reviewing it live, the decision was to pause rather than live with the
conservative fallback for cases like Point Comfort, and revert the live route line back to plain
manual routing until there's a real fix.

## Ideas not yet tried, for next time

- **Proper polygon union/dissolve.** The real fix for the chart-cell-seam problem: merge
  touching/overlapping polygon fragments from adjacent chart cells into one unified shape
  *before* building the routing graph, instead of trying to detect and bridge the seam
  afterward with heuristics. More work than anything tried here (a real computational-geometry
  polygon-union operation), but addresses the root cause rather than patching around it.
- **Widen the search corridor specifically when the retry loop is failing near a suspected
  seam** — the corridor filter that keeps the graph small may be cutting off the vertices that
  would complete a genuinely valid detour.
- **A different approach entirely** — e.g., a marine-routing API/service built for this exact
  problem, if one exists with acceptable licensing/cost for a free hobby app, rather than a
  from-scratch client-side visibility graph over raw chart polygons.

## NOAA ENC API reference (so next time doesn't re-discover this from scratch)

Base host: `https://gis.charttools.noaa.gov/arcgis/rest/services/encdirect/` — free, no API
key, and CORS-open (the server reflects `Access-Control-Allow-Origin` back to whatever `Origin`
the browser sends, so it works from any deployed domain including Netlify). Same host already
used for this app's "Chart" basemap tiles, just a different sub-service exposing queryable
vector geometry instead of pre-rendered tiles.

There are four scale-band `MapServer` services, each covering the whole US chart suite merged
(query by arbitrary bbox and it returns all matching features regardless of which underlying
chart cell they came from). Two were used; the finer two (`enc_approach`, `enc_general`) exist
but were coarser than needed for Raritan Bay:
- `enc_harbour/MapServer` — finest detail, near ports/marinas/rivers
- `enc_coastal/MapServer` — broader open-water coverage

**Each service has its OWN layer-ID numbering for the same feature classes.** Layer IDs
confirmed via each service's `?f=json` layer list:

| Feature class                | `enc_harbour` id | `enc_coastal` id |
|------------------------------|:----------------:|:----------------:|
| Land_Area (polygon)          | 233              | 171              |
| Fairway_area (polygon)       | 208              | 150              |
| River_area (polygon)         | 236              | 174              |
| Recommended_Track_line       | 134              | 102              |
| Navigation_Line              | 132              | 99               |
| Buoy_Lateral_point           | 6                | 5                |
| Beacon_Lateral_point         | 1                | 1                |
| Coastline_line               | 84               | 70               |

Query pattern (ArcGIS REST `query` endpoint, GeoJSON out, WGS84 lat/lng):
```
GET {host}{service}/MapServer/{layerId}/query
  ?geometry=<xmin>,<ymin>,<xmax>,<ymax>   (lng,lat order for envelope)
  &geometryType=esriGeometryEnvelope
  &inSR=4326&outSR=4326
  &spatialRel=esriSpatialRelIntersects
  &outFields=*&f=geojson
```
The server can also do the crossing test itself: pass `geometryType=esriGeometryPolyline` with a
JSON `{"paths":[[[lng,lat],[lng,lat]]],"spatialReference":{"wkid":4326}}` as `geometry` and it
returns exactly the polygons that line crosses (this is how the Port Monmouth→Red Bank
land-crossing was confirmed).

Field notes:
- **`CATLAM`** on `Buoy_Lateral_point`/`Beacon_Lateral_point`: 1 = port (green), 2 = starboard
  (red). Verified against real samples (CATLAM=1 paired 100% with COLOUR green, =2 with red).
  Much cleaner than parsing OSM colour/category tag strings.
- **`DSNM`** = source chart cell id (e.g. `US5NJ1UM.000`) — multiple different values come back
  in one bbox query, confirming the merged-coverage behavior. This field is also the fingerprint
  of the chart-cell-seam problem: the two Point Comfort land fragments carry different `DSNM`s.

**Layers found but never integrated** (deliberately deferred, not forgotten): `Fairway_area`
(real marked-channel polygons — ~10 near Sandy Hook vs OSM's 1) and `River_area`. They weren't
used because a polygon's boundary vertices don't make good route via-points for the gate-
threading algorithm as written (routing between the two edges of a channel polygon zigzags
instead of following a centerline). Using them well would need either a point-in-polygon
corridor constraint or a centerline-extraction step — a natural v1.1, not required to close the
original land-crossing bug.

## Where the code still lives

Every line described above is intact in git history, not deleted from the project — only
removed from the live `index.html`. The full working (if imperfect) implementation spans
commits `68cbb4c` through `2a97a65` on `main`:

- `68cbb4c` — initial coastline auto-detour
- `ce8d524` — visibility-graph + Dijkstra rewrite
- `737e1bc` — fetch-failure caching fix
- `f614fdf` — OSM channel-snapping (buoy gates)
- `2a97a65` — NOAA ENC rebuild + seam-artifact fixes

`git show 2a97a65:index.html` (or check out that commit) to see the last working state in full,
including the `routeAroundLand`/`coastlineFor`/`channelDataFor`/`channelPath`/`computeLeg`
functions and the `unverified`-flag plumbing through `getRoutedLeg`/`draw()`/`renderRoute()`.
