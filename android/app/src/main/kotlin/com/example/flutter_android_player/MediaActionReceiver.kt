package com.example.flutter_android_player

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 媒体通知上的播放/暂停按钮。系统媒体空间本身由 MediaSession 直接控制播放器。
 */
class MediaActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_TOGGLE) return

        val player = SimplePlayer.currentPlayer ?: return
        if (player.isPlaying) {
            player.pause()
        } else {
            player.play()
        }
    }

    companion object {
        const val ACTION_TOGGLE = "com.example.flutter_android_player.MEDIA_TOGGLE"
    }
}
