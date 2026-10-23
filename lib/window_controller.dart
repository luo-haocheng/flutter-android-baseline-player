import 'package:flutter/services.dart';

class WindowController {
  static const _channel = MethodChannel('demo/window_controls');

  Future<double?> getBrightness() async {
    try {
      final value = await _channel.invokeMethod<num>('getBrightness');
      return value?.toDouble();
    } on PlatformException {
      return null;
    }
  }

  Future<bool> isEmulator() async {
    try {
      return await _channel.invokeMethod<bool>('isEmulator') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> setBrightness(double value) async {
    try {
      await _channel.invokeMethod<void>(
        'setBrightness',
        {'value': value.clamp(0.01, 1.0)},
      );
    } on PlatformException {
      // 亮度调整失败时不影响播放。
    }
  }
}
