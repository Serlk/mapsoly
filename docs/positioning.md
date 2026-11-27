# Positioning subsystem

Code: `lib/positioning/` (pure Dart except `engine_notifier.dart`).
Tests: `test/positioning/` (`flutter test test/positioning`).

Goal: know where the user is when GNSS is absent, jammed or spoofed, from
Wi-Fi, cell towers and (later) BLE, and use GNSS when it is healthy. No data
source needs a token, key or registration.

Statements below are marked **[verified]** (checked on the Titan 2, the PC or
a live endpoint on 2026-11-26/27) or **[assumption]**.

## 1. Structure

| File | Role |
|---|---|
| `models.dart` | `WifiObservation`, `CellObservation`, `BleObservation`, `GnssFix`, `PositionEstimate`, MAC/TA helpers |
| `geo.dart` | haversine, local tangent-plane projection, weighted median |
| `signal_model.dart` | log-distance path-loss model |
| `nmea.dart` | NMEA parser and epoch assembler |
| `sources/sources.dart` | `WifiScanner`, `CellSource`, `GnssSource`, `BleScanner` interfaces |
| `sources/dbus_decode.dart` | pure decoding of D-Bus dictionaries |
| `sources/linux_wifi.dart` | NetworkManager + wpa_supplicant |
| `sources/linux_cell.dart` | ModemManager |
| `sources/nmea_socket_gnss.dart` | NMEA over a unix socket |
| `sources/android_gnss.dart` | Android: `LocationManager` fixes, the location permission |
| `sources/android_radio.dart` | Android: Wi-Fi scan results, cells |
| `sources/android_stillness.dart` | Android: "the device lies still" from the accelerometer |
| `platform_engine.dart` | the engine with this platform's sources (Flutter; the rest is pure Dart) |
| `location_db.dart` | SQLite transmitter database |
| `importers.dart` | WiGLE CSV, generic / MLS CSV |
| `wardriving.dart` | collector: GNSS + observations -> database |
| `online/protobuf_lite.dart` | minimal protobuf wire codec |
| `online/apple_wps.dart` | Apple WPS client (unofficial API, isolated here) |
| `online/beacondb.dart` | beaconDB client |
| `online/resolver.dart` | caching resolver, region preload |
| `estimator.dart` | observations + database -> radio fix |
| `gnss_sanity.dart` | spoofing / jamming checks |
| `fusion.dart` | Kalman filter |
| `engine.dart` | `PositioningEngine` facade |
| `engine_notifier.dart` | `ChangeNotifier` adapter for Flutter |
| `tool/positioning_probe.dart` | command-line diagnostics (runs with bare `dart`) |

Data flow:

```
Wi-Fi scan ─┐                         ┌─> wardriving collector ─> DB
cells ──────┼─> RadioEstimator(DB) ───┤
            │        │ radio fix      └─> GnssSanityChecker <── GNSS (NMEA)
            │        v                          │ usable?
            │   FusionFilter <──────────────────┘ position + velocity
OBD speed ──┘        │
                     v 1 Hz
              PositionEstimate
```

## 2. Sources

### 2.1 Wi-Fi

Two backends on the system bus, chosen by `LinuxWifiScanner`:

* **wpa_supplicant** (`fi.w1.wpa_supplicant1`): BSS `BSSID` (ay), `Signal`
  (int16, dBm), `Frequency` (uint16, MHz), `Age` (uint32, s). Preferred
  because it has real dBm. `Signal >= 0` is treated as "no level".
* **NetworkManager**: `AccessPoint` `HwAddress`, `Frequency`, `Strength`
  (percent) and `LastSeen` (CLOCK_BOOTTIME seconds, -1 = never). The age is
  `/proc/uptime - LastSeen`; APs older than `maxWifiAge` (30 s) are dropped.

Scans are requested through NetworkManager (`RequestScan`), results are read
from wpa_supplicant when the bus lets us, otherwise from NetworkManager.
Access to wpa_supplicant is re-probed every 10 minutes, so a policy change on
the phone is picked up without an app update.

