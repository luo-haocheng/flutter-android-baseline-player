package com.example.flutter_android_player

import android.app.Activity
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 只调整当前 Activity 窗口的亮度，不修改系统亮度，因此不需要 WRITE_SETTINGS 权限。
 */
class WindowControl(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL).apply {
        setMethodCallHandler(this@WindowControl)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getBrightness" -> result.success(currentBrightness())
            "setBrightness" -> {
                val value = call.argument<Number>("value")?.toFloat() ?: 0.5f
                setBrightness(value)
                result.success(null)
            }
            "isEmulator" -> result.success(isEmulator())
            else -> result.notImplemented()
        }
    }

    private fun isEmulator(): Boolean {
        return Build.FINGERPRINT.startsWith("generic") ||
            Build.FINGERPRINT.contains("emulator", ignoreCase = true) ||
            Build.MODEL.contains("google_sdk", ignoreCase = true) ||
            Build.MODEL.contains("emulator", ignoreCase = true) ||
            Build.MODEL.contains("Android SDK built for", ignoreCase = true) ||
            Build.HARDWARE.contains("goldfish", ignoreCase = true) ||
            Build.HARDWARE.contains("ranchu", ignoreCase = true) ||
            Build.PRODUCT.contains("sdk", ignoreCase = true)
    }

    private fun currentBrightness(): Double {
        val attrValue = activity.window.attributes.screenBrightness
        val value = if (attrValue >= 0f) {
            attrValue
        } else {
            Settings.System.getInt(
                activity.contentResolver,
                Settings.System.SCREEN_BRIGHTNESS,
                128,
            ) / 255f
        }
        return value.coerceIn(0.01f, 1f).toDouble()
    }

    private fun setBrightness(value: Float) {
        val target = value.coerceIn(0.01f, 1f)
        val attributes = activity.window.attributes
        attributes.screenBrightness = target
        activity.window.attributes = attributes
        Log.d("WindowControl", "setBrightness($target)")
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    companion object {
        const val CHANNEL = "demo/window_controls"
    }
}
