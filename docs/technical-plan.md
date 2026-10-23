# Flutter + Android 原生 Kotlin 视频播放器技术方案

> 面向只有 HarmonyOS / ArkTS 经验、没有 Android 和 Flutter 经验的开发者。
> 版本基线：Flutter 3.47（2026-10 官方文档基线）、AndroidX Media3 1.11.1（当前稳定版）。
> 目标：Flutter 负责全部播放界面；Android 原生 Kotlin 负责播放器内核；支持播放/暂停、seek、倍速、缓冲/错误状态、全屏等。
>
> 如果只是做“单视频、本地资源、只验证播放/暂停/seek/倍速”的 Demo，请直接看更短的 [极简 Demo 落地手册](simplified-demo.md)。本文件是完整产品化方案，包含多播放器、全屏、HLS、DRM 等扩展。

---

## 0. 一句话结论

**用 AndroidX Media3 的 ExoPlayer 做播放内核，用 `PlayerView + SurfaceView` 通过 Flutter `PlatformView` 嵌到 Flutter 页面里；Flutter 通过 `MethodChannel` 下发控制命令，通过 `EventChannel` 接收播放状态。**

```
┌──────────────────────────── Flutter 侧 ────────────────────────────┐
│  PlayerPage（Flutter Widget）                                       │
│  ├─ 自定义播放按钮 / 进度条 / 倍速菜单 / 全屏 / 错误提示             │
│  ├─ NativePlayerController（ChangeNotifier，保存 UI 快照）           │
│  └─ NativeVideoView（PlatformViewLink + AndroidViewSurface）        │
│            │  MethodChannel：play/pause/seek/setSpeed...            │
│            │  EventChannel：position/duration/buffering/error...     │
└────────────┼────────────────────────────────────────────────────────┘
             │
┌────────────▼──────────────── Android 侧 ────────────────────────────┐
│  MainActivity                                                       │
│  ├─ PlayerRegistry（管理 playerId -> PlayerSession）                 │
│  ├─ MethodChannel Handler（执行控制命令）                            │
│  ├─ EventChannel StreamHandler（把状态发给 Flutter）                 │
│  └─ VideoPlatformView（把 PlayerView 交给 Flutter 显示）             │
│            │                                                         │
│       PlayerSession                                                 │
│       ├─ ExoPlayer（解码、缓冲、音视频同步、倍速、seek）              │
│       ├─ Player.Listener（状态变化回调）                             │
│       └─ 250ms 定时快照（位置/缓冲进度）                             │
│            │                                                         │
│       PlayerView → SurfaceView → Surface                            │
│       （视频帧由解码器直接写入 Surface，不经过 Dart）                 │
└─────────────────────────────────────────────────────────────────────┘
```

关键认知：

1. **视频帧不通过 Flutter 通道传输。** 通道只传“命令”和“状态”。视频帧由 Android 解码器写入 `Surface`，再由系统合成。
2. **Flutter 不拥有播放器。** 真正的播放状态以 Kotlin 的 ExoPlayer 为准；Flutter 只是显示快照，并做乐观 UI。
3. **`PlatformView` 不是视频播放器。** 它只是把 Android 的 `PlayerView` 嵌进 Flutter 的视图树；播放仍然由 ExoPlayer 完成。

--- `SubtitleView`；

- 缓冲转圈、封面、shutter（黑屏过渡）；
- 播放器与 Surface 的绑定生命周期。

所以我们用 `PlayerView`，但 **关闭它自带的控制条**（`useController=false`），控制条全部由 Flutter 画。这样既满足“Flutter 实现播放界面”，又不用自己处理 Surface 细节。

### 2.2 为什么不用其他方案

| 方案 | 结论 | 原因 |
|---|---|---|
| `android.media.MediaPlayer` / `VideoView` | 不推荐 | 老 API；HLS/DASH、倍速、缓冲状态、错误恢复都不如 ExoPlayer；`VideoView` 自带 UI，不适合 Flutter 接管 |
| `ijkplayer` / FFmpeg | 暂不推荐 | 包体大、维护成本高；只有遇到 ExoPlayer 不支持的冷门封装/编码时再考虑 |
| Flutter `video_player` 插件 | 不符合题目要求 | 它内部也是 ExoPlayer，但把原生能力封装掉了；你无法真正实现/掌控 Kotlin 播放核心，DRM、轨选择等扩展也受限 |
| `better_player` 等三方播放器 | 不推荐 | 维护状态和兼容性不可控；本项目不需要 |
| 自己写 MediaCodec + AudioTrack | 不推荐 | 等于重造 ExoPlayer；同步、缓冲、seek、倍速、错误处理都非常复杂 |

**“Android 原生 Kotlin 实现播放器核心”不等于“自己写解码器”。** 使用 Media3 就是标准 Android 原生做法，和 HarmonyOS 用 `AVPlayer` 而不是自己写解码器是一个道理。

### 2.3 权限与 Manifest

`android/app/src/main/AndroidManifest.xml`：

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
```

如果后续使用 `setWakeMode(C.WAKE_MODE_NETWORK)` 做长时间/后台播放，再增加：

```xml
<uses-permission android:name="android.permission.WAKE_LOCK" />
```

开发阶段如果使用 `http://` 地址，Android 9+ 默认禁止明文流量。**只建议在 debug 配置里临时放开**，生产必须用 HTTPS：

```xml
<!-- 仅 debug，不要带到 release -->
<application android:usesCleartextTraffic="true" ...>
```

### 2.4 `minSdk` 建议

Flutter 当前模板的 `minSdk` 通常已经够用。Media3 1.11.x 建议 `minSdk >= 23/24`。新项目直接保持 Flutter 模板默认值即可；如果要兼容更老设备，先确认 Media3 的最低要求。

---

## 3. 视频画面如何渲染到 Flutter

### 3.1 三种可选路线