Facts:

* **[verified]** On the Titan 2 user `serlk` can call NM `GetDevices`,
  `GetAllAccessPoints`, read AP properties and call `RequestScan`. The Dart
  code ran on the phone as `serlk` and listed 13-17 APs; reading 17 APs takes
  about 90 ms. The same code works against NetworkManager on the Arch PC.
* **[verified]** A full scan takes about 8 s on the phone; `LastScan` only
  moved after that time.
* **[verified]** `serlk` cannot reach wpa_supplicant: the stock
  `/usr/share/dbus-1/system.d/wpa_supplicant.conf` allows only root
  (`AccessDenied`). Same on the PC. So today the app gets percent only.
* **[verified]** Percent to dBm: NetworkManager computes
  `quality = 100 - 100 * (-40 - dBm) / 60` clamped to [-100, -40] dBm, so
  `dBm = 0.6 * quality - 100`. Checked against `iw scan dump` on the phone
  (-90 dBm = 17 %, -78 = 37 %, -69 = 52 %). 100 % only means "-40 dBm or
  stronger", and the value is quantised to 0.6 dB.
* **[unverified]** `WpaSupplicantWifiScanner.requestScan(frequenciesMhz:)`
  (direct `Interface.Scan` with a `Channels` list for fast partial scans)
  could not be exercised as a non-root user.

SSIDs ending in `_nomap` (or containing `_optout`) are never stored, never
sent online and never used.

### 2.2 Cells

`ModemManagerCellSource` enumerates modems with
`ObjectManager.GetManagedObjects` and per modem tries:

1. `Modem.GetCellInfo()` -> `aa{sv}`; decoded by `decodeMmCellInfo`.
2. `Modem.Location.GetLocation()` -> `a{uv}`, key 1 =
   `"MCC,MNC,LAC,CI,TAC"` (LAC/CI/TAC upper-case hex).
3. the `Location` property (same content, only filled by ModemManager when
   `SignalsLocation` is true).

A method failing with Unsupported / AccessDenied / Unauthorized is retried
only every 5 minutes. The radio type for the `Location` path comes from
`Modem.AccessTechnologies` (LTE bit wins over NR: in NSA the registered cell
is the LTE anchor).

Facts:

* **[verified]** As root: `GetCellInfo` -> `Core.Unsupported`;
  `GetLocation` -> `{1: '250,20,0,1A2B3C4,1F40'}` and
  `{1: '250,02,0,2B3C4D5,2A2B'}` on the two modems; `AccessTechnologies` =
  16384 (LTE).
* **[verified]** As `serlk` the app gets **no cell data today**:
  `GetCellInfo` is rejected by the bus policy (the installed
  `org.freedesktop.ModemManager1.conf` has no entry for it), `GetLocation`
  is refused by polkit (action `org.freedesktop.ModemManager1.Location`; the
  stock rule wants `plugdev` *and* an active logind session, which the niri
  session is not), and the `Location` property is `{}` because
  `SignalsLocation` is false.
* **[assumption]** `GetCellInfo` key names and types follow the ModemManager
  1.20+ API: `cell-type` (u; 2 GSM, 3 UMTS, 4 TD-SCDMA, 5 LTE, 6 NR),
  `serving` (b), `operator-id` (s), `lac`/`tac`/`ci`/`physical-ci`/`psc`/
  `base-station-id` (s, hex without prefix), `arfcn`/`uarfcn`/`earfcn`/
  `nrarfcn` (u), `rsrp`/`rsrq`/`rscp`/`ecio` (d), `rx-level` (u),
  `timing-advance` (u). The decoder also accepts integers for the
  identifiers. Not testable until the modem plugin implements the method.

Rules: a missing key stays `null`; 0 is never used as "unknown". A cell
without full identity (typical neighbour: PCI + EARFCN + level) is kept in
the observation list but cannot be looked up or stored.

