# Places: offline search and speed cameras

The "places and road-safety" part of a region pack: `places.sqlite`, built on
the PC by `tool/build_places.sh <pack>` from the pack's `region.osm.pbf`, and
read on the device by the code in `lib/places/`.

- Search index: addresses, streets, localities, POIs (SQLite FTS5).
- Speed / enforcement cameras with the direction of travel they apply to
  (R-tree).
- No per-road speed limits: the routing engine supplies them along the route.
  The only exception is a camera's own limit, which falls back to the
  `maxspeed` of the road it stands on (flagged, see `maxspeed_from_road`).

Everything comes from OpenStreetMap; nothing needs a key or registration.

## Building

```
tool/build_region.sh moscow russia/central-fed-district 35.1,54.2,40.3,57.0
tool/build_places.sh moscow        # -> data/packs/moscow/places.sqlite
```

`build_places.sh` runs `tool/places/build_places.py` in the local Docker image
`mapsoly-places:1` (`tool/docker/places/Dockerfile`: `python:3.13-slim` +
`osmium==4.0.2`, `shapely==2.1.1`, `numpy==2.3.1`; 309 MB on disk), as the
invoking user. The image is built on first use. Nothing is installed on the
host.

The extractor reads the PBF three times: enforcement relations, their member
nodes, then the main pass (pyosmium `FileProcessor` with node locations and
area assembly, tag-filtered in C++).

### Measured (PC: Ryzen AI 7 350, 2026-11-26/27)

| pack | region.osm.pbf | places.sqlite | build (wall) | peak RSS |
|---|---|---|---|---|
| kaliningrad (Geofabrik `russia/kaliningrad`) | 29.3 MB | 6.6 MB | 13 s | 0.23 GB |
| moscow (central-fed-district cropped to 35.1,54.2,40.3,57.0) | 366.7 MB | 82.5 MB | 2 min 28 s | 1.30 GB |

| count | kaliningrad | moscow |
|---|---|---|
| houses (unique street + number) | 105 228 | 1 074 197 |
| addresses tagged in OSM (before dedup) | 112 805 | 1 122 475 |
| streets (merged per name + locality) | 8 072 | 75 564 |
| named highway ways they were merged from | 16 737 | 141 060 |
| localities and administrative areas | 2 094 | 27 343 |
| POIs | 10 344 | 201 587 |
| cameras | 10 | 3 130 |

Where the bytes go (moscow): FTS index 38.6 MB, `place` 20.0 MB, `house`
19.6 MB, cameras 0.3 MB.

## Schema (version 1)

Coordinates of places and houses are integers, degrees × 1e5 (≈1.1 m).
Camera coordinates are REAL degrees.

```sql
meta(key TEXT PRIMARY KEY, value TEXT)
category(id INTEGER PRIMARY KEY, code TEXT, label TEXT, kind INTEGER, syn TEXT)
place(id INTEGER PRIMARY KEY, kind INTEGER, cat INTEGER, name TEXT, alt TEXT,
      loc INTEGER, ctx TEXT, addr TEXT, lat INTEGER, lon INTEGER, w INTEGER)
place_fts USING fts5(name, alt, ctx, tag, content='', detail=column,
      columnsize=0, prefix='1 2 3', tokenize="unicode61 remove_diacritics 2")
house(street INTEGER, hn TEXT, lat INTEGER, lon INTEGER,
      PRIMARY KEY(street, hn)) WITHOUT ROWID
camera(id INTEGER PRIMARY KEY, type TEXT, lat REAL, lon REAL, bearing INTEGER,
      bidir INTEGER, maxspeed INTEGER, maxspeed_from_road INTEGER,
      end_lat REAL, end_lon REAL, osm TEXT)
camera_rtree USING rtree(id, min_lat, max_lat, min_lon, max_lon)
```

### meta

`schema_version` (1), `norm_version` (1, see Normalisation), `source_date`
(PBF header timestamp; when the header has none, as after `osmium extract`,
the newest object timestamp seen), `source_file`, `built`, `bbox`
(`west,south,east,north`: header bbox, else the extent of the houses) and
`count_*` statistics (houses, streets, localities, pois, cameras and their
breakdown, dropped/odd inputs).

### category

