package xyz.alxbkr.hum_flutter

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Android-only Flutter plugin that initializes `ndk-context` inside `hum_cpal`
 * with the process `JavaVM` and `Application` context so `cpal` (AAudio) can
 * query audio devices and open streams.
 */
class HumFlutterPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        nativeInitAndroidContext(binding.applicationContext)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}

    companion object {
        init {
            System.loadLibrary("hum_cpal")
        }

        @JvmStatic
        private external fun nativeInitAndroidContext(context: Context)
    }
}
