/// Camera warnings while driving a route: pure logic, no I/O.
///
/// Feed [CameraAlerter.update] with the current position along the route
/// (metres from its start), the speed and a monotonic time; it returns the
/// alerts that became due. Rules are described in `docs/places.md`.
library;

import 'cameras.dart';

/// Russian texts of camera alerts.
class CameraAlertTexts {
  const CameraAlertTexts._();

  static const String speedCamera = 'Камера контроля скорости';
  static const String averageSpeed = 'Контроль средней скорости';
  static const String trafficSignals = 'Камера на светофоре';
  static const String minDistance = 'Камера контроля дистанции';
  static const String busLane = 'Камера контроля полосы';
  static const String roadMarking = 'Камера контроля разметки';
  static const String otherCamera = 'Камера';
  static const String slowDown = 'Снизьте скорость';
  static const String zoneStart = 'Начало участка контроля средней скорости';
  static const String zoneEnd = 'Конец участка контроля средней скорости';
  static const String zoneAverageTooHigh = 'Средняя скорость выше ограничения';

  static String typeLabel(CameraType t) => switch (t) {
    CameraType.speed => speedCamera,
    CameraType.averageSpeed => averageSpeed,
    CameraType.trafficSignals => trafficSignals,
    CameraType.minDistance => minDistance,
    CameraType.busLane => busLane,
    CameraType.roadMarking => roadMarking,
    CameraType.other => otherCamera,
  };

  static String distance(double m) {
    if (m >= 1000) {
      final km = m / 1000;
      return '${km.toStringAsFixed(km >= 10 ? 0 : 1).replaceAll('.', ',')} км';
    }
    final step = m >= 100 ? 50 : 10;
    final r = (m / step).round() * step;
    return '${r < step ? step : r} м';
  }

  static String limit(int kmh) => 'ограничение $kmh км/ч';

  static String approaching(CameraType t, double distanceM, int? limitKmh) =>
      '${typeLabel(t)} через ${distance(distanceM)}'
      '${limitKmh == null ? '' : ', ${limit(limitKmh)}'}';

  static String speeding(int limitKmh) => '$slowDown: ${limit(limitKmh)}';

  static String zoneEntered(int? limitKmh) =>
      limitKmh == null ? zoneStart : '$zoneStart, ${limit(limitKmh)}';

  static String zoneSpeeding(int averageKmh, int limitKmh) =>
      '$zoneAverageTooHigh: $averageKmh км/ч, ${limit(limitKmh)}';

  static String zoneLeft(int? averageKmh) => averageKmh == null
      ? zoneEnd
      : '$zoneEnd. Средняя скорость $averageKmh км/ч';
}

enum CameraAlertKind {
  /// First warning, [CameraAlert.distanceM] before the camera.
  approaching,

  /// Still above the limit close to the camera.
  speeding,

  /// The camera is behind (lets the UI clear its indicator).
  passed,

  /// Entered an average-speed section.
  zoneEntered,

  /// Average speed inside the section went above the limit.
  zoneSpeeding,

  /// Left an average-speed section.
  zoneLeft,
}

class CameraAlert {
  const CameraAlert({
    required this.kind,
    required this.camera,
    required this.text,
    this.distanceM = 0,
    this.overLimit = false,
    this.averageKmh,
  });

  final CameraAlertKind kind;
  final RouteCamera camera;

  /// Ready-to-show (and to speak) Russian text.
  final String text;

  /// Distance to the camera (approaching/speeding) at the time of the alert.
  final double distanceM;

  /// Whether the current speed was above the limit (plus tolerance).
  final bool overLimit;

  /// Average speed in the section (zone alerts).
  final double? averageKmh;

  @override
  String toString() => 'CameraAlert(${kind.name}, $text)';
}

class CameraAlertConfig {
  const CameraAlertConfig({
    this.leadSeconds = 15,
    this.minWarnM = 300,
    this.maxWarnM = 1000,
    this.urgentSeconds = 6,
    this.minUrgentM = 150,
    this.toleranceKmh = 0,
    this.passedMarginM = 30,
  });

  /// The first warning comes this many seconds of travel before the camera…
  final double leadSeconds;

  /// …but not closer than [minWarnM] and not farther than [maxWarnM].
  final double minWarnM;
  final double maxWarnM;

  /// The "slow down" reminder distance: [urgentSeconds] of travel, at least
  /// [minUrgentM].
  final double urgentSeconds;
  final double minUrgentM;

  /// Speed above limit + tolerance counts as speeding.
  final double toleranceKmh;

  /// How far behind a camera must be to count as passed.
  final double passedMarginM;

  /// Distance before a camera at which the first warning is given.
  double warnDistanceM(double speedKmh) =>
      (speedKmh / 3.6 * leadSeconds).clamp(minWarnM, maxWarnM);

  double urgentDistanceM(double speedKmh) {
    final d = speedKmh / 3.6 * urgentSeconds;
    return d < minUrgentM ? minUrgentM : d;
  }
}

/// State of the average-speed section being driven.
class ActiveZone {
  ActiveZone._(this.camera, this._enteredAt);
  final RouteCamera camera;
  final Duration _enteredAt;
  double _averageKmh = 0;
  bool _speedingWarned = false;

  /// Average speed since the start of the section, km/h (0 until measurable).
  double get averageKmh => _averageKmh;
}

class _State {
  bool warned = false;
  bool urgent = false;
  bool done = false;
}