**Timing advance** is kept raw in `CellObservation.timingAdvance`;
`timingAdvanceMeters()` converts:

| Radio | Unit | Distance per unit |
|---|---|---|
| LTE | 16 Ts = 16 / (15000 * 2048) s round trip | c * 16 Ts / 2 = **78.12 m** |
| NR | 16 * 64 * Tc / 2^mu | 78.12 m at 15 kHz SCS; halves per numerology step, so 78.12 m is an upper bound **[assumption]** |
| GSM | one bit period, 48/13 us round trip | **553.46 m** |

GSM `rx-level` (RXLEV 0..63) is converted with `dBm = -110 + RXLEV`.

### 2.3 GNSS

`NmeaSocketGnssSource` connects to `/run/t2-gnss/nmea.sock` when it exists,
splits lines, feeds `NmeaParser` and reconnects with exponential backoff
(1 s to 15 s) after: missing socket, permission error, EOF, or 10 s of
silence.

* **[verified]** by tests against a local unix-socket server: waiting for the
  socket, sentence reassembly across packets, service restart, silent
  connection, garbage input.
* **[unverified]** against the real service: `t2-gnss` was not running and
  `/run/t2-gnss` did not exist.

`NmeaParser`:

* Sentences: GGA, RMC, VTG, GSA, GSV, GST; talkers GP, GL, GA, GB/BD, GQ, GI,
  GN. Checksums are mandatory.
* One `GnssFix` per epoch: emitted when RMC and GGA with the same UTC time
  have been seen, or (single-sentence receivers) when a newer time arrives.
* Speed from RMC (knots) or VTG (km/h preferred); course from RMC/VTG.
* Satellites from complete GSV cycles, per talker and NMEA 4.10 signal id;
  `used` from GSA, mapped by the GSA system id, else by talker, else by the
  legacy PRN ranges. An empty C/N0 stays `null`.
* Accuracy (NMEA has none): GST lat/lon sigmas if present, else
  `HDOP * 5 m` (typical single-frequency user range error), floored at 3 m,
  else 25 m. **[assumption]**: 5 m UERE.
* `GnssFix.receivedAt` is the local clock; receiver time is only informative,
  so a spoofed time cannot disturb the filter timing.

### 2.4 BLE

**Exists:** the model (`BleObservation`, with a `randomAddress` flag), the
database kind, the collector (`WardrivingCollector.addBle`: public
addresses only, range from the level with BLE taken as 10 dB weaker than
Wi-Fi, capped at 100 m), WiGLE/CSV import, the engine slot
(`PositioningEngine.ble`, counted in `bleVisible`) and the privacy-zone
checks for it.

**Missing:** a scanner on either platform (`BleScanner` is an interface
only), and any use of BLE in the estimator: `RadioEstimator` looks up Wi-Fi
and cells only.

**Why Android did not get one in the Wi-Fi/cell pass** (design note):

* Only advertisers with a stable identity may enter the database; a
  resolvable private address rotates every few minutes and would fill it
  with ghosts. Android tells an app the address *type* only since API 35
  (`BluetoothDevice.getAddressType()`); on Android 14 and older a scan
  result is a bare address, and its top bits distinguish the kinds of
  *random* address from each other, not random from public.
* So below API 35 the honest filter is by payload, not by address: iBeacon
  (Apple manufacturer data `02 15` + UUID/major/minor) and Eddystone-UID
  (service data `0xFEAA`, frame `0x00`) carry fixed ids. They need a key
  that is not a MAC (`ibeacon:<uuid>:<major>:<minor>`), while the collector
  and the importers normalise BLE ids as MACs today.
* It needs `BLUETOOTH_SCAN` at run time (Android 12+), declared *without*
  `neverForLocation`, plus location on; a low-power scan in windows of a
  few seconds, only while the app is on screen.
* The estimator needs a BLE term: the Wi-Fi centroid with a shorter range
  model and its own outlier radius (tens of metres, not 250 m).