| 路线 | 做法 | 优点 | 缺点 | 适用 |
|---|---|---|---|---|
| **A. PlatformView + PlayerView/SurfaceView（推荐）** | Android 原生 View 嵌进 Flutter | 视频性能最好；SurfaceView 直接显示；实现最简单；字幕/宽高比现成 | Hybrid Composition 会合并 Flutter raster 线程和 Android 主线程，复杂 Flutter 动画可能掉帧；SurfaceView 不好做圆角和任意变换 | 本任务首选 |
| B. PlatformView + TextureView | 同上，但 `PlayerView` 用 `surface_type=texture_view` | 可以圆角、缩放、动画；层级问题少 | 每帧多一次 GPU 拷贝；高分辨率/高帧率更耗性能 | 需要圆角/复杂变换时 |
| C. TextureRegistry + SurfaceProducer + Flutter `Texture` | 原生把视频渲染到 Flutter 提供的纹理，Flutter 用 `Texture` Widget 显示 | 视频像普通 Flutter 图层，可做任意变换；没有 PlatformView 的线程合并开销 | 实现复杂：要自己管理 `SurfaceProducer`、尺寸、生命周期、释放；调试成本高 | 第二阶段或高级需求 |

**本方案选 A。** 如果后面发现 Hybrid Composition 让 Flutter 动画明显卡顿，再评估 C，或者试试 Flutter 的 HCPP（实验特性，要求 Android API 34+ 和 Vulkan）。

### 3.2 为什么用 Hybrid Composition，而不是默认 Texture Layer

Flutter 3.47 的 Android PlatformView 默认实现是 **Texture Layer**（`AndroidView` 默认），它把原生 View 渲染到纹理，再由 Flutter 合成。它适合 WebView/地图等，但对 `SurfaceView` 视频有几个现实问题：

- `SurfaceView` 的无障碍和文字放大可能异常；
- 快速滚动时容易 jank；
- 视频 Surface 的层级/裁剪行为不如原生视图树稳定。

官方文档明确：**Hybrid Composition 对 `SurfaceView` 的支持最好**。因此视频播放器建议用：

```dart
PlatformViewLink + AndroidViewSurface
```

而不是直接 `AndroidView(...)`。代价是 Hybrid Composition 会把 Flutter 的 raster 线程合并到 Android 主线程，复杂 Flutter 动画可能掉帧；但播放页的 Flutter UI 通常只有控制条，影响可控。

### 3.3 原生 `PlayerView` 的配置

`android/app/src/main/res/layout/player_view.xml`：

```xml
<?xml version="1.0" encoding="utf-8"?>
<androidx.media3.ui.PlayerView
    xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:app="http://schemas.android.com/apk/res-auto"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:background="@android:color/black"
    app:use_controller="false"
    app:resize_mode="fit"
    app:surface_type="surface_view"
    app:shutter_background_color="@android:color/black" />
```

说明：

- `use_controller=false`：不要原生控制条，Flutter 自己画。
- `resize_mode=fit`：保持视频宽高比，剩余区域黑边。
- `surface_type=surface_view`：性能优先。若要圆角/变换，改成 `texture_view`。
- `shutter_background_color`：Surface 还没出画面时显示黑色，避免花屏/白屏。

### 3.4 PlatformView 的原生实现

`VideoPlatformView` 只做三件事：创建 `PlayerView`、把它加到容器、销毁时释放播放器。

```kotlin
package com.example.video_player_demo

import android.content.Context
import android.graphics.Color
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import io.flutter.plugin.platform.PlatformView

class VideoPlatformView(
    context: Context,
    private val viewId: Int,
    creationParams: Map<*, *>,
    private val registry: PlayerRegistry,
) : PlatformView {

    private val root = FrameLayout(context).apply {
        setBackgroundColor(Color.BLACK)
    }
    private var session: PlayerSession? = null

    init {
        val url = creationParams["url"] as? String
        if (url.isNullOrBlank()) {
            root.addView(errorText(context, "缺少视频地址"))
        } else {
            try {
                val created = registry.createSession(
                    context = context,
                    viewId = viewId,
                    url = url,
                    autoplay = creationParams["autoplay"] == true,
                )
                session = created
                root.addView(
                    created.view,
                    FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT,
                    ),
                )
            } catch (e: Exception) {
                root.addView(errorText(context, "播放器初始化失败：${e.message}"))
            }
        }
    }

    override fun getView(): View = root

    override fun dispose() {
        registry.disposeSession(viewId)
        session = null
    }

    private fun errorText(context: Context, message: String): TextView =
        TextView(context).apply {
            text = message
            setTextColor(Color.WHITE)
            gravity = android.view.Gravity.CENTER
        }
}
```

`VideoViewFactory`：

```kotlin
package com.example.video_player_demo

import android.content.Context
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class VideoViewFactory(
    private val registry: PlayerRegistry,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val params = args as? Map<*, *> ?: emptyMap<Any, Any>()
        return VideoPlatformView(context, viewId, params, registry)
    }
}
```

在 `MainActivity` 注册：

```kotlin
package com.example.video_player_demo

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    private var registry: PlayerRegistry? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val playerRegistry = PlayerRegistry(flutterEngine.dartExecutor.binaryMessenger)
        registry = playerRegistry

        flutterEngine.platformViewsController.registry.registerViewFactory(
            "native_video_view",
            VideoViewFactory(playerRegistry),
        )
    }

    override fun onPause() {
        // 默认：App 退到后台就暂停。若要后台音频，改为不暂停并考虑前台服务。
        registry?.pauseAll()
        super.onPause()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        registry?.dispose()
        registry = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
```

> 包名 `com.example.video_player_demo` 要和 `android/app/build.gradle.kts` 里的 `namespace/applicationId` 一致。用 `flutter create` 生成后，按实际包名调整。

### 3.5 Flutter 侧的 PlatformView

