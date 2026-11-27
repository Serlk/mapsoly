import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'camera.dart';

/// Turns raw pointer input into camera changes.
///
/// One finger pans (with a fling on release), two fingers pan, pinch-zoom and
/// rotate, or - moved up or down together - tilt the view; a double tap zooms in, a double tap followed by a vertical drag
/// zooms continuously, the wheel zooms around the pointer, and holding still
/// reports a long press. Positions are logical pixels from the view's
/// top-left corner; time comes in through [advance] and the event calls, so
/// the whole machine can be driven by a test.
class MapGestures {
  MapGestures({
    required this.camera,
    required this.setCamera,
    required this.onLongPress,
    required this.origin,
    this.onAnimating,
  });

  /// The current camera and the way to change it. [animated] asks the host
  /// to ease into the new camera instead of jumping (discrete steps).
  final MapCamera Function() camera;
  final void Function(MapCamera camera, {bool animated}) setCamera;
  final void Function(Offset position) onLongPress;

  /// Where the camera target is drawn, from the view's top-left corner (the
  /// view centre, moved by the camera padding).
  final Offset Function() origin;

  /// Told when a fling starts or ends, so the host can run [advance] from a
  /// ticker only while needed.
  final void Function(bool animating)? onAnimating;

  static const touchSlop = 10.0;
  static const longPressTime = Duration(milliseconds: 500);
  static const doubleTapTime = Duration(milliseconds: 300);
  static const doubleTapSlop = 48.0;

  /// Two fingers have to turn this far before the map starts to rotate, so a
  /// plain pinch does not turn it.
  static const rotationThreshold = 12.0;

  /// Fling: speed decays as exp(-t / flingDecay).
  static const flingDecay = 0.30;
  static const minFlingSpeed = 120.0;

  /// Double-tap-drag: pixels of vertical movement per zoom level.
  static const dragPerZoomLevel = 110.0;

  final Map<int, Offset> _pointers = {};
  final List<(double, Offset)> _samples = []; // (seconds, position) of the drag
  Timer? _longPress;
  Offset? _downAt;
  bool _moved = false;
  bool _consumed = false; // long press fired, or a second finger was involved
  double? _lastTapUp; // seconds
  Offset? _lastTapAt;
  bool _secondTap = false;
  double _dragZoomStart = 0;
  // two-finger state
  Offset? _centroid;
  double _distance = 0, _angle = 0, _turned = 0;
  bool _rotating = false;
  // What the two fingers are doing, decided once they moved far enough.
  bool? _tilting;
  Offset _twoStart0 = Offset.zero, _twoStart1 = Offset.zero;
  Offset _flingVelocity = Offset.zero;

  bool get flinging => _flingVelocity != Offset.zero;

  Offset _fromCenter(Offset p) => p - origin();

  /// Two fingers moving up or down together tilt the view by this many
  /// degrees per pixel.
  static const pitchPerPixel = 0.35;

  void pointerDown(int id, Offset position, double seconds) {
    _stopFling();
    _pointers[id] = position;
    _longPress?.cancel();
    if (_pointers.length == 1) {
      _downAt = position;
      _moved = false;
      _consumed = false;
      _samples
        ..clear()
        ..add((seconds, position));
      final last = _lastTapUp, lastAt = _lastTapAt;
      _secondTap =
          last != null &&
          lastAt != null &&
          seconds - last <= doubleTapTime.inMilliseconds / 1000 &&
          (position - lastAt).distance <= doubleTapSlop;
      _dragZoomStart = camera().zoom;
      if (!_secondTap) {
        _longPress = Timer(longPressTime, () {
          if (_pointers.length == 1 && !_moved) {
            _consumed = true;
            onLongPress(position);
          }
        });
      }
    } else {
      _consumed = true;
      _secondTap = false;
      _startTwoFingers();
    }
  }

  void _startTwoFingers() {
    final p = _pointers.values.take(2).toList();
    _centroid = (p[0] + p[1]) / 2;
    final d = p[1] - p[0];
    _distance = d.distance;
    _angle = d.direction;
    _turned = 0;
    _rotating = false;
    _tilting = null;
    _twoStart0 = p[0];
    _twoStart1 = p[1];
  }

  void pointerMove(int id, Offset position, double seconds) {
    final previous = _pointers[id];
    if (previous == null) return;
    _pointers[id] = position;
    if (_pointers.length >= 2) {
      _twoFingerMove();
      return;
    }
    final down = _downAt;
    if (down == null) return;
    if (!_moved && (position - down).distance > touchSlop) {
      _moved = true;
      _longPress?.cancel();
    }
    if (!_moved) return;
    if (_secondTap) {
      // Double-tap-drag: down zooms in, up zooms out, around the tap.
      setCamera(
        camera().zoomedAround(
          _fromCenter(down),
          _dragZoomStart + (position.dy - down.dy) / dragPerZoomLevel,
        ),
        animated: false,
      );
      return;
    }
    final cam = camera().dragged(_fromCenter(previous), _fromCenter(position));
    if (_consumed) {
      // After a pinch one finger may stay down: it keeps panning.
      setCamera(cam, animated: false);
      return;
    }
    setCamera(cam, animated: false);
    _samples.add((seconds, position));
    while (_samples.length > 2 && seconds - _samples.first.$1 > 0.1) {
      _samples.removeAt(0);
    }
  }