* Neither test device could have verified it: the emulator hears no
  advertisers, and a home has few fixed beacons.

A scanner that stores every address it hears would look like it works and
slowly poison the database, so none was shipped.

### 2.5 Android

`platform_engine.dart` builds the engine with three sources that talk to
the app's own platform channels (Kotlin side: `LocationBridge.kt`,
`RadioBridge.kt`, `StillnessBridge.kt`). The platform side passes raw
values; cleaning them up is Dart and unit-tested.

**GNSS** (`AndroidGnssSource`): `LocationManager`, GPS provider, 1 Hz, with
the satellites of `GnssStatus`. Accuracy is Android's own 68 % radius.
`receivedAt` is when the fix was taken by the system's monotonic clock
(`elapsedRealtimeNanos`), expressed in system-clock time: still not the
receiver's time, and not the arrival time either, because fixes that queue
up behind a busy app and arrive together would look like a jump.

**Wi-Fi** (`AndroidWifiScanner`): `WifiManager.getScanResults()`, the
system's cache of the latest scan by anyone, each entry with its age
(`ScanResult.timestamp`).

* Real dBm, frequency (2.4 / 5 / 6 GHz), SSID only for `_nomap`.
* Dropped: the placeholder `02:00:00:00:00:00` (what an app without access
  is shown), the all-zero address, levels >= 0, entries older than
  `maxAge`; an access point listed twice counts once, at its strongest.
* `startScan()` at most every 31 s (Android 9+: four per two minutes for an
  app on screen), 60 s after a refusal. **[verified]** on the emulator: a
  new list every 33–35 s.
* `EstimatorConfig.maxWifiAge` is 45 s on Android (30 s elsewhere) and
  `FusionConfig.radioFresh` 60 s (35 s), or the Wi-Fi estimate and its
  label would drop out at the end of every scan cycle.

**Cells** (`AndroidCellSource`): `requestCellInfoUpdate` (Android 10+) or
the cached `getAllCellInfo`.

| Field | GSM | UMTS | LTE | NR |
|---|---|---|---|---|
| area | LAC | LAC | TAC | TAC (24 bit) |
| cell id | CID (16 bit) | UTRAN id (28 bit) | ECI (28 bit) | NCI (36 bit) |
| physical id | BSIC | PSC | PCI | PCI |
| signal | RSSI | RSCP | RSRP | SS-RSRP |
| timing advance | bit periods | — | 16 Ts steps | — |

* Android's "unavailable" (`Integer.MAX_VALUE`; `Long.MAX_VALUE` for the
  NCI) becomes null, as do reserved values (LAC/TAC 0 and 0xFFFE/0xFFFF,
  CID 0xFFFF, ECI 0xFFFFFFF, MCC 0). A neighbour known only by its physical
  id therefore has no database key and is counted as seen, never stored or
  looked up.
* CDMA and TD-SCDMA are skipped (no model). A cell reported once per SIM is
  kept once.
* No modem, no SIM registered, no permission: an empty list, no error.

**Stillness** (`StationaryFeeder`): scans half a minute apart leave the
filter without evidence of movement in between, and with its car-grade
process noise the accuracy circle of a tablet on a desk swung from tens of
metres to kilometres with every scan (**[verified]** on the emulator:
250 m – 2.7 km). While the standard deviation of the accelerometer's
magnitude over ~3 s stays below 0.04 m/s² (0.07 to leave the state) the
engine gets `addStationarySample()` once a second: a zero-velocity update
that does not count as a speed source. Not fed while a usable GNSS fix is
less than 3 s old. **[assumption]**: the thresholds separate a resting
device from a car; they were only tried on an emulator (constant readings)
and a tablet on a desk.

**Lifecycle**: when the app is hidden the engine is stopped (location
listener removed, no scan requests, no cell polls, accelerometer released)
and started again when it is shown.

