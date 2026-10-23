import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'demo_player_controller.dart';
import 'native_video_view.dart';
import 'window_controller.dart';

void main() => runApp(const DemoApp());

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: PlayerPage(),
    );
  }
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

enum _AdjustTarget { none, brightness, volume }

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  final DemoPlayerController _controller = DemoPlayerController();
  final WindowController _window = WindowController();

  bool _playWhenReady = true;
  double _speed = 1.0;
  int _positionMs = 0;
  int _durationMs = 0;
  int _bufferedMs = 0;
  double _volume = 1.0;
  String _status = 'ready';
  String? _error;
  StreamSubscription<PlayerEvent>? _eventSub;

  bool _controlsVisible = true;
  bool _isLandscape = false;

  double _brightness = 0.5;
  bool _isEmulator = false;
  _AdjustTarget _adjusting = _AdjustTarget.none;
  double _adjustValue = 0;
  double _adjustStartValue = 0;
  double _adjustDelta = 0;
  String? _adjustText;
  IconData? _adjustIcon;
  Timer? _adjustTimer;
  DateTime _lastAdjustSend = DateTime.fromMillisecondsSinceEpoch(0);

  bool _dragging = false;
  bool _sliderDragging = false;
  double _sliderValue = 0;
  bool _longPressing = false;
  double _dragDx = 0;
  int _seekStartMs = 0;
  int _seekTargetMs = 0;
  double _speedBeforeLongPress = 1.0;

  IconData? _centerIcon;
  Timer? _centerTimer;

  String? _hudText;
  IconData? _hudIcon;
  Timer? _hudTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _eventSub = _controller.events.listen(_onPlayerEvent);
    _refreshState();
    _loadWindowInfo();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _eventSub?.cancel();
    _centerTimer?.cancel();
    _hudTimer?.cancel();
    _adjustTimer?.cancel();
    unawaited(SystemChrome.setPreferredOrientations(const []));
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge),
    );
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshState();
    }
  }

  Future<void> _refreshState() async {
    final snapshot = await _controller.getState();
    if (!mounted || snapshot == null) return;

    setState(() {
      _status = snapshot.status;
      _playWhenReady = snapshot.playWhenReady;
      _speed = snapshot.speed;
      _bufferedMs = snapshot.bufferedMs;
      if (_adjusting != _AdjustTarget.volume) {
        _volume = snapshot.volume;
      }
      if (!_dragging && !_sliderDragging && !_longPressing) {
        _positionMs = snapshot.positionMs;
        _durationMs = snapshot.durationMs;
      }
    });
  }

  void _onPlayerEvent(PlayerEvent event) {
    if (!mounted) return;

    final message = event.errorMessage;
    if (message != null) {
      setState(() {
        _error = message;
        _status = 'idle';
        _playWhenReady = false;
      });
      return;
    }

    final snapshot = event.snapshot;
    if (snapshot == null) return;

    setState(() {
      _status = snapshot.status;
      _playWhenReady = snapshot.playWhenReady;
      _speed = snapshot.speed;
      _bufferedMs = snapshot.bufferedMs;
      if (_adjusting != _AdjustTarget.volume) {
        _volume = snapshot.volume;
      }
      if (!_dragging && !_sliderDragging && !_longPressing) {
        _positionMs = snapshot.positionMs;
        _durationMs = snapshot.durationMs;
      }
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
  }

  Future<void> _toggleOrientation() async {
    final next = !_isLandscape;
    setState(() => _isLandscape = next);

    if (next) {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  void _onVerticalDragStart(DragStartDetails details) {
    if (_longPressing || _dragging || _sliderDragging) return;

    final width = MediaQuery.sizeOf(context).width;
    final isLeft = details.localPosition.dx < width / 2;

    _adjustTimer?.cancel();
    setState(() {
      _adjusting =
          isLeft ? _AdjustTarget.brightness : _AdjustTarget.volume;
      _adjustStartValue = isLeft ? _brightness : _volume;
      _adjustValue = _adjustStartValue;
      _adjustDelta = 0;
      _adjustText = isLeft ? '亮度' : '音量';
      _adjustIcon = isLeft
          ? Icons.brightness_6
          : (_volume <= 0 ? Icons.volume_off : Icons.volume_up);
    });
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (_adjusting == _AdjustTarget.none) return;

    final height = MediaQuery.sizeOf(context).height;
    _adjustDelta -= details.delta.dy;
    final value = (_adjustStartValue + _adjustDelta / (height * 0.65))
        .clamp(0.0, 1.0)
        .toDouble();

    setState(() {
      _adjustValue = value;
      if (_adjusting == _AdjustTarget.brightness) {
        _brightness = value;
        _adjustIcon = value < 0.4 ? Icons.brightness_low : Icons.brightness_6;
      } else {
        _volume = value;
        _adjustIcon = value <= 0
            ? Icons.volume_off
            : (value < 0.5 ? Icons.volume_down : Icons.volume_up);
      }
    });

    final now = DateTime.now();
    if (now.difference(_lastAdjustSend).inMilliseconds >= 33) {
      _lastAdjustSend = now;
      if (_adjusting == _AdjustTarget.brightness) {
        _window.setBrightness(value);
      } else {
        _controller.setVolume(value);
      }
    }
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (_adjusting == _AdjustTarget.none) return;
    setState(() => _adjusting = _AdjustTarget.none);
    _hideAdjustmentLater();
  }

  void _onVerticalDragCancel() {
    if (_adjusting == _AdjustTarget.none) return;
    setState(() => _adjusting = _AdjustTarget.none);
    _hideAdjustmentLater();
  }

  void _hideAdjustmentLater() {
    _adjustTimer?.cancel();
    _adjustTimer = Timer(const Duration(milliseconds: 650), () {
      if (!mounted) return;
      setState(() {
        _adjustText = null;
        _adjustIcon = null;
      });
    });
  }

  Future<void> _loadWindowInfo() async {
    final brightness = await _window.getBrightness();
    final emulator = await _window.isEmulator();
    if (!mounted) return;
    setState(() {
      if (brightness != null) {
        _brightness = brightness;
      }
      _isEmulator = emulator;
    });
  }

  Future<void> _togglePlay() async {
    if (_longPressing) return;

    final wasEnded = _status == 'ended';
    final shouldPlay = wasEnded || !_playWhenReady;

    if (!shouldPlay) {
      setState(() {
        _playWhenReady = false;
      });
      _flashCenterIcon(Icons.pause);
      await _controller.pause();
      return;
    }

    setState(() {
      _playWhenReady = true;
      _error = null;
      if (wasEnded) {
        _positionMs = 0;
        _status = 'ready';
      }
    });
    _flashCenterIcon(Icons.play_arrow);
    await _controller.play();
  }

  void _flashCenterIcon(IconData icon) {
    _centerTimer?.cancel();
    setState(() => _centerIcon = icon);
    _centerTimer = Timer(const Duration(milliseconds: 550), () {
      if (mounted) setState(() => _centerIcon = null);
    });
  }

  void _showHud(
    String text,
    IconData icon, {
    Duration? hideAfter = const Duration(milliseconds: 700),
  }) {
    _hudTimer?.cancel();
    setState(() {
      _hudText = text;
      _hudIcon = icon;
    });
    if (hideAfter != null) {
      _hudTimer = Timer(hideAfter, _clearHud);
    }
  }

  void _clearHud() {
    if (!mounted) return;
    setState(() {
      _hudText = null;
      _hudIcon = null;
    });
  }

  void _onLongPressStart(LongPressStartDetails details) {
    if (_dragging) return;

    _speedBeforeLongPress = _speed;
    setState(() {
      _longPressing = true;
      _speed = 2.0;
    });
    _showHud('2.0× 倍速', Icons.fast_forward, hideAfter: null);
    _controller.setSpeed(2.0);
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    if (!_longPressing) return;

    final restoreSpeed = _speedBeforeLongPress;
    setState(() {
      _longPressing = false;
      _speed = restoreSpeed;
    });
    _controller.setSpeed(restoreSpeed);
    _showHud(
      '${_formatSpeed(restoreSpeed)} 倍速',
      Icons.speed,
      hideAfter: const Duration(milliseconds: 550),
    );
  }

  void _onDragStart(DragStartDetails details) {
    if (_longPressing) return;

    _hudTimer?.cancel();
    setState(() {
      _dragging = true;
      _dragDx = 0;
      _seekStartMs = _positionMs;
      _seekTargetMs = _positionMs;
    });
    _showHud('左右滑动调整进度', Icons.swap_horiz, hideAfter: null);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!_dragging || _longPressing) return;

    _dragDx += details.delta.dx;
    final target = _clampTarget(_seekStartMs + (_dragDx * 40).round());
    final delta = target - _seekStartMs;

    setState(() {
      _seekTargetMs = target;
      _hudText = delta >= 0
          ? '快进  ${_formatTime(target)}'
          : '快退  ${_formatTime(target)}';
      _hudIcon = delta >= 0 ? Icons.fast_forward : Icons.fast_rewind;
    });
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_dragging) return;

    final target = _seekTargetMs;
    setState(() {
      _dragging = false;
      _positionMs = target;
      _error = null;
    });
    _controller.seekTo(target);
    _showHud(
      '跳转到 ${_formatTime(target)}',
      Icons.check,
      hideAfter: const Duration(milliseconds: 700),
    );
  }

  void _onDragCancel() {
    if (!_dragging) return;
    setState(() => _dragging = false);
    _clearHud();
  }

  void _onSliderStart(double value) {
    _hudTimer?.cancel();
    setState(() {
      _sliderDragging = true;
      _sliderValue = value;
    });
  }

  void _onSliderChanged(double value) {
    setState(() => _sliderValue = value);
  }

  void _onSliderEnd(double value) {
    final target = value.round();
    setState(() {
      _sliderDragging = false;
      _positionMs = target;
      _error = null;
    });
    _controller.seekTo(target);
    _showHud(
      '跳转到 ${_formatTime(target)}',
      Icons.check,
      hideAfter: const Duration(milliseconds: 700),
    );
  }

  void _selectSpeed(double speed) {
    setState(() {
      _speed = speed;
      _error = null;
    });
    _controller.setSpeed(speed);
    _showHud(
      '${_formatSpeed(speed)} 倍速',
      Icons.speed,
      hideAfter: const Duration(milliseconds: 700),
    );
  }

  int _clampTarget(int value) {
    final max = _durationMs > 0 ? _durationMs : 1 << 30;
    return value.clamp(0, max).toInt();
  }

  String _formatTime(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  String _formatSpeed(double speed) => '${speed.toStringAsFixed(1)}×';

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final sliderMax = _durationMs > 0 ? _durationMs.toDouble() : 1.0;
    final sliderValue = (_sliderDragging
            ? _sliderValue
            : _positionMs.toDouble())
        .clamp(0.0, sliderMax)
        .toDouble();
    final secondaryTrack = _durationMs > 0
        ? (_bufferedMs / _durationMs * sliderMax)
            .clamp(0.0, sliderMax)
            .toDouble()
        : 0.0;
    final showPause = _playWhenReady && _status != 'ended';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          const Center(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: NativeVideoView(),
            ),
          ),

          if (_isEmulator && _brightness < 0.999)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: Colors.black.withValues(
                    alpha: ((1 - _brightness) * 0.8).clamp(0.0, 0.82),
                  ),
                ),
              ),
            ),

          // 全屏手势层：双击、左右拖动、长按。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              onDoubleTap: _togglePlay,
              onLongPressStart: _onLongPressStart,
              onLongPressEnd: _onLongPressEnd,
              onHorizontalDragStart: _onDragStart,
              onHorizontalDragUpdate: _onDragUpdate,
              onHorizontalDragEnd: _onDragEnd,
              onHorizontalDragCancel: _onDragCancel,
              onVerticalDragStart: _onVerticalDragStart,
              onVerticalDragUpdate: _onVerticalDragUpdate,
              onVerticalDragEnd: _onVerticalDragEnd,
              onVerticalDragCancel: _onVerticalDragCancel,
              child: const SizedBox.expand(),
            ),
          ),

          if (_centerIcon != null)
            Center(
              child: IgnorePointer(
                child: Container(
                  width: 86,
                  height: 86,
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(_centerIcon, color: Colors.white, size: 48),
                ),
              ),
            ),

          if (_hudText != null)
            Positioned(
              top: topInset + 24,
              left: 24,
              right: 24,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(_hudIcon, color: Colors.white, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          _hudText!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          if (_status == 'buffering')
            Positioned(
              top: topInset + 78,
              left: 0,
              right: 0,
              child: const IgnorePointer(
                child: Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
            ),

          if (_error != null)
            Positioned(
              top: topInset + 80,
              left: 24,
              right: 24,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ),
            ),

          if (_adjustText != null)
            Positioned(
              top: topInset + 96,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 280),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(_adjustIcon, color: Colors.white, size: 22),
                              const SizedBox(width: 8),
                              Text(
                                '$_adjustText ${(_adjustValue * 100).round()}%',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: _adjustValue,
                              minHeight: 4,
                              backgroundColor: Colors.white24,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          Positioned(
            left: _isLandscape ? 24 : 8,
            right: _isLandscape ? 24 : 8,
            bottom: _isLandscape ? 10 + bottomInset : 18 + bottomInset,
            child: IgnorePointer(
              ignoring: !_controlsVisible,
              child: AnimatedOpacity(
                opacity: _controlsVisible ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: Container(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.58),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                      IconButton(
                        tooltip: showPause ? '暂停' : '播放',
                        color: Colors.white,
                        icon: Icon(
                          showPause
                              ? Icons.pause
                              : (_status == 'ended'
                                  ? Icons.replay
                                  : Icons.play_arrow),
                        ),
                        onPressed: _togglePlay,
                      ),
                      Text(
                        _formatTime(_positionMs),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 11,
                        ),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 14,
                            ),
                            activeTrackColor: Colors.white,
                            inactiveTrackColor: Colors.white24,
                            secondaryActiveTrackColor: Colors.white38,
                            thumbColor: Colors.white,
                            overlayColor: Colors.white24,
                          ),
                          child: Slider(
                            value: sliderValue,
                            max: sliderMax,
                            secondaryTrackValue: secondaryTrack,
                            onChangeStart: _durationMs > 0
                                ? _onSliderStart
                                : null,
                            onChanged: _durationMs > 0
                                ? _onSliderChanged
                                : null,
                            onChangeEnd:
                                _durationMs > 0 ? _onSliderEnd : null,
                          ),
                        ),
                      ),
                      Text(
                        _formatTime(_durationMs),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 11,
                        ),
                      ),
                      PopupMenuButton<double>(
                        initialValue: _speed,
                        tooltip: '播放速度',
                        onSelected: _selectSpeed,
                        itemBuilder: (_) => const [0.5, 1.0, 1.5, 2.0]
                            .map(
                              (value) => PopupMenuItem<double>(
                                value: value,
                                child: Text('${value.toStringAsFixed(1)}×'),
                              ),
                            )
                            .toList(),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            _formatSpeed(_speed),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: _isLandscape ? '切换到竖屏' : '切换到横屏',
                        color: Colors.white,
                        icon: Icon(
                          _isLandscape
                              ? Icons.stay_current_portrait
                              : Icons.screen_rotation,
                        ),
                        onPressed: _toggleOrientation,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
