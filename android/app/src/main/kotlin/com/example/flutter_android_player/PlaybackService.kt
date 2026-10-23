package com.example.flutter_android_player

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Demo 用的前台服务：只负责让播放进程在后台存活，并承载媒体通知。
 * 播放器仍由 SimplePlayer/ExoPlayer 持有；退出 Activity 时会停止服务并释放播放器。
 *
 * 生产环境更推荐 MediaSessionService 持有播放器，并由服务统一管理生命周期。
 */
class PlaybackService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = currentNotification
        if (notification == null) {
            Log.w("PlaybackService", "No notification, stop service")
            stopSelf()
            return START_NOT_STICKY
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    MediaNotificationManager.NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
                )
            } else {
                startForeground(MediaNotificationManager.NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.e("PlaybackService", "startForeground failed", e)
            stopSelf()
            return START_NOT_STICKY
        }

        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    companion object {
        var currentNotification: Notification? = null

        fun start(context: Context, notification: Notification) {
            currentNotification = notification
            ContextCompat.startForegroundService(
                context,
                Intent(context, PlaybackService::class.java),
            )
        }

        fun stop(context: Context) {
            currentNotification = null
            context.stopService(Intent(context, PlaybackService::class.java))
        }
    }
}
