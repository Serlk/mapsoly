# User data: places, routes, GPX, privacy zones, exports

Pure Dart logic in `lib/user/` (no UI), tests in `test/user/`. Nothing here
needs an account, a key or a server.

| File | What |
| --- | --- |
| `json_store.dart` | shared base: tolerant load, atomic write, ids |
| `user_places.dart` | home / work / favourites |
| `saved_routes.dart` | routes the user kept |
| `gpx.dart` | GPX 1.1 export and GPX 1.0/1.1 import, own XML tokenizer |
| `privacy_zones.dart` | the zones and their geometry |
| `privacy_guard.dart` | enforcement glue: engine, trip log, purge |
| `data_export.dart` | wardriving CSV export, trip log listing / export / delete |

## Wiring (what the app has to do)

```dart
final userDir = Directory('${supportDir.path}/user');
final places = UserPlaces.load(userDir);
final routes = SavedRoutes.load(userDir);
final zones  = PrivacyZones.load(userDir);
final guard  = PrivacyGuard.load(userDir, zones);

// Positioning: BEFORE engine.start(), every time an engine is created.
guard.attach(engine);

// OBD trip log: wrap the position callback.
ObdSession(connect, options: ObdOptions(
  logDirectory: tripsDir,
  position: guard.enginePosition(engine),   // or guard.tripLogPosition(fn)
));

// Anything else that sends a position out (online search hint):
near: guard.shareable(LatLng(fix.lat, fix.lon), accuracyM: fix.accuracyM),
```

If `zones.unconfirmed` is true after loading, show the zone list with
`zones.loadError` and call `zones.confirmZones()` once the user has checked
it (see "Fails closed" below). `engine.status.privateArea` tells the UI that
collection and online lookups are paused right now.

## Stores

All three stores are `ChangeNotifier`s created with `X.load(Directory)`
(never throws) or `X.inMemory()`.

- Missing file: empty store. Unreadable file: empty store, `damaged`,
  `loadError` (Russian), the file copied to `<name>.bak`. Entries that cannot
  be used are skipped one by one (`skippedOnLoad`, `.bak` copy as well).
- Every change writes `<name>.tmp` (flushed) and renames it over the file.
  A failed write sets `saveError`; the change stays in memory.
- Ids come from `newUserId()`: time + per-process counter + random bits.

### Formats

`places.json`:
`{"version":1,"places":[{"id","name","kind":"home|work|favorite","point":[lat,lon],"address"?}]}`

`routes.json`:
`{"version":1,"routes":[{"id","name","costing":"auto|pedestrian|bicycle","created":"<ISO 8601 UTC>","points":[{"point":[lat,lon],"label"?}],"lengthMeters"?,"geometry"?:"<polyline6>"}]}`

`privacy_zones.json`:
`{"version":1,"zones":[{"id","name","center":[lat,lon],"radiusM"}],"unconfirmed"?:true}`

`privacy_state.json` (the guard): `{"inside":true|false}`. No coordinates.

### Places

`UserPlaces`: `places` (home, work, then favourites by name), `home`, `work`,
`favorites`, `byId`, `save` (same id = update; a new home/work replaces the
old one), `addAll` (import: a home/work from the file becomes a favourite if
one exists already), `remove`, `rename`. Names are trimmed; an empty name
becomes "Дом" / "Работа" / "Место".

### Routes