```dart
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class NativeVideoView extends StatelessWidget {
  const NativeVideoView({
    super.key,
    required this.url,
    required this.autoplay,
    required this.onPlatformViewCreated,
  });

  static const String viewType = 'native_video_view';

  final String url;
  final bool autoplay;
  final ValueChanged<int> onPlatformViewCreated;

  @override
  Widget build(BuildContext context) {
    final creationParams = <String, dynamic>{
      'url': url,
      'autoplay': autoplay,
    };

    return PlatformViewLink(
      viewType: viewType,
      surfaceFactory: (context, controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        );
      },
      onCreatePlatformView: (params) {
        return PlatformViewsService.initSurfaceAndroidView(
          id: params.id,
          viewType: viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        )
          ..addOnPlatformViewCreatedListener((id) {
            params.onPlatformViewCreated(id);
            onPlatformViewCreated(id);
          })
          ..create();
      },
    );
  }
}
```

要点：

- `onPlatformViewCreated(id)` 里拿到的 `id` 就是原生平台 View 的 id，后面所有 MethodChannel 命令都用它做 `playerId`。
- 视频控件外面用 `AspectRatio` 或固定 16:9 容器；视频比例未知时先用 16:9 占位，收到 `videoWidth/videoHeight` 后再调整。
- 不要在 `build()` 里根据播放进度重建整个 `NativeVideoView`，否则可能触发 PlatformView 重建。用稳定的 Widget 树，只让控制条局部刷新。
- `SurfaceView` 不适合做圆角裁剪。设计稿如果要求圆角视频，直接用 `texture_view`，或者用 Flutter 侧黑色遮罩/边框规避。

---

## 4. Flutter 与 Android 如何传消息

### 4.1 通道划分

只开两个通道，职责分开：

| 通道 | 类型 | 方向 | 用途 |
|---|---|---|---|
| `com.example.video_player_demo/commands` | `MethodChannel` | Flutter → Android | 播放/暂停/seek/倍速/音量/重试/释放 |
| `com.example.video_player_demo/events` | `EventChannel` | Android → Flutter | 状态快照、错误、视频尺寸 |

命名空间可以换成你自己的包名，但一旦确定就保持稳定。

**不要**用 MethodChannel 传视频帧，也不要用它每 16ms 拉一次进度。视频帧走 Surface/GPU；进度用 EventChannel 4Hz 快照 + Flutter 本地插值。

### 4.2 命令协议

所有命令都带 `playerId`：

| method | 参数 | 原生动作 | 返回值 |
|---|---|---|---|
| `play` | `playerId` | `exoPlayer.play()` | `null` |
| `pause` | `playerId` | `exoPlayer.pause()` | `null` |
| `seekTo` | `playerId`, `positionMs` | `exoPlayer.seekTo(ms)` | `null` |
| `setSpeed` | `playerId`, `speed` | `exoPlayer.setPlaybackSpeed(f)` | `null` |
| `setVolume` | `playerId`, `volume` | `exoPlayer.volume = f` | `null` |
| `retry` | `playerId` | `exoPlayer.prepare()` | `null` |
| `getState` | `playerId` | 返回当前快照 | `Map` |
| `release` | `playerId` | 释放 ExoPlayer | `null` |

错误用 `result.error(code, message, details)` 返回，Flutter 侧捕获 `PlatformException`。

### 4.3 状态事件协议

每次发**完整快照**，不要发增量。完整快照可以丢、可以重复，UI 永远以最后一条为准。

```json
{
  "type": "state",
  "playerId": 7,
  "playbackState": "ready",
  "positionMs": 12340,
  "durationMs": 60000,
  "bufferedMs": 30000,
  "isPlaying": true,
  "playWhenReady": true,
  "speed": 1.0,
  "videoWidth": 1920,
  "videoHeight": 1080
}
```

错误单独发：

```json
{
  "type": "error",
  "playerId": 7,
  "errorCode": 2001,
  "message": "Source error"
}
```

`playbackState` 只暴露 4 个值：

| 值 | 含义 | Flutter UI |
|---|---|---|
| `idle` | 未准备/已释放 | 加载中或错误 |
| `buffering` | 缓冲中 | 转圈；保留当前画面 |
| `ready` | 可播放/已暂停/播放中 | 显示播放/暂停按钮 |
| `ended` | 播放结束 | 显示重播按钮 |

注意区分：

- `playWhenReady`：用户“想不想播”。播放/暂停按钮图标通常看它。
- `isPlaying`：当前是否真的在出帧。缓冲时 `playWhenReady=true` 但 `isPlaying=false`。
- 所以缓冲时按钮可以显示“暂停”，同时叠一个转圈，而不是把按钮切成“播放”。

### 4.4 状态机

```
                 ┌──────────── error ────────────┐
                 │                               │
idle ──prepare──▶ buffering ──ready──▶ ready ──end──▶ ended
  ▲                   │                  │  ▲            │
  │                   └──── error ───────┘  └── seek ────┘
  └──────────────────── release ──────────────────────────
```

Flutter 不需要精确复刻 ExoPlayer 的所有内部状态；它只需要这 4 个状态 + `error`。

### 4.5 原生播放会话

`PlayerSession` 是核心，负责 ExoPlayer、`PlayerView`、监听器和定时快照。