**Permissions**: `ACCESS_FINE_LOCATION` at run time; `ACCESS_WIFI_STATE`,
`CHANGE_WIFI_STATE` at install. Not `NEARBY_WIFI_DEVICES`: scan results
need the location permission whatever else is held, and that permission is
meant for apps that do not locate by Wi-Fi.

## 3. Location database

SQLite through `package:sqlite3` (system `libsqlite3.so`, falling back to
`libsqlite3.so.0` so no `-dev` package is needed). WAL mode. **[verified]**
opens and writes on the phone (musl aarch64) and the PC.

```
transmitter(kind, id, lat, lon, accuracy, samples, wsum, scatter,
            best_signal, best_range, source, updated)  PRIMARY KEY(kind, id)
            INDEX(lat, lon)
sample(kind, id, lat, lon, fix_accuracy, signal, time)   -- optional raw points
unknown(kind, id, checked)                               -- negative cache
```

* `kind`: wifi / cell / ble. `id`: normalised BSSID (`aa:bb:..`), BLE
  address, or cell key `radio:mcc:mnc:area:cid` (e.g.
  `lte:250:20:8000:27440068`).
* `source` is ordered by trust: wardriving < wigle < csv < beacondb < apple.
  `upsertExternal` never overwrites a record from a more trusted source.
* A plain `(lat, lon)` index is used instead of an R-tree: the only spatial
  query is a bounding box for preload seeds.
* Negative cache: ids the online services did not know are not asked again
  for 14 days.

Running estimate (`addSamples`): weighted mean position plus weighted
scatter, updated incrementally (Welford), so no raw points are needed:

```
W' = W + w;  mean' = mean + (w / W') (x - mean)
S' = S + w (x - mean)·(x - mean') + w * fixAccuracy²
accuracy = max(floor, sqrt(S / W + bestRange²))
```

`bestRange` is the smallest estimated distance at which the transmitter was
ever heard. Floors: 10 m (Wi-Fi/BLE), 300 m (cells). A record from an
external source acts as a prior worth one sample and then becomes a
wardriving record. A Wi-Fi sample more than 400 m from the stored position
(cells: 50 km) restarts the estimate: the transmitter moved.

Importers:

* **WiGLE CSV** (`WigleWifi-1.x` app export; 1.4 and 1.6 column layouts,
  located by header name). Rows are observations and are merged per
  transmitter with the same weighting as live wardriving. Skipped: accuracy
  worse than 50 m, 0/0 coordinates, `_nomap`, classic BT. Cell rows use the
  key `<mcc><mnc>_<lac>_<cid>`; BLE rows are stored as BLE. Unquoted commas
  in SSIDs are handled.
* **Generic CSV** with a header: `bssid|mac|id|address`, `lat`, `lon|lng`,
  optional `accuracy|range|radius`, `samples`, `type|kind`; or the MLS /
  OpenCelliD cell export layout (`radio,mcc,net,area,cell,...,lon,lat,range`).
  One row = one transmitter.

## 4. Wardriving collector

Active only while `PositioningEngine.wardriving` is on **and** the GNSS
sanity check calls the current fix usable.

* Fixes are buffered for 60 s; an observation is placed at
  `now - observation.age` by interpolating between the surrounding fixes
  (at 20 m/s a 5 s old scan entry would otherwise be 100 m off).
* Requirements: fix accuracy <= 25 m, speed <= 45 m/s, observation age
  <= 12 s, a fix within 3 s of the observation time.
* A transmitter is re-sampled only after moving 5 m or when its signal
  improved by more than 3 dB, so standing still does not pile up samples.
* Weights: Wi-Fi/BLE `1 / (range² + fixAccuracy² + 1)` with `range` from the
  path-loss model; cells `10^((dBm + 110) / 20)` (1 at -110 dBm, 100 at
  -70 dBm), 1 without a level. A cell record is therefore the centroid of
  where the cell is *heard*, not the mast.
* On suspected spoofing the fix buffer is cleared, so a lying receiver cannot
  poison the database.