  void _twoFingerMove() {
    final p = _pointers.values.take(2).toList();
    final centroid = (p[0] + p[1]) / 2;
    final d = p[1] - p[0];
    final distance = d.distance;
    var cam = camera();
    final old = _centroid;
    if (_tilting == null) {
      // Both fingers went the same way vertically, about equally far, and
      // hardly sideways: a tilt. Anything else: pan / pinch / rotate.
      final m0 = p[0] - _twoStart0, m1 = p[1] - _twoStart1;
      // Pointer events come one finger at a time: wait until both moved (or
      // one moved far while the other rests, which is no tilt).
      final least = math.min(m0.distance, m1.distance);
      final most = math.max(m0.distance, m1.distance);
      if (most > touchSlop && (least > 4 || most > 3 * touchSlop)) {
        _tilting =
            m0.dy * m1.dy > 0 &&
            m0.dy.abs() > 2 * m0.dx.abs() &&
            m1.dy.abs() > 2 * m1.dx.abs() &&
            (m0.dy - m1.dy).abs() < 0.5 * math.max(m0.dy.abs(), m1.dy.abs()) &&
            p[0].dy - p[1].dy < 150 &&
            p[1].dy - p[0].dy < 150;
      }
    }
    // Not clear yet what the fingers are doing: nothing moves.
    if (_tilting == null) return;
    if (_tilting == true) {
      if (old != null) {
        // Fingers up: tilt more (look towards the horizon).
        cam = cam.withPitch(cam.pitch - (centroid.dy - old.dy) * pitchPerPixel);
      }
      _centroid = centroid;
      _distance = distance;
      _angle = d.direction;
      setCamera(cam, animated: false);
      return;
    }
    if (old != null) cam = cam.dragged(_fromCenter(old), _fromCenter(centroid));
    final focal = _fromCenter(centroid);
    if (_distance > 1 && distance > 1) {
      cam = cam.zoomedAround(
        focal,
        cam.zoom + math.log(distance / _distance) / math.ln2,
      );
    }
    var turn = (d.direction - _angle) * 180 / math.pi;
    if (turn > 180) turn -= 360;
    if (turn < -180) turn += 360;
    if (!_rotating) {
      _turned += turn;
      if (_turned.abs() > rotationThreshold) _rotating = true;
    } else {
      cam = cam.rotatedAround(focal, turn);
    }
    _centroid = centroid;
    _distance = distance;
    _angle = d.direction;
    setCamera(cam, animated: false);
  }

  void pointerUp(int id, Offset position, double seconds) {
    if (_pointers.remove(id) == null) return;
    _longPress?.cancel();
    if (_pointers.length >= 2) {
      _startTwoFingers();
      return;
    }
    if (_pointers.length == 1) {
      // Back to one finger: keep panning from where it is, no tap, no fling.
      _centroid = null;
      _downAt = _pointers.values.first;
      _moved = true;
      return;
    }
    _centroid = null;
    final down = _downAt;
    _downAt = null;
    if (down == null) return;
    if (_secondTap) {
      _secondTap = false;
      _lastTapUp = null;
      if (!_moved) {
        final cam = camera();
        setCamera(
          cam.zoomedAround(_fromCenter(down), cam.zoom + 1),
          animated: true,
        );
      }
      return;
    }
    if (_consumed) return;
    if (!_moved) {
      _lastTapUp = seconds;
      _lastTapAt = position;
      return;
    }
    _lastTapUp = null;
    _startFling(seconds);
  }

  void pointerCancel(int id) {
    _pointers.remove(id);
    _longPress?.cancel();
    if (_pointers.isEmpty) {
      _downAt = null;
      _centroid = null;
      _secondTap = false;
    } else if (_pointers.length >= 2) {
      _startTwoFingers();
    }
  }

  /// Mouse wheel or touchpad scroll by [dy] pixels at [position].
  void scroll(Offset position, double dy) {
    if (dy == 0) return;
    _stopFling();
    final cam = camera();
    final step = (-dy / 100).clamp(-1.0, 1.0) * 0.5;
    setCamera(
      cam.zoomedAround(_fromCenter(position), cam.zoom + step),
      animated: true,
    );
  }

  void _startFling(double seconds) {
    if (_samples.length < 2) return;
    final (t0, p0) = _samples.first;
    final (t1, p1) = _samples.last;
    // The finger rested before lifting: no fling.
    if (t1 - t0 < 0.005 || seconds - t1 > 0.08) return;
    final v = (p1 - p0) / (t1 - t0);
    if (v.distance < minFlingSpeed) return;
    const maxSpeed = 6000.0;
    _flingVelocity = v.distance > maxSpeed ? v / v.distance * maxSpeed : v;
    onAnimating?.call(true);
  }

  void _stopFling() {
    if (_flingVelocity == Offset.zero) return;
    _flingVelocity = Offset.zero;
    onAnimating?.call(false);
  }

  /// Moves a running fling on by [dt] seconds.
  void advance(double dt) {
    if (_flingVelocity == Offset.zero || dt <= 0) return;
    final k = math.exp(-dt / flingDecay);
    // Distance covered while the speed decays from v to v*k.
    final travelled = _flingVelocity * (flingDecay * (1 - k));
    _flingVelocity = _flingVelocity * k;
    setCamera(camera().dragged(Offset.zero, travelled), animated: false);
    if (_flingVelocity.distance < 20) _stopFling();
  }

  void dispose() {
    _longPress?.cancel();
    _flingVelocity = Offset.zero;
    _pointers.clear();
  }
}