```kotlin
package com.example.video_player_demo

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.LayoutInflater
import android.widget.FrameLayout
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import java.io.File

class PlayerSession(
    context: Context,
    val playerId: Int,
    url: String,
    autoplay: Boolean,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val appContext = context.applicationContext
    private var released = false

    private val exoPlayer: ExoPlayer = ExoPlayer.Builder(appContext).build().apply {
        setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(),
            true, // 自动处理音频焦点
        )
        setHandleAudioBecomingNoisy(true) // 拔耳机自动暂停
        playWhenReady = autoplay
        setMediaItem(MediaItem.fromUri(toUri(url)))
        prepare()
    }

    val view: PlayerView = (
        LayoutInflater.from(context)
            .inflate(R.layout.player_view, FrameLayout(context), false) as PlayerView
        ).apply {
        useController = false
        player = exoPlayer
        isClickable = false
    }

    private val listener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) {
            view.keepScreenOn = player.isPlaying
            emitSnapshot()
        }

        override fun onPlayerError(error: PlaybackException) {
            emit(
                mapOf(
                    "type" to "error",
                    "playerId" to playerId,
                    "errorCode" to error.errorCode,
                    "message" to (error.message ?: "Playback error"),
                ),
            )
        }
    }

    private val ticker = object : Runnable {
        override fun run() {
            if (released) return
            emitSnapshot()
            mainHandler.postDelayed(this, 250L)
        }
    }

    init {
        exoPlayer.addListener(listener)
        mainHandler.post(ticker)
    }

    fun play() {
        if (!released) exoPlayer.play()
    }

    fun pause() {
        if (!released) exoPlayer.pause()
    }

    fun seekTo(positionMs: Long) {
        if (!released) exoPlayer.seekTo(positionMs.coerceAtLeast(0L))
    }

    fun setSpeed(speed: Float) {
        if (!released) exoPlayer.setPlaybackSpeed(speed.coerceIn(0.25f, 4.0f))
    }

    fun setVolume(volume: Float) {
        if (!released) exoPlayer.volume = volume.coerceIn(0f, 1f)
    }

    fun retry() {
        if (!released) exoPlayer.prepare()
    }

    fun snapshot(): Map<String, Any?> {
        val duration = exoPlayer.duration.let { if (it == C.TIME_UNSET) 0L else it }
        val buffered = exoPlayer.bufferedPosition.let { if (it == C.TIME_UNSET) 0L else it }
        val size = exoPlayer.videoSize

        return mapOf(
            "type" to "state",
            "playerId" to playerId,
            "playbackState" to when (exoPlayer.playbackState) {
                Player.STATE_IDLE -> "idle"
                Player.STATE_BUFFERING -> "buffering"
                Player.STATE_READY -> "ready"
                Player.STATE_ENDED -> "ended"
                else -> "idle"
            },
            "positionMs" to exoPlayer.currentPosition.coerceAtLeast(0L),
            "durationMs" to duration,
            "bufferedMs" to buffered.coerceAtLeast(0L),
            "isPlaying" to exoPlayer.isPlaying,
            "playWhenReady" to exoPlayer.playWhenReady,
            "speed" to exoPlayer.playbackParameters.speed.toDouble(),
            "videoWidth" to size.width,
            "videoHeight" to size.height,
        )
    }

    fun emitSnapshot() {
        if (!released) emit(snapshot())
    }

    fun release() {
        if (released) return
        released = true
        mainHandler.removeCallbacks(ticker)
        exoPlayer.removeListener(listener)
        view.player = null
        exoPlayer.release()
    }

    private fun toUri(raw: String): Uri =
        if (raw.contains("://")) Uri.parse(raw) else Uri.fromFile(File(raw))
}
```

几个容易踩的点：

- **所有 ExoPlayer 调用都在主线程**。MethodChannel 回调、`Player.Listener`、`Handler` 都在主线程，不要切换到后台线程。
- `setAudioAttributes(..., true)` 的第二个参数是 `handleAudioFocus`，让 ExoPlayer 处理来电/其他 App 抢占音频。
- `setHandleAudioBecomingNoisy(true)` 处理拔耳机。
- `currentPosition` 不要每帧轮询；250ms 足够，Flutter 侧插值。
- `duration == C.TIME_UNSET` 表示直播/未知时长，转成 0 并禁用 seek。
- `view.player = null` 必须在 `exoPlayer.release()` 之前，避免 Surface 释放顺序问题。
- `released` 幂等，防止 PlatformView dispose 和 Flutter controller 同时 release。

### 4.6 原生注册表与通道处理

```kotlin
package com.example.video_player_demo

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class PlayerRegistry(messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val sessions = mutableMapOf<Int, PlayerSession>()
    private var eventSink: EventChannel.EventSink? = null

    private val methodChannel = MethodChannel(messenger, CHANNEL_COMMANDS).apply {
        setMethodCallHandler(this@PlayerRegistry)
    }
    private val eventChannel = EventChannel(messenger, CHANNEL_EVENTS).apply {
        setStreamHandler(this@PlayerRegistry)
    }

    fun createSession(
        context: Context,
        viewId: Int,
        url: String,
        autoplay: Boolean,
    ): PlayerSession {
        sessions.remove(viewId)?.release()
        val session = PlayerSession(context, viewId, url, autoplay) { event ->
            eventSink?.success(event)
        }
        sessions[viewId] = session
        return session
    }

    fun disposeSession(viewId: Int) {
        sessions.remove(viewId)?.release()
    }

    fun pauseAll() {
        sessions.values.forEach { it.pause() }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val playerId = call.argument<Number>("playerId")?.toInt()
            ?: return result.error("NO_PLAYER_ID", "playerId is required", null)
        val session = sessions[playerId]
            ?: return result.error("NO_PLAYER", "Player not found: $playerId", null)

        try {
            when (call.method) {
                "play" -> session.play()
                "pause" -> session.pause()
                "seekTo" -> session.seekTo(
                    call.argument<Number>("positionMs")?.toLong() ?: 0L,
                )
                "setSpeed" -> session.setSpeed(
                    call.argument<Number>("speed")?.toFloat() ?: 1f,
                )
                "setVolume" -> session.setVolume(
                    call.argument<Number>("volume")?.toFloat() ?: 1f,
                )
                "retry" -> session.retry()
                "getState" -> {
                    result.success(session.snapshot())
                    return
                }
                "release" -> {
                    sessions.remove(playerId)?.release()
                    result.success(null)
                    return
                }
                else -> {
                    result.notImplemented()
                    return
                }
            }
            result.success(null)
        } catch (e: Exception) {
            result.error("PLAYER_ERROR", e.message, null)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
        sessions.values.forEach { it.emitSnapshot() }
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun dispose() {
        eventSink = null
        sessions.values.toList().forEach { it.release() }
        sessions.clear()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    companion object {
        const val CHANNEL_COMMANDS = "com.example.video_player_demo/commands"
        const val CHANNEL_EVENTS = "com.example.video_player_demo/events"
    }
}
```

> 这是单播放器 MVP 的简化版。多播放器/列表页时，建议每个播放器独立的 EventChannel，或继续用全局事件 + `playerId` 过滤，但要注意 EventChannel 只有一个 `EventSink`。

### 4.7 Flutter 侧控制器