/// Decides when to warn about cameras on a route. One instance per route;
/// pass the previous instance's [warnedKeys] when the route is recalculated
/// so that a camera already announced is not announced again.
class CameraAlerter {
  CameraAlerter(
    List<RouteCamera> cameras, {
    this.config = const CameraAlertConfig(),
    Set<String>? alreadyWarned,
  }) : cameras = List.of(cameras)
         ..sort((a, b) => a.alongM.compareTo(b.alongM)) {
    for (final c in this.cameras) {
      final s = _states[c] = _State();
      if (alreadyWarned != null && alreadyWarned.contains(c.camera.key)) {
        s.warned = true;
        _warned.add(c.camera.key);
      }
    }
  }

  final List<RouteCamera> cameras;
  final CameraAlertConfig config;
  final Map<RouteCamera, _State> _states = {};
  final Set<String> _warned = {};
  ActiveZone? _zone;
  double _lastAlongM = 0;

  /// Keys ([SpeedCamera.key]) of cameras already announced.
  Set<String> get warnedKeys => Set.unmodifiable(_warned);

  /// Average-speed section currently being driven, if any.
  ActiveZone? get activeZone => _zone;

  /// The nearest camera still ahead of the last reported position.
  RouteCamera? get next {
    for (final c in cameras) {
      if (c.alongM >= _lastAlongM && !_states[c]!.done) return c;
    }
    return null;
  }

  /// Distance to [next], or null.
  double? get distanceToNextM {
    final n = next;
    return n == null ? null : n.alongM - _lastAlongM;
  }

  bool _isZone(RouteCamera c) =>
      c.camera.type == CameraType.averageSpeed && c.zoneEndAlongM != null;

  /// Reports progress; returns alerts that became due, in route order.
  ///
  /// [alongM] is the distance from the route start, [time] any monotonic
  /// clock (only differences are used, for the average speed in sections).
  List<CameraAlert> update({
    required double alongM,
    required double speedKmh,
    required Duration time,
  }) {
    _lastAlongM = alongM;
    final out = <CameraAlert>[];
    final warnM = config.warnDistanceM(speedKmh);
    final urgentM = config.urgentDistanceM(speedKmh);
    for (final c in cameras) {
      final s = _states[c]!;
      if (s.done) continue;
      final d = c.alongM - alongM;
      if (d > warnM) break; // sorted: the rest is farther away
      final limit = c.camera.maxSpeedKmh;
      final over = limit != null && speedKmh > limit + config.toleranceKmh;
      if (d >= 0) {
        if (!s.warned) {
          s.warned = true;
          _warned.add(c.camera.key);
          out.add(
            CameraAlert(
              kind: CameraAlertKind.approaching,
              camera: c,
              text: CameraAlertTexts.approaching(c.camera.type, d, limit),
              distanceM: d,
              overLimit: over,
            ),
          );
        } else if (!s.urgent && over && d <= urgentM && !_isZone(c)) {
          s.urgent = true;
          out.add(
            CameraAlert(
              kind: CameraAlertKind.speeding,
              camera: c,
              text: CameraAlertTexts.speeding(limit),
              distanceM: d,
              overLimit: true,
            ),
          );
        }
        continue;
      }
      // The camera is behind us.
      if (_isZone(c)) {
        if (_zone?.camera != c) {
          if (alongM < c.zoneEndAlongM!) {
            _warned.add(c.camera.key);
            s.warned = true;
            // Entry time is corrected for the distance already driven in.
            final v = speedKmh / 3.6;
            final late = v > 1
                ? Duration(milliseconds: (-d / v * 1000).round())
                : Duration.zero;
            _zone = ActiveZone._(c, time - late);
            out.add(
              CameraAlert(
                kind: CameraAlertKind.zoneEntered,
                camera: c,
                text: CameraAlertTexts.zoneEntered(limit),
              ),
            );
          } else {
            s.done = true; // jumped over the whole section
          }
        }
      } else if (-d > config.passedMarginM) {
        s.done = true;
        if (s.warned) {
          out.add(
            CameraAlert(
              kind: CameraAlertKind.passed,
              camera: c,
              text: '',
              distanceM: d,
            ),
          );
        }
      }
    }
    final zone = _zone;
    if (zone != null) {
      final c = zone.camera;
      final limit = c.camera.maxSpeedKmh;
      final elapsed = (time - zone._enteredAt).inMilliseconds / 1000.0;
      final driven = alongM - c.alongM;
      if (elapsed >= 3 && driven > 0) {
        zone._averageKmh = driven / elapsed * 3.6;
      }
      if (alongM >= c.zoneEndAlongM!) {
        _states[c]!.done = true;
        _zone = null;
        out.add(
          CameraAlert(
            kind: CameraAlertKind.zoneLeft,
            camera: c,
            text: CameraAlertTexts.zoneLeft(
              zone._averageKmh > 0 ? zone._averageKmh.round() : null,
            ),
            averageKmh: zone._averageKmh > 0 ? zone._averageKmh : null,
            overLimit:
                limit != null && zone._averageKmh > limit + config.toleranceKmh,
          ),
        );
      } else if (limit != null && zone._averageKmh > 0) {
        if (zone._averageKmh > limit + config.toleranceKmh) {
          if (!zone._speedingWarned) {
            zone._speedingWarned = true;
            out.add(
              CameraAlert(
                kind: CameraAlertKind.zoneSpeeding,
                camera: c,
                text: CameraAlertTexts.zoneSpeeding(
                  zone._averageKmh.round(),
                  limit,
                ),
                distanceM: c.zoneEndAlongM! - alongM,
                overLimit: true,
                averageKmh: zone._averageKmh,
              ),
            );
          }
        } else if (zone._averageKmh < limit + config.toleranceKmh - 3) {
          zone._speedingWarned = false; // re-arm after slowing down
        }
      }
    }
    return out;
  }
}
