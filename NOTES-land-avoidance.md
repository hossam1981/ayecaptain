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

## Research: prior art & viable next approaches (2026-09, no code written)

Investigated two links suggested as leads plus a broader search for who has solved this.

### The two suggested links were dead ends
- **inlet.tech** (`kb.inlet.tech/kb/inlet-api-guide`) — a hospitality / property-access
  (smart-lock booking) API. Nothing to do with marine navigation. Name coincidence only.
- **riverml.xyz** ("River") — a Python *online machine-learning* library (streaming/incremental
  learning). Matched the search by the word "river," but unrelated to waterway routing.

### Reference implementation that already does exactly this: OpenCPN
Open-source (C++) chart plotter. It extracts obstacle geometry from the **same NOAA ENC S-57
charts we're already using**, builds an R-tree spatial index, generates obstacle-aware paths
around islands/peninsulas/narrow channels, and does **draft-based shoal avoidance** (route
through water deeper than vessel draft + a safety margin). This is our feature, already built and
sea-tested. Can't drop C++ into a browser PWA, but its approach is the model to study — especially
the draft/depth-contour angle, which is a smarter obstacle definition than "land polygon" alone.

### The chart-cell-seam problem has a standard, named fix — and it works in the browser
The Point Comfort failure (one landmass split into two cell-clipped polygons with a ~26m
artificial gap) is a classic GIS "close the seam" problem. Standard solution is a **morphological
closing**: `buffer(+ε)` each polygon → `union` → `buffer(−ε)` back. The small outward buffer
makes the two fragments overlap so the union actually dissolves the shared seam (plain union
alone does NOT merge polygons that merely *nearly* touch — which is exactly why our attempt-4
heuristics struggled).

Crucially this is doable **client-side, no backend**, with **Turf.js** (`turf.union` +
`turf.buffer`, loadable from a CDN the same way Leaflet already is): heal the NOAA polygons at
route time before building the visibility graph. This upgrades the earlier vague "polygon
union/dissolve" idea into something concrete and compatible with this app's static-PWA model.

### Two architecture options for a real retry, both fit "static PWA, no backend"
1. **Client-side heal with Turf.js** — load Turf from CDN, run buffer→union→buffer on the fetched
   NOAA `Land_Area` polygons to dissolve cell seams before running the existing visibility-graph +
   Dijkstra. Smallest change to what's already written; still makes a live NOAA fetch per route.
2. **Offline-preprocessed routing graph (probably the cleaner fit)** — run `shapely`
   (`shapely.ops.unary_union`, buffer-close) *once, offline*, to build a clean seamless water
   polygon / prebuilt routing graph for the app's actual operating area (Raritan Bay + approaches),
   and ship it as a **static JSON asset**. The app then just does fast pathfinding on the baked
   graph — no per-route Overpass/NOAA call (sidesteps the rate-limiting we kept hitting), matches
   how the app already ships static assets, and moves all the heavy/fragile geometry offline where
   it can be inspected and corrected by hand.

### Ocean-scale routers exist but are the wrong scale
`searoute` (Python/JS), `maritime-routing`, `OpenStreetMap-Ship-Routing` — all solve port-to-port
ocean crossings as shortest-path on a water graph, but on a ~0.5° grid (≈55 km cells). Far too
coarse for bays/inlets/rivers (tens of meters). Useful confirmation that "shortest path on a
graph of water" is the universally-standard framing, but none are directly usable at our scale.

### One NOAA-specific lead worth checking first
NOAA's own **"ENC Direct to GIS"** portal states its layers are "created by merging S-57 object
classes from all NOAA ENCs into **seamless** layers" — yet the query endpoint we used returned
cell-clipped fragments (different `DSNM` per piece). Worth checking whether a different
endpoint/format/parameter returns *already-dissolved* geometry, which would eliminate the seam
problem at the source with no union step at all.

### CORRECTION (verified against the raw API, 2026-09): the seam gap was OUR bug, not NOAA's
Directly fetched the two Point Comfort `Land_Area` fragments in full, unsimplified:
- OBJECTID 699786 (chart cell `US5NYCAE`) — 442-point ring
- OBJECTID 699790 (chart cell `US5NYCAF`) — 954-point ring

**They share 5 vertices at exactly 0.0m apart along the seam — the raw polygons genuinely TOUCH.**
NOAA's data has no gap. The ~26m gap that broke routing was created entirely by our own
`simplifyWay(120m)` step, which thinned each polygon *independently* and happened to delete the
shared seam vertices, tearing open a fake gap that was never in the source.

### FOLLOW-UP TEST (2026-09): the seam/merge fix was DISPROVEN — the real blocker is deeper
Built a standalone Node harness running the exact committed routing algorithm (commit `2a97a65`)
against live NOAA Point Comfort data, to test the merge-before-simplify idea before trusting it.
Results:
- **Current production behavior** (simplify each polygon separately): returns `unverified`. Expected.
- **Raw polygons, no simplification at all** (so no torn seam): **STILL returns `unverified`.**
  This disproves the merge/seam hypothesis outright — the seam tear was never the blocker.
