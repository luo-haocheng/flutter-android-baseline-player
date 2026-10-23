package com.example.flutter_android_player

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    private var simplePlayer: SimplePlayer? = null
    private var windowControl: WindowControl? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQUEST_NOTIFICATION_PERMISSION,
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val player = SimplePlayer(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        simplePlayer = player

        windowControl = WindowControl(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )

        flutterEngine.platformViewsController.registry.registerViewFactory(
            "native_video_view",
            VideoViewFactory(player),
        )
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        windowControl?.dispose()
        windowControl = null
        simplePlayer?.release()
        simplePlayer = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        windowControl?.dispose()
        windowControl = null
        simplePlayer?.release()
        simplePlayer = null
        super.onDestroy()
    }

    companion object {
        private const val REQUEST_NOTIFICATION_PERMISSION = 1001
    }
}
