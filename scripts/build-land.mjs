// Offline preprocessor: pull NOAA ENC Land_Area for the app's target region, tile-merge
// (dissolve chart-cell seams) with polygon-clipping, simplify, and write a single static JSON
// (`data/land-njny.json`) the app loads at startup instead of querying NOAA per leg.
//
// Run: `npm install && npm run build:land`
// The output is checked into git — re-run only when NOAA updates its ENC charts (rare).

import polygonClipping from 'polygon-clipping';
import { writeFileSync, mkdirSync, statSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = dirname(HERE);
const OUT_FILE = `${REPO}/data/land-njny.json`;

// Full NJ / NY harbour coast: Cape May → south shore Long Island
const BBOX = { w: -75.0, s: 38.9, e: -73.5, n: 40.9 };

const TILE_DEG = 0.25;          // 0.25° x 0.25° sub-tiles — small enough to stay under NOAA's per-response feature cap
const TILE_DELAY_MS = 250;      // courteous spacing between NOAA calls
const SIMPLIFY_M = 40;          // Douglas-Peucker perpendicular tolerance (metres) — well under boat-route granularity
const FETCH_TIMEOUT_MS = 30000;
const HOST = 'https://gis.charttools.noaa.gov/arcgis/rest/services/encdirect/enc_harbour/MapServer/233/query';

const sleep = ms => new Promise(r => setTimeout(r, ms));

function ringsOf(feat) {
  const g = feat.geometry;
  if (!g) return [];
  if (g.type === 'Polygon') return [g.coordinates];             // one Polygon = one outer ring + holes
  if (g.type === 'MultiPolygon') return g.coordinates;          // array of Polygons
  return [];
}

async function fetchTile(w, s, e, n) {
  const params = new URLSearchParams({
    geometry: `${w},${s},${e},${n}`,
    geometryType: 'esriGeometryEnvelope',
    inSR: '4326', outSR: '4326',
    spatialRel: 'esriSpatialRelIntersects',
    outFields: 'OBJECTID',
    returnGeometry: 'true',
    f: 'geojson'
  });
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), FETCH_TIMEOUT_MS);
  try {
    const res = await fetch(`${HOST}?${params}`, { signal: ctl.signal });
    clearTimeout(timer);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const gj = await res.json();
    return gj.features || [];
  } catch (e) {
    clearTimeout(timer);
    throw e;
  }
}

function haversine(a, b) {
  const R = 6371000, toR = x => x * Math.PI / 180;
  const dLat = toR(b[1] - a[1]), dLon = toR(b[0] - a[0]);
  const s = Math.sin(dLat / 2) ** 2 + Math.cos(toR(a[1])) * Math.cos(toR(b[1])) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(s));
}

// Perpendicular distance from point p to segment a-b, converted to metres via haversine at a's latitude
function perpDistanceM(p, a, b) {
  // local equirectangular projection anchored at `a`
  const latR = a[1] * Math.PI / 180;
  const mPerLat = 111320, mPerLng = 111320 * Math.cos(latR);
  const px = (p[0] - a[0]) * mPerLng, py = (p[1] - a[1]) * mPerLat;
  const bx = (b[0] - a[0]) * mPerLng, by = (b[1] - a[1]) * mPerLat;
  const bLen2 = bx * bx + by * by;
  if (bLen2 < 1) return Math.hypot(px, py);
  const t = Math.max(0, Math.min(1, (px * bx + py * by) / bLen2));
  return Math.hypot(px - t * bx, py - t * by);
}

// Douglas-Peucker on a closed ring, keeping first & last identical
function simplifyRing(ring, tolM) {
  if (ring.length < 5) return ring;
  const keep = new Array(ring.length).fill(false);
  keep[0] = keep[ring.length - 1] = true;
  const stack = [[0, ring.length - 1]];
  while (stack.length) {
    const [i, j] = stack.pop();
    let maxD = 0, idx = -1;
    for (let k = i + 1; k < j; k++) {
      const d = perpDistanceM(ring[k], ring[i], ring[j]);
      if (d > maxD) { maxD = d; idx = k; }
    }
    if (maxD > tolM && idx !== -1) {
      keep[idx] = true;
      stack.push([i, idx], [idx, j]);
    }
  }
  const out = [];
  for (let i = 0; i < ring.length; i++) if (keep[i]) out.push(ring[i]);
  return out;
}

function simplifyPolygon(poly, tolM) {
  return poly.map(ring => {
    const simp = simplifyRing(ring, tolM);
    return simp.length >= 4 ? simp : ring;   // drop trivial degeneracies (keep raw ring)
  }).filter(ring => ring.length >= 4);
}

function countVerts(mp) {
  let n = 0;
  for (const poly of mp) for (const ring of poly) n += ring.length;
  return n;
}