```dart
import 'dart:async';

import 'package:flutter/services.dart';

enum PlaybackStatus { idle, buffering, ready, ended }

class PlayerSnapshot {
  const PlayerSnapshot({
    this.status = PlaybackStatus.idle,
    this.positionMs = 0,
    this.durationMs = 0,
    this.bufferedMs = 0,
    this.isPlaying = false,
    this.playWhenReady = false,
    this.speed = 1.0,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.error,
  });

  final PlaybackStatus status;
  final int positionMs;
  final int durationMs;
  final int bufferedMs;
  final bool isPlaying;
  final bool playWhenReady;
  final double speed;
  final int videoWidth;
  final int videoHeight;
  final String? error;

  bool get isBuffering => status == PlaybackStatus.buffering;
  bool get isEnded => status == PlaybackStatus.ended;
  bool get hasError => error != null;

  factory PlayerSnapshot.fromEvent(Map<Object?, Object?> map) {
    final status = switch (map['playbackState']) {
      'buffering' => PlaybackStatus.buffering,
      'ready' => PlaybackStatus.ready,
      'ended' => PlaybackStatus.ended,
      _ => PlaybackStatus.idle,
    };

    int asInt(Object? value) => (value as num?)?.toInt() ?? 0;
    double asDouble(Object? value) => (value as num?)?.toDouble() ?? 0;

    return PlayerSnapshot(
      status: status,
      positionMs: asInt(map['positionMs']),
      durationMs: asInt(map['durationMs']),
      bufferedMs: asInt(map['bufferedMs']),
      isPlaying: map['isPlaying'] == true,
      playWhenReady: map['playWhenReady'] == true,
      speed: asDouble(map['speed']).clamp(0.25, 4.0).toDouble(),
      videoWidth: asInt(map['videoWidth']),
      videoHeight: asInt(map['videoHeight']),
    );
  }

  PlayerSnapshot copyWith({
    PlaybackStatus? status,
    int? positionMs,
    int? durationMs,
    int? bufferedMs,
    bool? isPlaying,
    bool? playWhenReady,
    double? speed,
    int? videoWidth,
    int? videoHeight,
    String? error,
    bool clearError = false,
  }) {
    return PlayerSnapshot(
      status: status ?? this.status,
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      bufferedMs: bufferedMs ?? this.bufferedMs,
      isPlaying: isPlaying ?? this.isPlaying,
      playWhenReady: playWhenReady ?? this.playWhenReady,
      speed: speed ?? this.speed,
      videoWidth: videoWidth ?? this.videoWidth,
      videoHeight: videoHeight ?? this.videoHeight,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class NativePlayerController extends ChangeNotifier {
  NativePlayerController({this.autoplay = false});

  static const MethodChannel _commands =
      MethodChannel('com.example.video_player_demo/commands');
  static const EventChannel _events =
      EventChannel('com.example.video_player_demo/events');

  // 静态 broadcast stream：多个 controller 共享一个原生订阅。
  static final Stream<dynamic> _eventStream = _events.receiveBroadcastStream();

  final bool autoplay;

  int? _viewId;
  StreamSubscription<dynamic>? _subscription;
  PlayerSnapshot _state = const PlayerSnapshot();

  PlayerSnapshot get state => _state;
  bool get isAttached => _viewId != null;
  int? get viewId => _viewId;

  Future<void> attach(int viewId) async {
    if (_viewId == viewId && _subscription != null) return;
    _viewId = viewId;
    _subscription ??= _eventStream.listen(_onEvent);
    await _syncState();
  }

  Future<void> _syncState() async {
    final id = _viewId;
    if (id == null) return;
    try {
      final map = await _commands.invokeMethod<Map<Object?, Object?>>(
        'getState',
        {'playerId': id},
      );
      if (map != null) _applyEvent(map);
    } on PlatformException catch (e) {
      _setError(e.message ?? '获取播放状态失败');
    }
  }

  Future<void> _invoke(String method, [Map<String, Object?> args = const {}]) async {
    final id = _viewId;
    if (id == null) return; // UI 层应在 attach 前禁用按钮
    try {
      await _commands.invokeMethod<void>(method, {
        'playerId': id,
        ...args,
      });
    } on PlatformException catch (e) {
      _setError(e.message ?? '原生播放器调用失败');
    }
  }

  Future<void> play() => _invoke('play');

  Future<void> pause() => _invoke('pause');

  Future<void> seekTo(int positionMs) {
    final max = _state.durationMs > 0 ? _state.durationMs : positionMs;
    final target = positionMs.clamp(0, max).toInt();
    _state = _state.copyWith(positionMs: target);
    notifyListeners();
    return _invoke('seekTo', {'positionMs': target});
  }

  Future<void> setSpeed(double speed) {
    final value = speed.clamp(0.25, 4.0).toDouble();
    _state = _state.copyWith(speed: value);
    notifyListeners();
    return _invoke('setSpeed', {'speed': value});
  }

  Future<void> setVolume(double volume) =>
      _invoke('setVolume', {'volume': volume.clamp(0.0, 1.0).toDouble()});

  Future<void> retry() {
    _state = _state.copyWith(clearError: true);
    notifyListeners();
    return _invoke('retry');
  }

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    if (raw['playerId'] != _viewId) return;
    _applyEvent(raw);
  }

  void _applyEvent(Map<Object?, Object?> raw) {
    if (raw['type'] == 'error') {
      _setError(_friendlyError(raw));
      return;
    }
    if (raw['type'] != 'state') return;

    final incoming = PlayerSnapshot.fromEvent(raw);
    // 错误后可能还会收到 idle 快照，先保留错误，等 retry/load 再清。
    final keepError =
        _state.error != null && incoming.status == PlaybackStatus.idle;
    _state = incoming.copyWith(
      error: keepError ? _state.error : null,
      clearError: !keepError,
    );
    notifyListeners();
  }

  void _setError(String message) {
    _state = _state.copyWith(error: message);
    notifyListeners();
  }

  String _friendlyError(Map<Object?, Object?> raw) {
    final code = (raw['errorCode'] as num?)?.toInt();
    if (code == 2001 || code == 2002) return '网络连接失败，请检查网络后重试';
    if (code == 2003) return '视频地址返回了错误状态，请稍后重试';
    if (code == 2004) return '视频文件不存在或地址失效';
    if (code != null && code >= 3000 && code < 4000) return '视频格式无法解析';
    return '播放失败，请重试';
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    super.dispose();
  }
}
```

