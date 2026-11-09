package com.safenet.safenet_collector

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    private var nativeTools: NativeTools? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nativeTools?.dispose()
        nativeTools = NativeTools(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onResume() {
        super.onResume()
        nativeTools?.uiVisible = true
    }

    override fun onPause() {
        nativeTools?.uiVisible = false
        super.onPause()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        val handled = nativeTools?.onRequestPermissionsResult(requestCode, grantResults) ?: false
        if (!handled) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }

    override fun onDestroy() {
        // Flutter engine (và việc ghi dữ liệu) chết cùng Activity: không giữ service vô ích.
        if (!isChangingConfigurations) {
            nativeTools?.stopServiceSilently()
        }
        nativeTools?.dispose()
        nativeTools = null
        super.onDestroy()
    }
}
