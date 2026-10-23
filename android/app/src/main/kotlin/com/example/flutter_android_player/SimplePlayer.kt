package com.example.flutter_android_player

import android.app.Activity
import android.app.PendingIntent
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * ExoPlayer 播放核心 + Flutter 控制命令 + 持续状态回传 + 系统媒体会话。
 */
class SimplePlayer(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private var released = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    private val contentIntent: PendingIntent = PendingIntent.getActivity(
        activity,
        0,
        Intent(activity, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    val player: ExoPlayer = ExoPlayer.Builder(activity.applicationContext).build().apply {
        setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(),
            true,
        )
        setHandleAudioBecomingNoisy(true)
        playWhenReady = true
        setMediaItem(
            MediaItem.Builder()
                .setUri("asset:///demo.mp4")
                .setMediaMetadata(
                    MediaMetadata.Builder()
                        .setTitle("Demo Video")
                        .setArtist("本地视频")
                        .build(),
                )
                .build(),
        )
        prepare()
    }

    private val mediaSession: MediaSession = MediaSession.Builder(activity, player)
        .setSessionActivity(contentIntent)
        .build()

    private val notificationManager =
        MediaNotificationManager(activity, mediaSession, player)

    private val methodChannel = MethodChannel(messenger, COMMANDS).apply {
        setMethodCallHandler(this@SimplePlayer)
    }

    private val eventChannel = EventChannel(messenger, EVENTS).apply {
        setStreamHandler(this@SimplePlayer)
    }

    private val listener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) {
            emitState()
            notificationManager.update()
        }

        override fun onPlayerError(error: PlaybackException) {
            Log.e("SimplePlayer", "Playback error: ${error.errorCode}", error)
            eventSink?.success(
                mapOf(
                    "type" to "error",
                    "errorCode" to error.errorCode,
                    "message" to (error.message ?: "Playback error"),
                ),
            )
            emitState()
        }
    }

    private val ticker = object : Runnable {
        override fun run() {
            if (released || eventSink == null) return
            emitState()
            mainHandler.postDelayed(this, 250L)
        }
    }

    init {
        currentPlayer = player
        player.addListener(listener)
        notificationManager.update()
        notificationManager.notification?.let {
            PlaybackService.start(activity, it)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (released) {
            result.error("RELEASED", "Player already released", null)
            return
        }

        try {
            when (call.method) {
                "play" -> play()
                "pause" -> pause()
                "seekTo" -> seekTo(
                    call.argument<Number>("positionMs")?.toLong() ?: 0L,
                )
                "setSpeed" -> setSpeed(
                    call.argument<Number>("speed")?.toFloat() ?: 1f,
                )
                "setVolume" -> setVolume(
                    call.argument<Number>("volume")?.toFloat() ?: 1f,
                )
                "getState" -> {
                    result.success(stateMap())
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
        emitState()
        mainHandler.removeCallbacks(ticker)
        mainHandler.post(ticker)
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        mainHandler.removeCallbacks(ticker)
    }

    private fun play() {
        if (player.playbackState == Player.STATE_ENDED) {
            player.seekTo(0L)
        }
        player.play()
        Log.d("SimplePlayer", "play()")
    }

    fun pause() {
        if (released) return
        player.pause()
        Log.d("SimplePlayer", "pause()")
    }

    private fun seekTo(positionMs: Long) {
        val duration = player.duration
        val max = if (duration == C.TIME_UNSET) Long.MAX_VALUE else duration
        val target = positionMs.coerceIn(0L, max)
        player.seekTo(target)
        Log.d("SimplePlayer", "seekTo($target)")
    }

    private fun setSpeed(speed: Float) {
        val target = speed.coerceIn(0.25f, 4f)
        player.setPlaybackSpeed(target)
        Log.d("SimplePlayer", "setSpeed($target)")
    }

    private fun setVolume(volume: Float) {
        val target = volume.coerceIn(0f, 1f)
        player.volume = target
        Log.d("SimplePlayer", "setVolume($target)")
    }

    private fun emitState() {
        if (released) return
        eventSink?.success(stateMap())
    }

    private fun stateMap(): Map<String, Any?> {
        val duration = player.duration.let {
            if (it == C.TIME_UNSET) 0L else it
        }
        val buffered = player.bufferedPosition.let {
            if (it == C.TIME_UNSET) 0L else it
        }

        return mapOf(
            "type" to "state",
            "status" to when (player.playbackState) {
                Player.STATE_IDLE -> "idle"
                Player.STATE_BUFFERING -> "buffering"
                Player.STATE_READY -> "ready"
                Player.STATE_ENDED -> "ended"
                else -> "idle"
            },
            "positionMs" to player.currentPosition.coerceAtLeast(0L),
            "durationMs" to duration,
            "bufferedMs" to buffered.coerceAtLeast(0L),
            "isPlaying" to player.isPlaying,
            "playWhenReady" to player.playWhenReady,
            "speed" to player.playbackParameters.speed.toDouble(),
            "volume" to player.volume.toDouble(),
        )
    }

    fun release() {
        if (released) return
        released = true

        mainHandler.removeCallbacks(ticker)
        player.removeListener(listener)
        eventSink = null
        PlaybackService.stop(activity)
        notificationManager.cancel()
        mediaSession.release()
        player.release()
        if (currentPlayer === player) {
            currentPlayer = null
        }

        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        Log.d("SimplePlayer", "release()")
    }

    companion object {
        const val COMMANDS = "demo/player_commands"
        const val EVENTS = "demo/player_events"

        var currentPlayer: ExoPlayer? = null
            private set
    }
}