`SavedRoutes`: `routes` (newest first), `byId`, `save`, `addAll`, `remove`,
`rename`. `SavedRoute` needs at least two points (throws `ArgumentError`).
`created` is always UTC. `geometry` is rounded to 1e-6 degrees in the
constructor (the precision of Valhalla's own shapes), which is what makes it
compact on disk (polyline6) and equal after any round trip.

## GPX

Export: `exportGpx({places, routes, name, time})` / `writeGpxFile(file, …)`.
One file can carry any number of places and routes.

```xml
<gpx version="1.1" creator="Mapsoly" xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:mapsoly="urn:mapsoly:gpx:1">
  <metadata><name/><time/></metadata>
  <wpt lat lon><name/><desc>address</desc>
    <extensions><mapsoly:id/><mapsoly:kind/></extensions></wpt>
  <rte><name/>
    <extensions><mapsoly:id/><mapsoly:costing/><mapsoly:created/><mapsoly:length/></extensions>
    <rtept lat lon><name>label</name></rtept>…</rte>
  <trk><name/><extensions><mapsoly:route>id of its rte</mapsoly:route></extensions>
    <trkseg><trkpt lat lon/>…</trkseg></trk>
</gpx>
```

Import: `importGpx(String)`, `importGpxBytes(Uint8List)`,
`importGpxFile(File)` (runs in an isolate). None of them throws; the result
has `places`, `routes`, `skipped` (reason in Russian + count) and `error`
(file refused as a whole).

- `<wpt>` → favourite (home/work only from our own extension).
- `<rte>` → route. `<trk>` linked by `mapsoly:route` → that route's geometry.
  A foreign `<trk>` → geometry of a foreign `<rte>` in the same file that has
  none and whose ends are within 300 m of the track's ends; otherwise a route
  of its own (first point → last point, track as geometry, length measured).
- Our objects keep their ids, so re-importing an export updates instead of
  duplicating. Foreign objects get new ids.
- Elements are matched by local name (prefixes and GPX 1.0 work); our
  extension elements are matched by namespace URI, not by prefix.
- Coordinates must be plain decimals. `55,75`, `NaN`, empty: the point is
  skipped and counted.
- Limits (`GpxLimits`): 20 MB, 200 000 points in total, nesting depth 64,
  names cut at 500 characters.
- Safety: the tokenizer has no notion of DTDs. A file with `<!DOCTYPE` is
  refused, so no entity can be declared; only the five predefined entities
  and character references are decoded, anything else stays literal text.
  Nothing is ever fetched.
- Encodings: UTF-8 (default), Latin-1 when declared. UTF-16 and others are
  refused with a message.

Round trip: export → import gives equal objects (tested, including names
with `<`, `&`, quotes, emoji, CR/LF/tab, `]]>`). Two documented exceptions:
leading/trailing whitespace of names is not kept, and characters XML 1.0
cannot carry (control characters, lone surrogates) are dropped on export.

GPX export is **not** filtered by privacy zones: places and routes are what
the user chose to save and share.

## Privacy zones

`PrivacyZone {id, name, center, radiusM}`; `PrivacyZones`: `zones`, `add`,
`update`, `remove`, `contains(LatLng)`, `intersects(LatLng, radiusM)`,
`zoneAt`, `unconfirmed`, `confirmZones()`. Radius is clamped to 50 m..50 km;
`PrivacyZone.defaultRadiusM` is 300.

`PrivacyZone.around(point, name:, radiusM:)` builds a zone whose centre is
shifted randomly by up to 40 % of the radius. Use it for "around my home":
tracks end at the zone edge, and with the home exactly in the centre three
such ends are enough to compute it.

**Fails closed.** If `privacy_zones.json` exists but cannot be read (or a
zone in it cannot), the zones are unknown, so `contains` / `intersects`
answer true everywhere until `confirmZones()`. The flag is written to the
file, so editing the list does not end the state by accident. A missing file
means "no zones".

### Enforcement

| Rule | Where | How |
| --- | --- | --- |
| a. Wardriving | `WardrivingCollector.privacyFilter` (set through `PositioningEngine.privacyFilter`) | each observation is checked against the GNSS position it was taken at (interpolated between fixes), with the fix accuracy as radius; private → dropped before `LocationDb.addSamples`, so neither the transmitter table nor the raw `sample` table sees it |
| b. Online lookups | `PositioningEngine._maybeResolveOnline` | no Apple / beaconDB request while the fused estimate, the latest radio estimate or the latest GNSS fix has an accuracy circle touching a zone; re-checked between the requests of a round. Local-database positioning is untouched |
| b'. Region preload | `PositioningEngine.preloadRegion`, `OnlineResolver.privacyFilter` | from a private area the current scan is not used as seeds; a transmitter stored at a private position is never a seed |
| c. Trip log | `PrivacyGuard.tripLogPosition` / `enginePosition` wrapped around `ObdOptions.position` | returns null inside a zone, `ObdSession` then writes empty `lat,lon` and the usual vehicle columns. `lib/obd` is unchanged |
| d. Exports | `exportWardriving`, `exportTripLogs` | filtered again by stored position / by the coordinates of each row, whatever was filtered at recording time |

The hook type is
`typedef PrivacyFilter = bool Function(double lat, double lon, double radiusM)`
(`lib/positioning/models.dart`): true = the circle touches a private area.
`lib/positioning` does not import `lib/user`.

`PrivacyGuard` also keeps one boolean across restarts: whether the last
estimate was inside a zone. If so, the next start sets
`engine.assumePrivateUntilLocated`, and no lookup is sent until a position is
known. `guard.releaseHold()` lets the user override ("I am not at home").

A zone change applies to new data at once (the filter reads the zones at
call time). Stored data is never deleted silently:
`purgeWardrivingInside(db, zones, {dryRun, allSources})` returns the number
of rows (transmitter records learnt by wardriving + raw samples) it would
remove / removed; `purgeDetails` gives the two counts apart.

### Not covered

Paths by which something collected in or about a zone can still be stored or
leave the device:

1. **Cold start inside a zone with nothing known.** The engine has no
   position, the previous session did not end in a zone (the app was closed
   elsewhere and opened at home), no visible transmitter is in the local
   database and there is no GNSS fix: with online lookups on, the scan is sent
   out, because that is how the position is found. Covered only when the last
   session ended in the zone (the hold above) or as soon as any estimate
   exists.
2. **Radio range.** A transmitter inside the zone heard from outside it is
   recorded at the place where the car was (outside), and is included in
   lookups made there. A zone has to be larger than Wi-Fi range for this not
   to matter; hence the 300 m default.
3. **Zone edge.** Trip logs and wardriving stop at the edge, so the edge
   itself is visible in the data. Use `PrivacyZone.around`.
4. **Trip log rows in a zone** keep time, speed and odometer. The distance
   driven inside the zone can be read from them.
5. **Trip log export** checks the logged point only; the CSV has no accuracy
   column.
6. **Answers of the online services** about a zone (Apple returns the
   neighbours of what was asked, up to ~300 m away) are stored in the local
   database as `apple` records. They are received, not collected, are needed
   for positioning inside the zone and are never exported with `onlyOwn`.
7. **Explicit region preload** over an area that contains a zone still asks
   about transmitters around it.
8. **Code outside `lib/user` / `lib/positioning`** (not changed here):
   - the online search fallback (Photon) gets the current position as its
     "near" hint (`map_screen.dart`, `_searchNear`); wrap it with
     `guard.shareable`;
   - `settings.json` stores the last map centre;
   - online map and traffic tiles are requested for whatever the map shows.
9. **Stale position.** If the last estimate lies in a zone and nothing
   updates it (no GNSS, nothing known locally at the new place), lookups stay
   blocked: safe, but positioning cannot recover online until GNSS or a known
   transmitter appears.
10. **GPX export** is not zone-filtered (see above).

## Exports

`exportWardriving(db, zones, out, {onlyOwn = true})` writes a
`WigleWifi-1.6` CSV with **one row per transmitter** (estimated position,
`AccuracyMeters` = position uncertainty, `RSSI` = strongest signal,
`FirstSeen` = last observation, UTC). The first line carries
`appRelease=mapsoly`; `importWigleCsv` recognises it and reads the rows back
as records (no 50 m limit, no range model), so cells survive the round trip.
Result: `exported`, `wifi`, `cells`, `ble`, `withheldByZones`, `notOwn`,
`file` (null and no file when nothing was exported).

"Own" (`TransmitterRecord.isOwn`): source `wardriving` and not started from
an Apple / beaconDB record. The database (schema 2) stores this in
`transmitter.seed_source`. Databases written by schema 1 are migrated on
open (`ALTER TABLE … ADD COLUMN`); for their existing wardriving rows the
seed is unknown and they count as own.

Trip logs: `listTripLogs(dir)` → `TripLogInfo {file, name, start, duration,
distanceKm, sizeBytes}` (newest first; reads only both ends of each file),
`exportTripLogs(files, zones, outDir)` → `TripExportResult {files, rows,
rowsBlanked, failed}`, `deleteTripLog(file)`. A row whose coordinates are in
a zone or not numbers is written without them; a row with a different number
of columns than the header is dropped; a file without `lat`/`lon` columns is
refused.

## Verified and assumed

Verified by tests: everything in the enforcement table (against the real
engine, collector, resolver, database and `ObdSession` with fake sources),
the GPX round trip, well-formedness of exported GPX with `xmllint`, the
wardriving CSV round trip through `importWigleCsv`, the schema migration.

Assumed, not verified:
- The exported GPX follows the element order of the GPX 1.1 schema; it was
  not validated against the XSD, and not opened in another app.
- The wardriving CSV has WiGLE's column layout; it was not uploaded to WiGLE
  or read by another tool. Empty SSID / channel columns may not be accepted
  there.
- An app build with schema 1 can still open a schema 2 database (it names
  its columns explicitly); not tested.