## 5. Online lookups (no keys)

Off by default (`PositioningConfig.onlineLookups`): every lookup tells a
third party which transmitters are around the user. No user or device
identifier is ever sent; SSIDs are never sent.

### 5.1 beaconDB

`POST https://api.beacondb.net/v1/geolocate`, Mozilla Location Service JSON,
`User-Agent: mapsoly/0.1`, `considerIp: false`, IP fallback disabled.

* Cells are resolved one per request, stripped of measurements, so the answer
  is that cell's own position and range and can be cached.
* A whole scan (>= 2 APs and/or cells) is sent only when nothing can be
  resolved locally; that answer is used as a one-off fix, it cannot be cached
  per transmitter.
* **[verified]** live: the phone's Tele2 serving cell
  (`lte:250:20:8000:27440068`) resolves with accuracy 968 m; the MTS cell
  (`lte:250:2:10795:45335765`) is unknown (HTTP 404).
* **[verified]** Wi-Fi coverage was empty in every place tried: the 17 APs
  around the phone and 10-AP clusters in six cities (5 in Germany, 1 in
  Russia) all returned 404. Do not count on beaconDB for Wi-Fi.
* Caveats: community project, no SLA, coverage depends on contributors, the
  terms ask for a meaningful User-Agent and moderate request rates. Data is
  CC0.

### 5.2 Apple WPS

`POST https://gs-loc.apple.com/clls/wloc`. **Unofficial and undocumented**:
reverse-engineered, the same request microG's Apple backend sends. Apple can
change or block it at any time and there are no terms that permit third-party
use; treat it as best-effort and keep it replaceable. Everything about the
wire format lives in `online/apple_wps.dart`; every failure is soft
(`ok == false`, no exception).

**[verified]** against the live endpoint:

* Request = header + protobuf. Header: int16 1; length-prefixed (int16)
  strings `en_US`, `com.apple.locationd`, `8.1.12B411`; int32 1; int32
  protobuf length (big endian). Protobuf: repeated field 2 `{1: bssid}`,
  field 3 = 0, field 4 = 0 (with neighbours) or 1 (only what was asked).
* Headers: `Content-Type: application/x-www-form-urlencoded`,
  `User-Agent: locationd/1753.17 CFNetwork/711.1.12 Darwin/14.0.0`.
* Response: 10-byte header (int16 1, int32 1, int32 length) + protobuf:
  repeated field 2 `{1: bssid, 2: {1: lat*1e8, 2: lon*1e8, 3: accuracy m,
  5: altitude, 6: vertical accuracy, ...}, 21: channel}`. BSSID octets come
  back without leading zeros (`0:21:5a:..`). Unknown BSSIDs have
  lat = lon = -180e8.
* Neighbours (up to 400) are returned only around the **first** requested
  BSSID; in central Berlin that is everything within about 200 m. 300 BSSIDs
  in one request were accepted.
* The Dart request is byte-identical to the one accepted live (golden test).
* Coverage: none of the 17 APs around the phone are known to Apple.