注意：

- `dispose()` 里不主动 `release` 原生播放器，因为 `PlatformView.dispose()` 会释放；两边都调用也可以，原生 `released` 幂等。关键是不能只释放 Dart 订阅而忘记原生播放器。
- `seekTo` / `setSpeed` 先改本地快照，是“乐观 UI”；原生事件回来后以原生为准。
- 快速拖动进度条时，会有旧的位置事件回来。可以在 `seekTo` 后 300ms 内忽略 `positionMs`，或者用递增的 `seekEpoch` 只接受最新 seek 之后的事件。MVP 可先不做，但要知道这个现象。
- `PlayerSnapshot.fromEvent` 里 `switch` 表达式需要 Dart 3；Flutter 3.47 没问题。

### 4.8 进度同步：250ms 快照 + Flutter 插值

原生每 250ms 发一次 `positionMs`，Flutter 不能每 250ms 跳一下，否则进度条会一顿一顿。做法：

```
每次收到原生快照：
  anchorPosition = snapshot.positionMs
  anchorTime = now

播放中每帧计算：
  displayPosition = anchorPosition + (now - anchorTime) * speed
  displayPosition = clamp(0, duration)

暂停/缓冲/结束：
  直接显示 snapshot.positionMs，不插值
```

这样：

- 通道只有 4Hz，不会把 Dart 主 isolate 打满；
- 进度条 60fps 平滑；
- 原生事件回来后自动校正漂移；
- seek 时本地先跳，原生确认后再校正。

进度条 Widget 用一个局部 `Ticker`，不要每帧 `setState` 整个页面：

```dart
class PlayerProgressBar extends StatefulWidget {
  const PlayerProgressBar({super.key, required this.controller});

  final NativePlayerController controller;

  @override
  State<PlayerProgressBar> createState() => _PlayerProgressBarState();
}

class _PlayerProgressBarState extends State<PlayerProgressBar>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double? _dragMs;
  int _anchorMs = 0;
  DateTime _anchorAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _anchorMs = widget.controller.state.positionMs;
    widget.controller.addListener(_resetAnchor);
    _ticker = createTicker((_) => setState(() {}))..start();
  }

  void _resetAnchor() {
    _anchorMs = widget.controller.state.positionMs;
    _anchorAt = DateTime.now();
  }

  int get _displayPosition {
    if (_dragMs != null) return _dragMs!.round();
    final s = widget.controller.state;
    if (!s.isPlaying) return s.positionMs;

    final elapsed = DateTime.now().difference(_anchorAt).inMilliseconds;
    final next = _anchorMs + (elapsed * s.speed).round();
    if (s.durationMs <= 0) return next;
    return next.clamp(0, s.durationMs).toInt();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_resetAnchor);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final duration = widget.controller.state.durationMs;
    final max = duration > 0 ? duration.toDouble() : 1.0;
    final value = _displayPosition.toDouble().clamp(0.0, max).toDouble();

    return Slider(
      value: value,
      max: max,
      onChanged: duration <= 0
          ? null
          : (v) => setState(() => _dragMs = v),
      onChangeEnd: duration <= 0
          ? null
          : (v) {
              setState(() => _dragMs = null);
              widget.controller.seekTo(v.round());
            },
    );
  }
}
```

> `Ticker` 在暂停时也会每帧重建这个进度条。可以进一步在 `isPlaying` 变化时 `start/stop`，但 MVP 这样已经够用，因为只重建局部 Widget。

---

## 5. Flutter 播放界面设计

### 5.1 页面结构

```dart
Scaffold(
  backgroundColor: Colors.black,
  body: SafeArea(
    top: !_fullscreen,
    bottom: !_fullscreen,
    child: Stack(
      children: [
        // 1. 视频画面（PlatformView）
        Positioned.fill(
          child: Center(
            child: AspectRatio(
              aspectRatio: _videoAspectRatio, // 未知时 16:9
              child: NativeVideoView(
                url: widget.url,
                autoplay: false,
                onPlatformViewCreated: (id) {
                  _controller.attach(id);
                },
              ),
            ),
          ),
        ),

        // 2. 缓冲转圈
        if (_controller.state.isBuffering)
          const Center(child: CircularProgressIndicator()),

        // 3. 错误/重试
        if (_controller.state.hasError)
          _ErrorOverlay(
            message: _controller.state.error!,
            onRetry: _controller.retry,
          ),

        // 4. 控制层（点击显示/隐藏）
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            child: AnimatedOpacity(
              opacity: _controlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: _PlayerControls(
                  controller: _controller,
                  onToggleFullscreen: _toggleFullscreen,
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  ),
)
```

### 5.2 控制条

页面 State 里要监听 controller，否则原生状态回来 UI 不会刷新。最简做法：

```dart
class _PlayerPageState extends State<PlayerPage> {
  late final NativePlayerController _controller;
  bool _controlsVisible = true;
  bool _fullscreen = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _controller = NativePlayerController(autoplay: false);
    _controller.addListener(_onPlayerChanged);
  }

  void _onPlayerChanged() {
    if (!mounted) return;
    setState(() {});
  }

  double get _videoAspectRatio {
    final s = _controller.state;
    if (s.videoWidth > 0 && s.videoHeight > 0) {
      return s.videoWidth / s.videoHeight;
    }
    return 16 / 9; // 视频尺寸未知时的占位比例
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller.removeListener(_onPlayerChanged);
    _controller.dispose();
    // 如果进过全屏，恢复系统 UI 和方向
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([]);
    super.dispose();
  }
}
```

