import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PlayerSnapshot {
  const PlayerSnapshot({
    required this.status,
    required this.positionMs,
    required this.durationMs,
    required this.bufferedMs,
    required this.isPlaying,
    required this.playWhenReady,
    required this.speed,
    required this.volume,
  });

  final String status;
  final int positionMs;
  final int durationMs;
  final int bufferedMs;
  final bool isPlaying;
  final bool playWhenReady;
  final double speed;
  final double volume;

  factory PlayerSnapshot.fromMap(Map<Object?, Object?> map) {
    int asInt(Object? value) => (value as num?)?.toInt() ?? 0;
    double asDouble(Object? value) => (value as num?)?.toDouble() ?? 1.0;

    return PlayerSnapshot(
      status: map['status']?.toString() ?? 'idle',
      positionMs: asInt(map['positionMs']),
      durationMs: asInt(map['durationMs']),
      bufferedMs: asInt(map['bufferedMs']),
      isPlaying: map['isPlaying'] == true,
      playWhenReady: map['playWhenReady'] == true,
      speed: asDouble(map['speed']),
      volume: asDouble(map['volume']),
    );
  }
}

class PlayerEvent {
  const PlayerEvent.state(this.snapshot) : errorMessage = null;

  const PlayerEvent.error(this.errorMessage) : snapshot = null;

  const PlayerEvent.unknown()
      : snapshot = null,
        errorMessage = null;

  final PlayerSnapshot? snapshot;
  final String? errorMessage;
}

class DemoPlayerController {
  static const _channel = MethodChannel('demo/player_commands');
  static const _eventChannel = EventChannel('demo/player_events');

  static final Stream<PlayerEvent> _events = _eventChannel
      .receiveBroadcastStream()
      .map<PlayerEvent>((raw) {
    if (raw is! Map) return const PlayerEvent.unknown();

    final map = raw.cast<Object?, Object?>();
    if (map['type'] == 'error') {
      return PlayerEvent.error(
        map['message']?.toString() ?? '播放失败',
      );
    }
    return PlayerEvent.state(PlayerSnapshot.fromMap(map));
  });

  Stream<PlayerEvent> get events => _events;

  Future<PlayerSnapshot?> getState() async {
    try {
      final map = await _channel.invokeMethod<Map<Object?, Object?>>('getState');
      if (map == null) return null;
      return PlayerSnapshot.fromMap(map);
    } on PlatformException catch (e) {
      debugPrint('getState failed: ${e.message}');
      return null;
    }
  }

  Future<void> play() => _invoke('play');

  Future<void> pause() => _invoke('pause');

  Future<void> seekTo(int positionMs) =>
      _invoke('seekTo', {'positionMs': positionMs});

  Future<void> setSpeed(double speed) =>
      _invoke('setSpeed', {'speed': speed});

  Future<void> setVolume(double volume) =>
      _invoke('setVolume', {'volume': volume});

  Future<void> _invoke(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException catch (e) {
      debugPrint('$method failed: ${e.message}');
    }
  }
}