- **Root cause found by tracing the graph**: with the real from/to (both confirmed in water on
  either side of the peninsula), the **destination node connects to the entire visibility graph
  by only ONE edge** (`to-degree: 1`). The endpoints sit in a tight coastal pocket. The
  verify-then-repair loop correctly rejects that single edge (it's a phantom-clear shortcut that
  actually clips land on the sampled check), which orphans the destination — Dijkstra then reports
  the graph disconnected and the function gives up. Not a seam problem, not a data problem: a
  **graph-connectivity-at-the-endpoints** problem.
- Tried the obvious next fix in the harness (collect boundary vertices from ALL rings within the
  corridor, not just rings the direct line crosses): connectivity improved (`to-degree` 1→4) but
  it **still disconnects** after the repair loop removes the bad edges. So even better node
  selection doesn't close it — this is genuinely hard local geometry.

**Honest confidence, post-test: LOW for any quick fix.** The easy explanations (seam, simplify
order, corridor width, node count) are all now ruled out by direct experiment. A real fix has to
attack endpoint connectivity in tight pockets — e.g. explicitly connect each endpoint to its
nearest *water-side* boundary vertices and let the path hug the shore out of the pocket, or seed
intermediate water nodes (not just land-boundary vertices) so there's always a navigable corridor
of nodes through open water. That's genuine algorithm design + testing, not a tweak — which is
exactly why this stays parked as research, not a near-term fix. The harness
(`/tmp/pointcomfort_test.mjs` at the time of writing; reconstruct from commit `2a97a65` if gone)
is the right place to prototype any candidate fix against real data before touching the app.

### Sources
- OpenCPN (open-source ENC-based chart plotter, obstacle/shoal-aware routing) —
  https://github.com/OpenCPN/OpenCPN , https://en.wikipedia.org/wiki/OpenCPN
- Turf.js `union` / `buffer` (browser-side polygon geometry) —
  https://turfjs.org/docs/api/union , https://turfjs.org/docs/api/buffer
- Shapely `unary_union` (offline seam dissolve) —
  https://shapely.readthedocs.io/en/stable/reference/shapely.unary_union.html
- searoute-py (ocean-scale reference) — https://github.com/genthalili/searoute-py
- OpenStreetMap-Ship-Routing — https://github.com/sibmr/OpenStreetMap-Ship-Routing
- NOAA ENC Direct to GIS ("seamless layers" claim) — https://nauticalcharts.noaa.gov/learn/encdirect/
- inlet.tech (confirmed unrelated) — https://kb.inlet.tech/kb/inlet-api-guide/
- riverml (confirmed unrelated) — https://riverml.xyz/0.25.0/api/overview/

### BREAKTHROUGH (2026-09, tested): a water-grid router solves the endpoint-connectivity blocker
Once the real blocker was pinned as "endpoints in a tight pocket barely connect to a
boundary-vertex visibility graph," prototyped the standard robust alternative in the harness: a
**water-grid router** — instead of using land-boundary vertices as nodes, lay a regular grid of
candidate nodes across the leg's corridor, keep only the ones in open water (`!pointOnLand`),
connect neighbours within ~1.8 cells by clear (non-land-crossing) edges, connect each endpoint to
nearby water nodes generously, and Dijkstra. This is how the ocean-scale routers (searoute etc.)
work, just at a fine local scale.

Tested against **live NOAA data**, real geometry checks, the exact `edgeCrossesLand` verifier:
- **Point Comfort E→W (the case that defeated the whole session): SOLVED** — verified-clear route,
  ~1.72 nm around the peninsula vs 1.49 nm straight, ~300 ms at 150–200 m grid spacing.
- **Robustness**: 40 randomly-perturbed water-to-water routes around Point Comfort (±650 m jitter),
  22 landed with both endpoints genuinely in water → **21 verified-clear detours, 1 correctly
  straight, 0 honest-unverified, and 0 wrong land-crossing lines.**
- **No regressions**: Sandy Hook and open-water legs (direct line already clear) correctly return a
  plain straight line untouched; legs whose endpoint I'd mistakenly placed on land, and Red Bank
  (no short water route exists — the river is only reachable miles around via Sandy Hook),
  correctly return `unverified`/warn rather than a wrong line.
- **Zero wrong lines in every single test.** The safety property (never silently draw across land)
  holds unconditionally.

**Confidence now — calibrated:**
- *That the water-grid approach solves the Point Comfort / boxed-in-endpoint failure that caused
  the revert:* **high (~90%)** — directly proven, 22/22 valid cases clean against real data.
- *That it's drop-in ship-ready as a complete feature:* **moderate** — still needs: integration
  into the app's async/cache/render plumbing; a node-count cap + spacing strategy for dense harbors
  (stayed <520 nodes / sub-second here, but untested at scale); optional path-straightening for
  quality (grid paths are slightly jagged, 11–20 pts); and acceptance that Red-Bank-class
  destinations (no short water route) still correctly degrade to "add a manual waypoint," which is
  a real product limitation of ANY local-corridor router, not a bug.

Prototype harness: `/tmp/gridroute_test.mjs` at time of writing (self-contained; reconstruct the
geometry primitives from commit `2a97a65` if gone). This is the thing to integrate next time —
it's the first approach across four attempts that actually clears the hardest known case.

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