> 这个 `setState` 只适合 MVP。状态事件 4Hz + 控制层重建通常没问题；如果页面很复杂，改成 `ValueListenableBuilder` / `AnimatedBuilder`，只重建控制条和进度条。

建议包含：

- 中央大按钮：播放 / 暂停 / 重播（根据 `status` 和 `playWhenReady`）。
- 底部：
  - 当前时间 / 总时长；
  - 进度条（含缓冲进度）；
  - 倍速菜单：`0.5 / 0.75 / 1.0 / 1.25 / 1.5 / 2.0`；
  - 全屏按钮。
- 顶部：返回、标题（可选）。
- 缓冲：转圈，不要隐藏当前画面。
- 错误：半透明黑色遮罩 + 文案 + 重试。
- 点击视频区域：显示/隐藏控制层；3 秒后自动隐藏（暂停/结束/错误时不隐藏）。
- 拖动进度条时：暂停自动隐藏计时器；拖动结束再 seek。

按钮逻辑示例：

```dart
IconButton(
  icon: Icon(
    controller.state.playWhenReady
        ? Icons.pause
        : (controller.state.isEnded ? Icons.replay : Icons.play_arrow),
  ),
  onPressed: () {
    if (controller.state.isEnded) {
      controller.seekTo(0);
      controller.play();
    } else if (controller.state.playWhenReady) {
      controller.pause();
    } else {
      controller.play();
    }
  },
)
```

### 5.3 全屏

**MVP 推荐：不跳新路由，在当前页面内展开 + 横屏。** 因为 `Navigator.push` 到新页面会销毁/重建 PlatformView，播放器可能重建并从 0 开始。

```dart
Future<void> _toggleFullscreen() async {
  setState(() => _fullscreen = !_fullscreen);

  if (_fullscreen) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  } else {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations([]);
  }
}
```

并在 `dispose()` 里恢复，否则退出页面后系统 UI 还停留在沉浸模式：

```dart
@override
void dispose() {
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setPreferredOrientations([]);
  _hideTimer?.cancel();
  _controller.dispose();
  super.dispose();
}
```

注意：Android 16 在平板/大屏上可能忽略横屏锁定，应使用响应式布局，而不是强依赖方向。

### 5.4 生命周期

| 时机 | 做什么 |
|---|---|
| Flutter `initState` | 创建 controller；如果 controller 需要 URL，在这里保存 |
| PlatformView created | `controller.attach(id)`，订阅事件并拉一次 `getState` |
| Android `onPause` | 默认 `pauseAll()`；后台音频场景另说 |
| Flutter `dispose` | 取消定时器、取消事件订阅、恢复系统 UI |
| PlatformView `dispose` | 原生 `release()`，移除监听器、停止 ticker、释放 ExoPlayer |
| `cleanUpFlutterEngine` | 释放 registry 中所有 session |
| App 被杀死 | 系统回收；不要依赖回调做持久化 |

---

## 6. 项目结构

```
flutter_android_player/
├── lib/
│   ├── main.dart
│   └── player/
│       ├── native_player_controller.dart
│       ├── native_player_view.dart
│       ├── player_page.dart
│       ├── player_progress_bar.dart
│       └── player_controls.dart
├── android/app/src/main/
│   ├── AndroidManifest.xml
│   ├── kotlin/com/example/video_player_demo/
│   │   ├── MainActivity.kt
│   │   ├── PlayerRegistry.kt
│   │   ├── PlayerSession.kt
│   │   ├── VideoPlatformView.kt
│   │   └── VideoViewFactory.kt
│   └── res/layout/player_view.xml
├── docs/
│   └── technical-plan.md
└── pubspec.yaml
```

初期**不要**做成独立 Flutter plugin。先把原生代码放在 app 模块里，跑通“一个页面、一个播放器”。等确认稳定、需要复用时，再抽成 local plugin/federated plugin。

---

## 7. 实施步骤

### 第 1 步：创建工程并跑通空页面

```bash
flutter create --project-name video_player_demo --org com.example --platforms=android .
flutter run
```

先确认：

- `flutter doctor` 通过；
- Android Studio / SDK / 模拟器或真机可用；
- 空 Flutter 页面能启动。

### 第 2 步：只验证“原生视频能显示”

1. 加 Media3 依赖；
2. 加 `player_view.xml`；
3. 写 `PlayerSession`（可以先不接通道，URL 写死一个测试 MP4）；
4. 写 `VideoPlatformView` / `VideoViewFactory`；
5. 在 `MainActivity` 注册；
6. Flutter 用 `NativeVideoView` 显示。

**验收：** 真机上能看到视频画面，黑边/比例正常，退出页面声音停止。

### 第 3 步：加 MethodChannel

先只做 `play` / `pause` / `seekTo` / `setSpeed`，用两个 Flutter 按钮测试。

**验收：** 点击 Flutter 按钮，原生播放器有反应；seek 后画面跳转；倍速生效。

### 第 4 步：加 EventChannel

1. `Player.Listener` 推状态；
2. 250ms ticker 推位置；
3. Flutter controller 收快照；
4. 控制条显示真实状态。

**验收：** 播放/暂停按钮图标正确；缓冲转圈；进度条平滑；播放结束显示重播；错误显示重试。

### 第 5 步：打磨

- 点击显示/隐藏控制条；
- 3 秒自动隐藏；
- 拖动 seek 的乐观更新与防抖；
- 全屏/横屏/系统 UI 恢复；
- 音频焦点、拔耳机、后台暂停；
- 错误码文案；
- 旋转、切后台、快速进出页面；
- release 构建测试（R8/混淆）。

### 第 6 步：扩展

- HLS/DASH；
- 自定义请求头/鉴权；
- 字幕/音轨选择；
- DRM（Widevine）；
- 画中画；
- 播放列表/多播放器；
- 截图/滤镜/手势缩放（这时评估 TextureRegistry 路线）。

---

## 8. 验收清单

### 功能