The protobuf codec (`protobuf_lite.dart`) is hand-written: varints (negative
int64 as 10-byte two's complement), length-delimited fields, skipping of
fixed32/64. No protobuf dependency.

### 5.3 Resolver and region preload

`OnlineResolver` serialises requests and spaces them by `minInterval`
(1 s). `resolveWifi` sends the unknown BSSIDs of a scan in one request with
the strongest first, so Apple's neighbour list covers the surroundings; all
answers are cached, explicit unknowns go to the negative cache; a failed
request caches nothing.

`preloadRegion(bounds, seeds)` snowballs through Apple WPS: the region is cut
into a 150 m grid, each request expands the known AP nearest to the centre
of a not-yet-expanded cell, new APs inside the region become candidates.
Bounds: one request per grid cell, `maxRequests` (default 300), `maxAps`
(default 100 000), 3 consecutive errors, cancellation callback.

* **[verified]** live: a 600 m x 600 m box in Berlin took 16 requests /
  16 s and stored 2165 APs (median stated accuracy 27 m). About 45 requests
  per km² in a dense city.
* Limits: seeds must be inside the region and known to Apple; areas not
  connected through chains of known APs (gaps over ~200 m, rivers, parks)
  are not reached.

## 6. Estimator

### 6.1 Wi-Fi: robust weighted centroid

1. Keep fresh (<= 30 s), known, not opted-out APs; strongest entry per BSSID.
2. Distance from the log-distance model
   `d = 10^((P0 - dBm) / (10 n))`, clamped to [1, 300] m, with

   | Constant | Value | Rationale |
   |---|---|---|
   | `P0` at 2.4 GHz | -40 dBm at 1 m | ~20 dBm EIRP, 40 dB free-space loss at 1 m, ~20 dB antenna/body/wall losses of a phone |
   | 5/6 GHz correction | `-20 log10(f / 2437)` | free-space difference, -6.7 dB at 5.2 GHz |
   | `n` | 2.7 | between free space (2) and dense indoor (3.5-4) |
   | unknown level | -85 dBm | weak but usable |

   The distances are crude; they are only used for weights and accuracy
   radii, never for trilateration.
3. Per-AP variance `σ² = d² + accuracy_db² + (20 m)²`, weight `1/σ²`.
4. Outlier rejection (>= 3 APs): drop APs further than
   `250 m + accuracy_db` from the weighted median of the AP positions.
   Rationale: consumer Wi-Fi is not heard beyond ~250 m, so such an AP moved
   or is a travelling hotspot. With exactly two APs more than 500 m apart
   there is no majority, so no fix is produced.
5. Position = weighted mean. Accuracy =
   `max(15 m, sqrt((1.5 / sqrt(Σw))² + spread² / N))`. The factor 1.5 is
   there because AP errors are correlated (same buildings, same wardriving
   tracks) and the formal inverse-variance value is optimistic.

Multi-BSSID routers count as several APs (accepted bias).

### 6.2 Cells

Per known cell an uncertainty `σ`:

* no TA: `max(accuracy_db, 300 m)` (the stored coverage radius);
* serving cell with TA: `sqrt(range² + (accuracy_db / 2)²) + unit / 2`,
  at least 150 m: measured distance to the mast, the unknown offset between
  mast and stored centroid, half a quantisation step;
* neighbour cells: `σ × 1.5`.

Position = `1/σ²`-weighted mean. Accuracy =
`max(150 m, 0.6 · min σ, sqrt(1 / Σ 1/σ²))`: cells often share a mast, so
the result is never claimed to be much better than the best single cell.

### 6.3 Choosing

Wi-Fi is used when available; if it lies further than
`3 · acc_cell + acc_wifi + 500 m` from the cell estimate it is discarded
(`wifiCellConflict`): the cell estimate is coarse but hard to fool.

## 7. GNSS sanity check

`GnssSanityChecker.check(fix, radio:)` per epoch. A fix is used for fusion
and wardriving only when `health.usable`.

| Anomaly | Rule | Constants |
|---|---|---|
| `radioMismatch` | distance(GNSS, radio fix) > `3 · (acc_gnss + acc_radio) + 100 m` for 2 consecutive epochs; radio fix at most 45 s old | a single mismatching epoch is already withheld (`unconfirmed`) |
| `uniformCn0` | >= 6 satellites with C/N0 and standard deviation < 1.5 dB-Hz for 3 epochs | real skies spread 4-10 dB-Hz with elevation and obstruction; one spoofing transmitter gives every PRN the same level |
| `positionJump` | step > `1.5 · v · dt + 3 · (acc1 + acc2) + 30 m` and implied speed > 15 m/s | `v` = larger reported speed |
| `timeJump` | (GNSS UTC - system clock) changes by > 5 s between epochs | a constant offset is tolerated |
| `weakSignal` | >= 4 satellites all below 22 dB-Hz, or fix lost with no usable signal | reported as `jammingSuspected`; cannot be told from being indoors |

Anomalies other than `weakSignal` make the verdict `suspect` and are held for
60 s after they were last seen. A radio fix that agrees with GNSS clears
`radioMismatch`; if it is Wi-Fi grade (<= 150 m) it also clears a held jump.
When the verdict turns `suspect` the engine restarts the filter from the
radio estimate alone and clears the wardriving buffer.

Limits **[assumption-laden, untested on real attacks]**: the thresholds come
from typical values, not from recorded spoofing. A slow drag-off without
radio coverage and with realistic per-satellite levels is not detected. With
a cell-only radio fix (accuracy ~1 km) only displacements of several km are
caught.

## 8. Fusion filter

Constant-velocity Kalman filter, state `[x, y, vx, vy]` on a local tangent
plane (re-centred beyond 30 km).

* Process noise: white acceleration, `σ_a = 2 m/s²` (normal car braking and
  cornering).
* Position update: accuracy radius `r` is taken as 68 %, per-axis
  `σ = r / √2`.
* GNSS velocity: speed + course as a 2-D velocity measurement
  (`σ = 0.5 m/s`); speed below 0.3 m/s -> zero-velocity update.
* External speed (OBD): magnitude-only EKF update `h(x) = |v|`
  (`σ = 0.7 m/s`), heading from the state (or the last known course); zero
  speed -> zero-velocity update.
* Stillness (`addStationary`, Android): a zero-velocity update
  (`σ = 0.2 m/s`) that is not a speed source for the label below.
* Radio fixes pass a 5σ Mahalanobis gate; after 3 consecutive rejections the
  filter restarts at the new position. A healthy GNSS fix that fails the gate
  restarts it immediately.
* The engine feeds an unchanged radio fix again only after 15 s: polls are
  more frequent than real scans.

Output (`estimateAt`, 1 Hz, does not modify the filter):

* Position is extrapolated only when the along-track velocity sigma is
  <= 3 m/s, and for at most 30 s; otherwise it is held. The covariance always
  grows.
* Accuracy = `sqrt(Pxx + Pyy)`. While only radio fixes arrive it is floored
  at half the accuracy of the last radio fix: successive fixes share the same
  transmitters, averaging them does not improve the truth.
* Speed is reported only while confident and at most 5 s after the last
  measurement; course additionally needs speed > 1 m/s and a cross-track
  sigma below half the speed. Otherwise they are `null`, not guessed. With
  Wi-Fi fixes only (every 10-15 s) no speed is reported.
* Source: `gnss` (GNSS within 3 s, nothing else), `fused` (GNSS plus radio
  or speed input; radio plus speed input), `wifi` / `cell` (radio within
  35 s), `deadReckoning` otherwise.

## 9. Engine

`PositioningEngine` polls Wi-Fi and cells every 5 s, listens to GNSS, emits
`PositionEstimate` at 1 Hz and a `PositioningStatus` on every change. See the
class documentation for the API. `PositioningNotifier` wraps it as a
`ChangeNotifier`.

All database access is synchronous on the calling isolate (lookups of one
scan are well under a millisecond; imports yield to the event loop every few
thousand rows).

## 10. State on the Titan 2 (2026-11-27)

With today's permissions the app cannot produce a position on the phone:

| Input | State |
|---|---|
| Wi-Fi scan | works (NetworkManager, percent only, new data every ~8-15 s) |
| Wi-Fi positions | the APs around the test location are unknown to Apple and beaconDB; they must be wardriven or imported |
| Cells | no data for `serlk` (section 2.2) |
| Cell positions | 1 of the 2 serving cells known to beaconDB (±968 m) |
| GNSS | service not running, socket absent |
| BLE | not implemented |

The true position of the phone could not be established independently, so
no real-world position error has been measured. The only real fix obtained
is the beaconDB answer for the Tele2 serving cell (±968 m).
