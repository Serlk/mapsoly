import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../platform/android_bridge.dart';

/// A short warning signal: two beeps, played through the system's audio
/// player. On Linux that is PipeWire/PulseAudio/ALSA's command-line player,
/// whichever is installed; on Android the same samples go to the platform
/// side (AlertPlayer.kt); elsewhere, and in tests, it stays silent.
class AlertSound {
  static const _players = ['pw-play', 'paplay', 'aplay'];
  static File? _file;
  static String? _player;
  static bool _unavailable = false;

  /// Two beeps of [hz], as a 16-bit mono WAV file.
  @visibleForTesting
  static Uint8List wav({double hz = 1175, int rate = 22050}) {
    const beep = 0.14, gap = 0.09;
    final n = ((beep * 2 + gap) * rate).round();
    final data = ByteData(44 + n * 2);
    void tag(int at, String s) {
      for (var i = 0; i < 4; i++) {
        data.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    data.setUint32(4, 36 + n * 2, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little); // PCM
    data.setUint16(22, 1, Endian.little); // mono
    data.setUint32(24, rate, Endian.little);
    data.setUint32(28, rate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    data.setUint32(40, n * 2, Endian.little);
    for (var i = 0; i < n; i++) {
      final t = i / rate;
      final inBeep = t < beep || t >= beep + gap;
      // Position inside the current beep, for a click-free fade in and out.
      final local = t < beep ? t : t - beep - gap;
      final fade = math.min(1.0, math.min(local, beep - local) / 0.012);
      final v = inBeep
          ? math.sin(2 * math.pi * hz * t) * 0.6 * fade.clamp(0.0, 1.0)
          : 0.0;
      data.setInt16(44 + i * 2, (v * 32767).round(), Endian.little);
    }
    return data.buffer.asUint8List();
  }

  /// Plays the signal; never throws.
  static Future<void> play() async {
    if (_unavailable || Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }
    if (Platform.isAndroid) return _playAndroid();
    if (!Platform.isLinux) return;
    try {
      final file = _file ??= await _write();
      final known = _player;
      for (final player in known != null ? [known] : _players) {
        try {
          final process = await Process.start(player, [
            file.path,
          ], mode: ProcessStartMode.detached);
          _player = player;
          debugPrint('alert sound: $player (pid ${process.pid})');
          return;
        } on ProcessException {
          continue; // not installed: try the next one
        }
      }
      _unavailable = true;
      debugPrint('Alert sound: no audio player found (${_players.join(', ')})');
    } on Object catch (e) {
      debugPrint('Alert sound failed: $e');
    }
  }

  static const _rate = 22050;
  static Uint8List? _pcm;

  static Future<void> _playAndroid() async {
    try {
      // The samples without the 44-byte WAV header.
      final pcm = _pcm ??= Uint8List.sublistView(wav(rate: _rate), 44);
      final played = await androidChannel.invokeMethod<bool>('playPcm', {
        'pcm': pcm,
        'rate': _rate,
      });
      debugPrint('alert sound: android (played: $played)');
    } on Object catch (e) {
      debugPrint('Alert sound failed: $e');
    }
  }

  static Future<File> _write() async {
    final file = File('${Directory.systemTemp.path}/mapsoly-alert-$pid.wav');
    await file.writeAsBytes(wav(), flush: true);
    return file;
  }
}