- [ ] 网络 MP4 能播放；
- [ ] HLS（如需要）能播放；
- [ ] 播放/暂停；
- [ ] 拖动 seek，松手后跳转；
- [ ] 暂停状态 seek 后画面更新；
- [ ] 0.5x / 1.0x / 1.5x / 2.0x 倍速，音调正常；
- [ ] 播放结束显示重播；
- [ ] 缓冲转圈；
- [ ] 错误提示 + 重试；
- [ ] 全屏/退出全屏，系统 UI 恢复；
- [ ] 返回页面后声音停止；
- [ ] 切后台自动暂停；
- [ ] 拔耳机自动暂停；
- [ ] 屏幕常亮仅在播放时生效。

### 稳定性

- [ ] 快速连点播放/暂停不崩溃；
- [ ] 快速拖动 seek 不 ANR；
- [ ] 播放中旋转屏幕不重启播放器；
- [ ] 连续进出播放页 20 次，无内存增长/声音残留；
- [ ] 网络断开/恢复有合理提示；
- [ ] release 包正常（R8 不混淆 Media3 必要类）。

### 性能

- [ ] 1080p 播放时 Flutter UI 仍流畅；
- [ ] 进度条 60fps 平滑，不因 4Hz 事件抖动；
- [ ] 没有每帧 MethodChannel 调用；
- [ ] 没有在 `build()` 里重建 PlatformView；
- [ ] 长时间播放不泄漏 Surface/Player。

---

## 9. 常见坑

1. **黑屏但有声音**
   - `PlayerView` 的 `surface_type` 不对；
   - 用了 Texture Layer 却放了 `SurfaceView`；
   - Surface 释放顺序错误；
   - 页面背景/层级遮挡。

2. **Flutter 控件被视频盖住**
   - 用了 `SurfaceView` 且合成模式不对；
   - 改用 Hybrid Composition（`PlatformViewLink + AndroidViewSurface`）；
   - 或改用 `texture_view`。

3. **圆角/裁剪无效**
   - `SurfaceView` 不受 Flutter `ClipRRect` 影响；
   - 用 `TextureView`，或设计上不要圆角。

4. **退出页面还在播**
   - 只取消了 Dart 订阅，没有释放原生 ExoPlayer；
   - `PlatformView.dispose()` 没调用 `release()`；
   - `onPause` 没暂停。

5. **进度条一跳一跳**
   - 直接每 250ms 用原生位置刷新 UI；
   - 没做本地插值；
   - 正确做法见 4.8。

6. **seek 后进度条回跳**
   - 旧的原生位置事件在 seek 后到达；
   - 做 300ms 抑制或 `seekEpoch`。

7. **播放/暂停图标不对**
   - 用 `isPlaying` 判断按钮，缓冲时变成“播放”；
   - 应该用 `playWhenReady` 判断意图，`isBuffering` 单独转圈。

8. **Activity 旋转后播放器重建**
   - 检查 Manifest 的 `configChanges`；
   - 不要用 `Navigator.push` 做全屏；
   - 不要在旋转时重建 `NativeVideoView`。

9. **HTTP 地址黑屏/报错**
   - Android 9+ 默认禁止明文；
   - 开发期临时放开，生产用 HTTPS。

10. **Flutter assets 里的视频播不了**
    - ExoPlayer 不直接认识 Flutter asset 路径；
    - 先复制到 cache 文件，或用 `AssetDataSource`；MVP 建议先用网络 URL。

11. **HLS 播不了**
    - 没加 `media3-exoplayer-hls`；
    - URL 无扩展名时没设置 MIME 类型。

12. **release 包崩溃**
    - R8/混淆；
    - 用 Media3 自带 consumer rules，必要时补 keep 规则；
    - release 模式真机验证。

---

## 10. 方案边界与后续演进

### 本方案适合

- 单个视频播放页；
- 播放网络 MP4 / HLS；
- 自定义 Flutter 控制条；
- 需要原生 Kotlin 播放核心；
- 需要后续加 DRM、字幕、轨选择。

### 本方案暂不覆盖

- 列表内多个视频同时播放/自动播放；
- 画中画；
- 后台音频/锁屏控制；
- 离线下载；
- 视频编辑/滤镜；
- 投屏；
- 直播低延迟优化。

### 后续如果要做“视频像普通 Flutter 图层”

评估 **TextureRegistry + SurfaceProducer**：

- 原生创建 `SurfaceProducer`，把 `surface` 交给 ExoPlayer；
- Flutter 用 `Texture(textureId: ...)` 显示；
- 优点：可做任意变换、圆角、滤镜、截图；
- 代价：要自己管理 surface 尺寸、生命周期、内存释放，复杂度明显高于 PlatformView。

在没有明确需求前，不要提前上这条路。

---

## 11. 参考资料

- Flutter 官方：Hosting native Android views（PlatformView / Hybrid Composition / HCPP）  
  https://docs.flutter.dev/platform-integration/android/platform-views
- Flutter 官方：Platform channels  
  https://docs.flutter.dev/platform-integration/platform-channels
- AndroidX Media3 版本页  
  https://developer.android.com/jetpack/androidx/releases/media3
- Media3 ExoPlayer 官方指南  
  https://developer.android.com/media/media3/exoplayer
- Media3 `PlayerView` / `Player` API  
  https://developer.android.com/reference/androidx/media3/ui/PlayerView  
  https://developer.android.com/reference/androidx/media3/common/Player

---

## 12. 附：最小落地顺序（给新手的检查表）

1. `flutter doctor` 全绿。
2. 创建工程，跑通空页面。
3. 加 Media3 依赖，Gradle sync 成功。
4. 写死一个测试 MP4，原生 `PlayerView` 能出画面。
5. 加 `play/pause` 两个 MethodChannel 命令。
6. 加 `seekTo/setSpeed`。
7. 加 EventChannel 状态快照。
8. Flutter 控制条接真实状态。
9. 加缓冲/错误/结束/重播。
10. 加全屏、后台暂停、释放。
11. 真机 + release 包回归。
12. 再考虑 HLS/DRM/字幕/多播放器。

**不要一开始就做插件化、多播放器、Pigeon、Texture 渲染。** 先把“一个视频、一个页面、一个 ExoPlayer、两个通道”跑通，这是整个方案的主干。