`kind`: 0 locality, 1 street, 2 POI. `code` is stable (`city`, `town`,
`village`, `hamlet`, `suburb`, `district`, `region`, `street`, `area`,
`fuel`, `pharmacy`, `metro`, …; the full list is `POI_CATS` / `LOC_CATS` in
`build_places.py`), `label` is the Russian name shown in the UI, `syn` the
normalised words that find any object of a POI category ("азс заправка
бензин топливо").

### place

One row per searchable object.

- `kind` 0 **locality**: `place=city|town|village|hamlet|isolated_dwelling|
  allotments|suburb|quarter|neighbourhood|locality` (nodes and polygons; a
  polygon and a same-named node inside it become one row), named
  `landuse=allotments` (СНТ), and `boundary=administrative` level 6
  (`district`) and 4 (`region`).
- `kind` 1 **street**: all named `highway=*` ways with the same name in the
  same locality are one row (`cat` = `street`); its point is the way midpoint
  nearest to the centre of the group. Outside any locality the grouping scope
  is the district, else the region. Streets that exist only in `addr:street`
  get a row too. `cat` = `area` is an `addr:place` value that is not a known
  locality (microdistrict, territory).
- `kind` 2 **POI**: `amenity`, `shop`, `tourism`, `leisure`, `railway`
  (stations; subway stations are `metro`), `aeroway=aerodrome`, `office`,
  `historic`, `landuse=cemetery`, mapped to ~55 categories. Unnamed objects
  are kept only for categories where the category itself is the point (fuel,
  pharmacy, ATM, bank, hospital, police, post office, toilets, car wash, car
  repair, charging); their name is the label plus brand ("АЗС Лукойл").
- `name`: display name (`name` tag). `alt`: other names, `"; "`-separated
  (`name:ru`, `name:en`, `alt_name`, `old_name`, `short_name`,
  `official_name`, `loc_name`; `ref` for roads; `brand`/`operator` for POIs).
- `loc`: `place.id` of the locality (or, for streets outside localities, the
  district/region) the object is in; NULL for settlements themselves.
- `ctx`: for localities, "district, region" for disambiguation.
- `addr`: for POIs with address tags, "улица Ленина, 5".
- `w`: weight 0..120 (type priority): city 100, town 85, region 90, district
  70, village 65, hamlet 55, streets 46..62 by road class, POIs 15..60 by
  category; settlements get +3·log10(population).
- **`id` is assigned in order of decreasing `w`.** FTS5 returns rows in rowid
  order, so `… MATCH ? ORDER BY rowid LIMIT n` yields the n most important
  matches without sorting. The search relies on this.

### place_fts

Contentless FTS5 (`rowid` = `place.id`), text pre-normalised by the builder:

- `name`: tokens of `name`;
- `alt`: tokens of the alternative names and, for POIs, of the category label
  and synonyms, minus those already in `name`;
- `ctx`: tokens of the locality name, its `ctx`, and for POIs `addr:street`;
- `tag`: machine tokens: `k<kind>` and three geo cells
  `m<y>x<x> f<y>x<x> c<y>x<x>` with, for `Y = lat5 + 9000000`,
  `X = lon5 + 18000000` (integer division): micro `Y/1250, X/2500`
  (0.0125°×0.025°, ≈1.4×1.6 km at 55°N), fine `Y/5000, X/10000`, coarse
  `Y/40000, X/80000`.

`detail=column, columnsize=0` keeps it small; `bm25()` is not available in
this configuration (and is not used).

### house

`street` is the `place.id` the house hangs on: its street, its `addr:place`
area, or the locality itself for addresses with neither. `hn` is the
canonical house number (see below). One row per (street, number); when a
building outline and an address node carry the same address the outline's
centre wins. Building centre = centre of the outer ring's bounding box.

Locality of an object: the smallest `place=*` polygon containing it; else a
city/town whose administrative boundary has exactly the same name and
contains it (how Moscow works); else the nearest settlement node within a
type-dependent radius (city 8 km, town 4, village 1.5, hamlet 0.8, relative
distance decides). An address whose `addr:city` names a different settlement
within 30 km is moved there unless a real polygon said otherwise.

### camera

- `type`: OSM `enforcement=*` value (`maxspeed`, `average_speed`,
  `traffic_signals`, `mindistance`, `access`, `road_marking`, `check`,
  `maxweight`, combinations with `;`); bare `highway=speed_camera` nodes are
  `maxspeed`.
- `lat`,`lon`: the device; for `average_speed`, the `from` node (section
  start), with `end_lat`,`end_lon` = the `to` node.
- `bearing`: direction of travel the camera applies to (degrees, 0 = north),
  NULL = unknown. `bidir` = 1: both directions along the `bearing` axis.
- `maxspeed`: from the relation, else the device node, else the `maxspeed` of
  the road the camera was snapped to (`maxspeed_from_road` = 1).
  `RU:urban/rural/motorway/living_street` are mapped to 60/90/110/20.
- `osm`: `n<id>` or `r<id>`.

How direction is derived:

1. `type=enforcement` relation with `from` node(s): one row per `from`. The
   bearing is that of the drivable road at the `from` node (nearest segment
   within 50 m), oriented towards the device (or the `to` node); on a one-way
   road simply the direction of the way. Without a road nearby: the straight
   bearing from → device.
2. Relation without `from`, or a bare `highway=speed_camera` node: the node is
   snapped to the nearest drivable way within 50 m (motorway … residential,
   living_street; `service` and tracks are ignored). One-way road (incl.
   motorways and roundabouts) → that direction. Two-way road → `bidir` = 1
   with the road axis, so a camera on a crossing street is still filtered
   out. `direction=forward|backward` on a node lying on the way is honoured.
3. No road within 50 m → `bearing` NULL (reported for every direction).

The numeric/cardinal `direction=*` tag is **not** used: the OSM wiki defines
it as the way the camera *faces*, which does not tell which traffic it
photographs.

## Normalisation (version 1)

Implemented twice, rule for rule: `tool/places/ru_normalize.py` (index time)
and `lib/places/normalize.dart` (query time). Both are checked against the
same vectors, `test/places/normalize_cases.json`:

```
docker run --rm -v $PWD:/w -w /w mapsoly-places:1 \
  python tool/places/ru_normalize.py test/places/normalize_cases.json
flutter test test/places/normalize_test.dart
```

A change to the rules must bump `NORM_VERSION` / `normVersion`; the app
refuses packs with another `norm_version`.

Text → tokens:

1. Lowercase; `ё` → `е`; decomposed `й`/`ё` are composed; combining marks are
   removed.
2. Hyphenated abbreviations (as whole words): `пр-т`, `пр-кт` → `проспект`;
   `пр-д` → `проезд`; `б-р` → `бульвар`; `р-н` → `район`; `мкр-н`, `м-н` →
   `микрорайон`; `ш-се` → `шоссе`; `пл-дь` → `площадь`; `наб-я` →
   `набережная`; `ул-ца` → `улица`; `п-к` → `переулок`.
3. Ordinal endings after a number are dropped: `1-я`, `2-й`, `3-го`,
   `50-летия` stays `50 летия`; glued `3я`, `2й`, `1ая` too.
4. Everything that is not a letter or digit separates tokens.
5. Whole-token abbreviations: `ул` → `улица`; `пр`, `просп`, `пркт` →
   `проспект`; `пер` → `переулок`; `ш` → `шоссе`; `пл` → `площадь`; `бул`,
   `бульв` → `бульвар`; `наб` → `набережная`; `туп` → `тупик`; `прд` →
   `проезд`; `ал` → `аллея`; `д` → `дом`; `к`, `корп` → `корпус`; `стр` →
   `строение`; `г`, `гор` → `город`; `п`, `пос` → `поселок`; `дер` →
   `деревня`; `мкр`, `мкрн` → `микрорайон`; `обл` → `область`; `им` →
   `имени`.

Remaining diacritics (`é`, `ö`) are folded by the FTS5 tokenizer
(`remove_diacritics 2`), the same on both sides.

House numbers have their own canonical form (`normalize_housenumber`):
lowercase, no spaces, `корпус/корп/к` → `к`, `строение/стр/с` → `с`,
`литера/лит` → `л`, leading `дом/д/владение/вл` dropped, `/` and `-` kept:
`"12 корп. 1 стр 2"` → `12к1с2`, `"5 А"` → `5а`, `"12 / 14"` → `12/14`.
`displayHouseNumber` turns it back into `12 к1 с2`, `5А`.

Query-only rules (`parseQuery`, Dart):

- The last word is a **prefix** unless the query ends with a space or
  punctuation. If it was expanded as an abbreviation while half-typed
  (`п` → `поселок`), both the raw prefix and the expansion are matched.
- A single letter anywhere is a prefix: `б. якиманка` finds `Большая
  Якиманка` (gendered `б.`/`м.`/`н.`/`в.` cannot be expanded to one word).
- **Status words** (`улица`, `проспект`, `переулок`, `шоссе`, `площадь`,
  `бульвар`, `набережная`, `тупик`, `проезд`, `аллея`, `город`, `поселок`,
  `деревня`, `село`, `микрорайон`, `район`, `область`, `дом`) are not required
  to match when the query has other words; they only raise the score of names
  that contain them.
- **House number readings.** Besides the plain reading, each of the (at most
  two, last first) number-like words is tried as a house number, together
  with what follows it (`к2`, `корпус 2`, `стр 1`, a trailing single letter):
  `ленина 5`, `5 ленина`, `ул. Ленина, д. 5 к2`, `9 мая 12` (both `12` on
  "9 Мая" and `9` on "Мая 12" are tried).

## Search

`PlacesDatabase.search(query, near:, limit:)`:

1. For every house reading: FTS finds the streets/localities matching the
   words (at most 3000, most important first), joined to `house` by primary
   key for the exact number and, while the number is still being typed, for
   numbers starting with it; the 40 nearest of each are kept. If fewer than 3
   houses were found, the matching streets themselves are added with a
   penalty.
2. Plain reading: the whole pack is searched first, top 150 by weight (300
   without `near`). If that returned everything there is, done. Otherwise the
   3×3 micro cells around `near` are searched (top 150), then the fine cells
   if the micro stage was not full, then the coarse cells likewise.
3. Candidates are scored in Dart and sorted.

MATCH expression: every required word must occur in `name`, `alt` or `ctx`,
and at least one in `name`/`alt`; stages add `tag:` terms.

### Ranking formula

```
score = 4.0 · text + 1.0 · type + 0.8 · proximity + bonus

type      = w / 120                       (houses: 1.0)
proximity = 1 / (1 + distance_km / 15)    (0 without `near`)
bonus     = +2.0  exact house number
            +1.0  same number with a suffix (5 → 5А, 5 к2), while typing
            +0.3  another number with that prefix (5 → 51), while typing
            −1.0  street offered because the house was not found
text      = 0.55 · coverage + 0.25 · exactness + 0.20 · status
```

For each required query word, against the candidate's name tokens:
1.0 exact token, 0.85 prefix (last word / initials only), else 0.8 if it is a
category synonym, else 0.6 if it is in the locality name, else 0.3 (it matched
some other name). `coverage` is the mean. `exactness` = share of query words
found in the name (or category) ÷ (1 + number of non-status name words left
unmatched). `status` = share of the query's status words present in the name,
or `coverage` when the query has none. Each alternative name is scored the
same way with a 0.95 factor and the best wins. A query consisting only of a
category's synonyms ("аптека") gives every object of the category 0.9, so
proximity decides. Constants live in `RankWeights`.

### Measured latency

`test/places/real_pack_test.dart`: every prefix of ~20 queries typed
character by character (as search-as-you-type would issue them), `near` =
city centre, limit 20, PC (Ryzen AI 7 350), Dart VM in JIT mode under
`flutter test`, system SQLite 3.54.1:

| pack | searches | p50 | p95 | p99 | max |
|---|---|---|---|---|---|
| moscow (82.5 MB) | 468 | 7.2 ms | 17.8 ms | 29 ms | 50 ms |
| kaliningrad (6.6 MB) | 360 | 1.7–2.1 ms | 5–12 ms | 8–16 ms | 9–20 ms |

(Ranges: repeated runs while other jobs were using the machine.) Not measured
on the phone.

`camerasAlong`: 46 µs for a 600 m route; 6 ms for a 20 001-point route across
the whole Moscow pack.

## Cameras on a route, alerts

- `camerasNear(p, radiusM, {courseDeg})`: R-tree box + exact distance,
  nearest first; with `courseDeg` only cameras for that direction.
- `camerasAlong(route, {corridorM = 35})`: the route is cut into ~3 km
  chunks; each chunk's bounding box (+ corridor) goes to the R-tree; a camera
  matches a segment when it is within `corridorM` of it **and**
  `|segment bearing − camera bearing| ≤ 50°` (or ≥ 130° for `bidir`; always
  for unknown direction). Each camera is reported once, at the matching
  segment it is closest to, with `alongM` (metres from the route start). For
  `average_speed` the section end is projected onto the rest of the route
  (within 2 × corridor) → `zoneEndAlongM`, null if it is not on the route.
- `CameraAlerter` (`camera_alert.dart`, pure logic): call
  `update(alongM:, speedKmh:, time:)` on every position fix.
  - `approaching`, once per camera, when it is within
    `clamp(speed · 15 s, 300 m, 1000 m)` ahead (300 m up to 72 km/h, 375 m at
    90, 540 m at 130).
  - `speeding`, once, when within `max(150 m, speed · 6 s)` and still above
    `limit + toleranceKmh` (default 0; a limit must be known).
  - `passed` 30 m behind the camera (to clear the indicator).
  - Average-speed sections with the end on the route: `zoneEntered` at the
    start, `zoneSpeeding` when the average since the start exceeds the limit
    (re-armed after it drops 3 km/h below), `zoneLeft` with the average at the
    end. A section whose end is not on the route behaves like a plain camera.
  - Cameras already behind at the first update are never announced. Pass
    `alreadyWarned: old.warnedKeys` to the alerter of a recalculated route.
  - Texts are Russian constants in `CameraAlertTexts`.

### User cameras

`UserCameraDatabase` is a separate writable SQLite file with the same
`camera` + `camera_rtree` tables (it survives pack updates), queried through
the same `CameraStore`; `mergeRouteCameras` joins pack and user results.
`importText` / `importFile` auto-detect:

- **CSV** `lat,lon,type,speed,direction`; header optional (columns are
  located by name when present), `,` `;` or TAB; `type` one of `speed`,
  `average`, `redlight`, `bus_lane`, `road_marking`, … or an OSM
  `enforcement` value; empty direction = all directions.
- **SpeedCam.txt** (iGO-style) `X,Y,TYPE,SPEED,DirType,Direction`, optionally
  with a leading `IDX`; X = longitude, Y = latitude; TYPE 1 speed, 2 built
  into traffic lights, 3 red light, 4 section, 5 mobile; DirType 0 all
  directions, 1 one direction, 2 both; SPEED 0 = unknown. **Unverified**: the
  field meanings follow community descriptions (no official spec found) and
  the importer was only tested on files written for the tests, not on a real
  third-party file. In particular "Direction" is assumed to be the heading of
  the affected traffic.

Section cameras from user files have no end point.

## Online fallback

`PhotonGeocoder` → `https://photon.komoot.io/api?q=…&limit=…&lat=…&lon=…`,
header `User-Agent: mapsoly/0.1`, 6 s timeout, no key. Never throws: an empty
list plus `lastError`. The public instance accepts `lang=default|de|en|fr`
only (`lang=ru` → HTTP 400), so no `lang` is sent and names come back in the
local language. Reachable from the development network on 2026-11-26/27:
HTTP 200 in 80–370 ms.

## Limitations

- **OSM camera coverage in Russia is incomplete.** What the data shows:
  kaliningrad — 10 cameras in the whole oblast, no enforcement relations;
  moscow pack — 3 130 rows from 2 884 `highway=speed_camera` nodes and 227
  enforcement relations: 3 029 `maxspeed`, 35 `access`, 32 `road_marking`,
  13 `traffic_signals`, 8 `check`, 4 `maxweight`, 2 `average_speed`, the rest
  combinations. Real installations (red-light, bus-lane and section control
  above all) are far more numerous. The alerts are a hint, not a guarantee;
  the user camera import exists for this reason.
- Direction is inferred, not surveyed. In the moscow pack 2 155 rows have one
  direction, 974 only the road axis (two-way road), 1 none. A camera beside a
  dual carriageway is attributed to the nearest carriageway. 731 of the 2 956
  limits are the road's `maxspeed`, not the camera's. Not checked against
  ground truth.
- Enforcement relation members that are ways (3 in the moscow pack) and the
  `section`/`force` roles are ignored.
- A camera is reported once per route, even if the route passes it twice.
- Skipped address sources: `addr:interpolation` ways and
  `associatedStreet`/`street` relations. Addresses on multipolygon buildings
  are included. Addresses with neither `addr:street`/`addr:place` nor a
  resolvable locality are dropped (6 156 in the moscow pack).
- Not indexed: bus/tram stops, natural features, `barrier=border_control`,
  road `ref` without a name.
- No typo tolerance and no transliteration ("lenina" finds nothing unless a
  `name:en` says so). Initials are matched as prefixes only.
- Locality assignment is heuristic where OSM has no settlement polygon
  (nearest place node), so the context line of an address can name a
  neighbouring village.
- A street crossing a locality border is two results (one per locality).
- No reverse geocoding and no "what is near here" query without text.
- The device needs SQLite with FTS5 (`remove_diacritics 2`: ≥ 3.27) and
  R-tree. Verified on the PC (3.54.1). `PlacesDatabase.open` probes both and
  throws `PlacesFormatException` otherwise; not verified on the phone.