async function main() {
  const cols = Math.ceil((BBOX.e - BBOX.w) / TILE_DEG);
  const rows = Math.ceil((BBOX.n - BBOX.s) / TILE_DEG);
  const total = cols * rows;
  console.log(`Fetching NOAA ENC Land_Area for ${BBOX.w},${BBOX.s},${BBOX.e},${BBOX.n}`);
  console.log(`  ${cols} × ${rows} = ${total} tiles @ ${TILE_DEG}°, ~${(TILE_DELAY_MS * total / 1000).toFixed(0)}s network floor`);

  // collect every polygon as its own MultiPolygon-shaped [ [ring, ...] ]
  const allPolys = [];
  let fetched = 0, features = 0, rawVerts = 0;
  for (let iy = 0; iy < rows; iy++) {
    for (let ix = 0; ix < cols; ix++) {
      const w = BBOX.w + ix * TILE_DEG;
      const s = BBOX.s + iy * TILE_DEG;
      const e = Math.min(BBOX.e, w + TILE_DEG);
      const n = Math.min(BBOX.n, s + TILE_DEG);
      let feats;
      try {
        feats = await fetchTile(w, s, e, n);
      } catch (err) {
        console.warn(`  tile ${ix},${iy} FAILED (${err.message}) — retrying once after 2s`);
        await sleep(2000);
        feats = await fetchTile(w, s, e, n);
      }
      for (const f of feats) {
        for (const rings of ringsOf(f)) {
          allPolys.push(rings);       // rings = [outer, ...holes] in [lng,lat] pairs
          features++;
          for (const ring of rings) rawVerts += ring.length;
        }
      }
      fetched++;
      if (fetched % 8 === 0 || fetched === total) {
        console.log(`  fetched ${fetched}/${total} tiles, cumulative ${features} polygons`);
      }
      await sleep(TILE_DELAY_MS);
    }
  }
  console.log(`Fetched ${features} polygons, ${rawVerts.toLocaleString()} raw vertices from ${fetched} tiles`);

  // Pre-simplify each raw polygon BEFORE union — polygon-clipping's cost scales badly with vertex count
  // (2845 polygons × ~195 vertices = 554k vertices overflowed its priority queue). Chart-scale vertex
  // detail is far finer than a boat route needs, so shrinking each polygon first is lossless for us.
  console.log(`Pre-simplifying ${allPolys.length} raw polygons at ${SIMPLIFY_M}m…`);
  const preSimp = allPolys
    .map(p => simplifyPolygon(p, SIMPLIFY_M))
    .filter(p => p.length && p[0].length >= 4);
  const preVerts = preSimp.reduce((n,p)=>n + p.reduce((m,r)=>m+r.length,0),0);
  console.log(`  after pre-simplify: ${preSimp.length} polygons, ${preVerts.toLocaleString()} vertices`);

  // Merge — batch union to keep polygon-clipping's internal priority queue bounded. Small batches (~40)
  // dissolve within-batch overlaps; then merge batch results pairwise.
  console.log('Unioning (dissolving chart-cell seams)…');
  const t0 = Date.now();
  const BATCH = 40;
  let running = null;   // accumulating MultiPolygon
  for (let i = 0; i < preSimp.length; i += BATCH){
    const chunk = preSimp.slice(i, i + BATCH).map(p => [p]);
    let chunkMerged;
    try {
      chunkMerged = polygonClipping.union(...chunk);
    } catch (e) {
      // fall back to pairwise inside the chunk on failure (rare — only if unusually gnarly geometry)
      chunkMerged = chunk[0];
      for (let j = 1; j < chunk.length; j++){
        try { chunkMerged = polygonClipping.union(chunkMerged, chunk[j]); }
        catch(e2) { /* skip poison polygon */ }
      }
    }
    if (running === null) running = chunkMerged;
    else {
      try { running = polygonClipping.union(running, chunkMerged); }
      catch(e){
        // if the running set gets too big to union in one shot, concatenate as a MultiPolygon and let
        // downstream simplify handle the (unmerged, but still correct) result
        running = [...running, ...chunkMerged];
      }
    }
    if ((i / BATCH) % 10 === 0){
      console.log(`  batches ${(i / BATCH + 1)}/${Math.ceil(preSimp.length / BATCH)} done, current polys ${running.length}`);
    }
  }
  const merged = running || [];
  console.log(`  ${merged.length} merged polygons after union (${((Date.now() - t0) / 1000).toFixed(1)}s), ${countVerts(merged).toLocaleString()} vertices`);

  // Simplify each merged polygon again to catch any duplicate/near-collinear vertices from the union
  console.log(`Post-simplifying at ${SIMPLIFY_M}m tolerance…`);
  const simplified = merged.map(p => simplifyPolygon(p, SIMPLIFY_M)).filter(p => p.length > 0);
  console.log(`  after simplify: ${simplified.length} polygons, ${countVerts(simplified).toLocaleString()} vertices`);

  // Convert to the app's in-memory shape: array of {lat,lng} rings (outer only — a hole is water inside land,
  // not an obstacle for routing purposes, matches the app's existing polyRingsOf)
  const ways = [];
  for (const poly of simplified) {
    if (!poly.length) continue;
    ways.push(poly[0].map(([lng, lat]) => ({ lat, lng })));   // outer ring only
  }

  // Write
  const out = {
    bbox: [BBOX.w, BBOX.s, BBOX.e, BBOX.n],
    generated: new Date().toISOString(),
    source: 'NOAA ENC enc_harbour/MapServer/233 (Land_Area)',
    simplify_m: SIMPLIFY_M,
    polygons: ways.length,
    vertices: ways.reduce((n, w) => n + w.length, 0),
    ways
  };
  mkdirSync(dirname(OUT_FILE), { recursive: true });
  writeFileSync(OUT_FILE, JSON.stringify(out));
  const sz = statSync(OUT_FILE).size;
  console.log(`Wrote ${OUT_FILE}`);
  console.log(`  ${out.polygons} polygons, ${out.vertices.toLocaleString()} vertices, ${(sz / 1024 / 1024).toFixed(2)} MB`);
}

main().catch(err => { console.error(err); process.exit(1); });
