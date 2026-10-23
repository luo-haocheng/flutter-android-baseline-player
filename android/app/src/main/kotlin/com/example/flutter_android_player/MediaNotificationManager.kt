package com.example.flutter_android_player

import android.app.PendingIntent
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Activity
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.util.Log
import androidx.media3.common.Player
import androidx.media3.session.MediaSession

/**
 * 把 MediaSession 挂到系统媒体通知/媒体空间。
 * 真正的播放/暂停/seek 命令由 MediaSession 转发给 ExoPlayer。
 */
class MediaNotificationManager(
    private val activity: Activity,
    private val mediaSession: MediaSession,
    private val player: Player,
) {

    private val notificationManager =
        activity.getSystemService(NotificationManager::class.java)

    var notification: Notification? = null
        private set

    init {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "视频播放",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "本地视频播放控制"
                setShowBadge(false)
            }
            notificationManager.createNotificationChannel(channel)
        }
    }

    fun update() {
        val metadata = player.mediaMetadata
        val title = metadata.title?.toString() ?: "Demo Video"
        val playing = player.isPlaying
        val toggleLabel = if (playing) "暂停" else "播放"
        val toggleIcon = if (playing) {
            android.R.drawable.ic_media_pause
        } else {
            android.R.drawable.ic_media_play
        }

        val contentIntent = PendingIntent.getActivity(
            activity,
            0,
            Intent(activity, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val toggleIntent = PendingIntent.getBroadcast(
            activity,
            1,
            Intent(activity, MediaActionReceiver::class.java).apply {
                action = MediaActionReceiver.ACTION_TOGGLE
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(activity, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(activity)
        }

        val action = Notification.Action.Builder(
            Icon.createWithResource(activity, toggleIcon),
            toggleLabel,
            toggleIntent,
        ).build()

        val builtNotification = builder
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentText("本地视频")
            .setContentIntent(contentIntent)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(mediaSession.platformToken)
                    .setShowActionsInCompactView(0),
            )
            .addAction(action)
            .build()

        notification = builtNotification
        try {
            notificationManager.notify(NOTIFICATION_ID, builtNotification)
        } catch (e: SecurityException) {
            Log.w("MediaNotification", "Notification permission denied", e)
        }
    }

    fun cancel() {
        notification = null
        notificationManager.cancel(NOTIFICATION_ID)
    }

    companion object {
        private const val CHANNEL_ID = "demo_video_playback"
        const val NOTIFICATION_ID = 1001
    }
}
