package com.example.flutter_android_player

import android.content.Context
import android.graphics.Color
import android.view.LayoutInflater
import android.view.View
import android.widget.FrameLayout
import androidx.media3.common.Player
import androidx.media3.ui.PlayerView
import io.flutter.plugin.platform.PlatformView

/**
 * Step 1：把原生 PlayerView 作为 PlatformView 暴露给 Flutter。
 */
class VideoPlatformView(
    context: Context,
    private val simplePlayer: SimplePlayer,
) : PlatformView {

    private val root = FrameLayout(context).apply {
        setBackgroundColor(Color.BLACK)
    }

    private val playerView: PlayerView = (
        LayoutInflater.from(context)
            .inflate(R.layout.player_view, root, false) as PlayerView
        ).apply {
        useController = false
        isClickable = false
        player = simplePlayer.player
    }

    private val screenOnListener = object : Player.Listener {
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            playerView.keepScreenOn = isPlaying
        }
    }

    init {
        root.addView(
            playerView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        playerView.keepScreenOn = simplePlayer.player.isPlaying
        simplePlayer.player.addListener(screenOnListener)
    }

    override fun getView(): View = root

    override fun dispose() {
        simplePlayer.player.removeListener(screenOnListener)
        playerView.keepScreenOn = false
        playerView.player = null
        // 不在这里暂停播放器：App 退到后台时视频 Surface 会解绑，
        // 但 ExoPlayer 仍需继续后台播放，由前台服务保活。
    }
}
