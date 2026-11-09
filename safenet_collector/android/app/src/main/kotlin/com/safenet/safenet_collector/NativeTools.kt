package com.safenet.safenet_collector

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedInputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.OutputStream
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * Xử lý MethodChannel `safenet/native`. Mọi lỗi đều trả về result.error, không ném ra ngoài.
 */
class NativeTools(
    private val activity: Activity,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "safenet/native"
        private const val TAG = "SafeNetNative"
        private const val REQ_NOTIFICATIONS = 4101
        private const val REQ_STORAGE = 4102
        private const val EXPORT_SUBDIR = "SafeNetCollector"
    }

    private val appContext: Context = activity.applicationContext
    private val channel = MethodChannel(messenger, CHANNEL)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    /** MainActivity cập nhật cờ này trong onResume/onPause. */
    @Volatile
    var uiVisible: Boolean = false

    // ---- TextToSpeech ----
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var ttsFailed = false
    private var pendingSpeech: String? = null

    // ---- Xin quyền ----
    private val pendingPermission = HashMap<Int, (Boolean) -> Unit>()

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "startService" -> startService(call, result)
                "stopService" -> stopService(result)
                "speak" -> speak(call, result)
                "deviceInfo" -> result.success(deviceInfo())
                "status" -> result.success(status())
                "storageDir" -> storageDir(result)
                "requestNotificationPermission" -> requestNotificationPermission(result)
                "requestIgnoreBatteryOptimizations" -> requestIgnoreBatteryOptimizations(result)
                "openAppSettings" -> openAppSettings(result)
                "exportZip" -> exportZip(call, result)
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Lỗi khi xử lý ${call.method}", e)
            result.error("NATIVE_ERROR", "${call.method}: ${e.message ?: e.javaClass.simpleName}", null)
        }
    }

    // ------------------------------------------------------------------
    // Service
    // ------------------------------------------------------------------

    private fun startService(call: MethodCall, result: MethodChannel.Result) {
        val title = call.argument<String>("title") ?: "SafeNet Collector"
        val text = call.argument<String>("text") ?: "Đang ghi dữ liệu"

        if (LoggerService.running) {
            // Đã chạy: chỉ cập nhật notification (an toàn cả khi app ở nền).
            LoggerService.updateNotification(appContext, title, text)
            result.success(true)
            return
        }
        if (!uiVisible) {
            result.error(
                "NOT_VISIBLE",
                "Chỉ được khởi động service khi giao diện đang hiển thị",
                null
            )
            return
        }
        val intent = Intent(appContext, LoggerService::class.java).apply {
            putExtra(LoggerService.EXTRA_TITLE, title)
            putExtra(LoggerService.EXTRA_TEXT, text)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                appContext.startForegroundService(intent)
            } else {
                appContext.startService(intent)
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("SERVICE_START_FAILED", "Không khởi động được service: ${e.message}", null)
        }
    }

    private fun stopService(result: MethodChannel.Result) {
        val stopped = appContext.stopService(Intent(appContext, LoggerService::class.java))
        result.success(stopped)
    }

    /** Gọi từ MainActivity.onDestroy. */
    fun stopServiceSilently() {
        try {
            appContext.stopService(Intent(appContext, LoggerService::class.java))
        } catch (e: Exception) {
            Log.e(TAG, "stopService", e)
        }
    }

    // ------------------------------------------------------------------
    // TextToSpeech
    // ------------------------------------------------------------------

    private fun speak(call: MethodCall, result: MethodChannel.Result) {
        val text = call.argument<String>("text")
        if (text.isNullOrBlank()) {
            result.error("BAD_ARGS", "Thiếu nội dung cần đọc", null)
            return
        }
        if (ttsFailed) {
            result.error("TTS_UNAVAILABLE", "Không khởi tạo được TextToSpeech trên máy này", null)
            return
        }
        val engine = tts
        if (engine == null || !ttsReady) {
            pendingSpeech = text
            if (engine == null) initTts()
            result.success("pending")
            return
        }
        val code = engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, "safenet_${System.nanoTime()}")
        if (code == TextToSpeech.SUCCESS) {
            result.success("ok")
        } else {
            result.error("TTS_SPEAK_FAILED", "TextToSpeech.speak trả về lỗi $code", null)
        }
    }

    private fun initTts() {
        tts = TextToSpeech(appContext) { status ->
            mainHandler.post {
                val engine = tts
                if (status != TextToSpeech.SUCCESS || engine == null) {
                    ttsFailed = true
                    Log.e(TAG, "Khởi tạo TTS thất bại: $status")
                    return@post
                }
                val vi = Locale.forLanguageTag("vi-VN")
                val avail = try {
                    engine.isLanguageAvailable(vi)
                } catch (e: Exception) {
                    TextToSpeech.LANG_NOT_SUPPORTED
                }
                if (avail >= TextToSpeech.LANG_AVAILABLE) {
                    engine.setLanguage(vi)
                } else {
                    engine.setLanguage(Locale.getDefault())
                }
                ttsReady = true
                pendingSpeech?.let {
                    engine.speak(it, TextToSpeech.QUEUE_FLUSH, null, "safenet_pending")
                }
                pendingSpeech = null
            }
        }
    }

    // ------------------------------------------------------------------
    // Thông tin máy / trạng thái
    // ------------------------------------------------------------------

    private fun deviceInfo(): Map<String, Any?> {
        val info = HashMap<String, Any?>()
        info["manufacturer"] = Build.MANUFACTURER
        info["model"] = Build.MODEL
        info["sdkInt"] = Build.VERSION.SDK_INT
        info["release"] = Build.VERSION.RELEASE
        info["appVersion"] = appVersion()

        val sm = appContext.getSystemService(Context.SENSOR_SERVICE) as SensorManager
        val acc = sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        info["accelerometer"] = if (acc == null) null else mapOf(
            "name" to acc.name,
            "vendor" to acc.vendor,
            "maxRange" to acc.maximumRange.toDouble(),
            "resolution" to acc.resolution.toDouble(),
            "minDelayUs" to acc.minDelay,
            "fifoMaxEventCount" to acc.fifoMaxEventCount
        )
        return info
    }

    private fun appVersion(): String {
        return try {
            val pm = appContext.packageManager
            val pi = if (Build.VERSION.SDK_INT >= 33) {
                pm.getPackageInfo(appContext.packageName, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(appContext.packageName, 0)
            }
            val code = if (Build.VERSION.SDK_INT >= 28) {
                pi.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                pi.versionCode.toLong()
            }
            "${pi.versionName}+$code"
        } catch (e: Exception) {
            "unknown"
        }
    }

    private fun status(): Map<String, Any?> {
        val bm = appContext.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        val pm = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
        val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val battery = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        return mapOf(
            "batteryPercent" to (if (battery in 0..100) battery else null),
            "screenOn" to pm.isInteractive,
            "ignoringBatteryOptimizations" to pm.isIgnoringBatteryOptimizations(appContext.packageName),
            "notificationsEnabled" to nm.areNotificationsEnabled(),
            "serviceRunning" to LoggerService.running
        )
    }

    private fun storageDir(result: MethodChannel.Result) {
        val dir = appContext.getExternalFilesDir(null)
        if (dir == null) {
            result.error("NO_STORAGE", "Không truy cập được bộ nhớ ngoài của app", null)
        } else {
            result.success(dir.absolutePath)
        }
    }

    // ------------------------------------------------------------------
    // Quyền & cài đặt
    // ------------------------------------------------------------------

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33) {
            val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            result.success(nm.areNotificationsEnabled())
            return
        }
        requestPermission(Manifest.permission.POST_NOTIFICATIONS, REQ_NOTIFICATIONS) { granted ->
            result.success(granted)
        }
    }

    private fun requestPermission(permission: String, requestCode: Int, callback: (Boolean) -> Unit) {
        if (activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            callback(true)
            return
        }
        if (pendingPermission.containsKey(requestCode)) {
            // Đang có yêu cầu chưa trả lời: hủy yêu cầu cũ.
            pendingPermission.remove(requestCode)?.invoke(false)
        }
        pendingPermission[requestCode] = callback
        activity.requestPermissions(arrayOf(permission), requestCode)
    }

    /** Gọi từ MainActivity.onRequestPermissionsResult. Trả về true nếu đã xử lý. */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        val callback = pendingPermission.remove(requestCode) ?: return false
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        try {
            callback(granted)
        } catch (e: Exception) {
            Log.e(TAG, "permission callback", e)
        }
        return true
    }

    private fun requestIgnoreBatteryOptimizations(result: MethodChannel.Result) {
        val pkg = appContext.packageName
        val pm = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (pm.isIgnoringBatteryOptimizations(pkg)) {
            result.success(true)
            return
        }
        try {
            @Suppress("BatteryLife")
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                .setData(Uri.parse("package:$pkg"))
            activity.startActivity(intent)
            result.success(false)
        } catch (e: Exception) {
            try {
                activity.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                result.success(false)
            } catch (e2: Exception) {
                result.error(
                    "NO_SETTINGS",
                    "Máy không có màn hình cài đặt tối ưu pin: ${e2.message}",
                    null
                )
            }
        }
    }

    private fun openAppSettings(result: MethodChannel.Result) {
        try {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.parse("package:${appContext.packageName}"))
            activity.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("NO_SETTINGS", "Không mở được trang cài đặt app: ${e.message}", null)
        }
    }

    // ------------------------------------------------------------------
    // Xuất ZIP
    // ------------------------------------------------------------------

    private fun exportZip(call: MethodCall, result: MethodChannel.Result) {
        val dirPath = call.argument<String>("dirPath")
        var zipName = call.argument<String>("zipName")
        if (dirPath.isNullOrBlank() || zipName.isNullOrBlank()) {
            result.error("BAD_ARGS", "Thiếu dirPath hoặc zipName", null)
            return
        }
        if (!zipName.endsWith(".zip", ignoreCase = true)) zipName += ".zip"
        val dir = File(dirPath)
        if (!dir.isDirectory) {
            result.error("NOT_FOUND", "Không tìm thấy thư mục: $dirPath", null)
            return
        }
        val name = zipName
        if (Build.VERSION.SDK_INT < 29) {
            requestPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE, REQ_STORAGE) { granted ->
                if (granted) {
                    runExport(dir, name, result)
                } else {
                    result.error(
                        "PERMISSION_DENIED",
                        "Cần quyền ghi bộ nhớ để lưu vào thư mục Download",
                        null
                    )
                }
            }
        } else {
            runExport(dir, name, result)
        }
    }

    private fun runExport(dir: File, zipName: String, result: MethodChannel.Result) {
        executor.execute {
            try {
                val shown = if (Build.VERSION.SDK_INT >= 29) {
                    exportViaMediaStore(dir, zipName)
                } else {
                    exportLegacy(dir, zipName)
                }
                mainHandler.post { result.success(shown) }
            } catch (e: Exception) {
                Log.e(TAG, "exportZip", e)
                mainHandler.post {
                    result.error("EXPORT_FAILED", "Xuất ZIP thất bại: ${e.message ?: e.javaClass.simpleName}", null)
                }
            }
        }
    }

    private fun exportViaMediaStore(dir: File, zipName: String): String {
        val resolver = appContext.contentResolver
        val relPath = Environment.DIRECTORY_DOWNLOADS + "/" + EXPORT_SUBDIR
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, zipName)
            put(MediaStore.MediaColumns.MIME_TYPE, "application/zip")
            put(MediaStore.MediaColumns.RELATIVE_PATH, relPath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("MediaStore không tạo được file")
        try {
            val out = resolver.openOutputStream(uri)
                ?: throw IllegalStateException("Không mở được luồng ghi MediaStore")
            out.use { zipDirectory(dir, it) }
            val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            resolver.update(uri, done, null, null)
        } catch (e: Exception) {
            try {
                resolver.delete(uri, null, null)
            } catch (_: Exception) {
            }
            throw e
        }
        // MediaStore có thể tự đổi tên nếu trùng, đọc lại tên thật.
        var finalName = zipName
        try {
            resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) finalName = c.getString(0) ?: zipName
            }
        } catch (_: Exception) {
        }
        return "Download/$EXPORT_SUBDIR/$finalName"
    }

    private fun exportLegacy(dir: File, zipName: String): String {
        @Suppress("DEPRECATION")
        val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        val target = File(downloads, EXPORT_SUBDIR)
        if (!target.exists() && !target.mkdirs()) {
            throw IllegalStateException("Không tạo được thư mục ${target.absolutePath}")
        }
        var file = File(target, zipName)
        var i = 1
        while (file.exists()) {
            file = File(target, zipName.removeSuffix(".zip") + " ($i).zip")
            i++
        }
        try {
            FileOutputStream(file).use { zipDirectory(dir, it) }
        } catch (e: Exception) {
            file.delete()
            throw e
        }
        return file.absolutePath
    }

    /** Nén [dir] (giữ tên thư mục gốc làm thư mục đầu tiên trong zip). */
    private fun zipDirectory(dir: File, out: OutputStream) {
        val base = dir.parentFile ?: dir
        ZipOutputStream(out).use { zos ->
            val buffer = ByteArray(64 * 1024)
            dir.walkTopDown().filter { it.isFile }.forEach { f ->
                val entryName = f.relativeTo(base).invariantSeparatorsPath
                zos.putNextEntry(ZipEntry(entryName).apply { time = f.lastModified() })
                BufferedInputStream(FileInputStream(f)).use { input ->
                    while (true) {
                        val n = input.read(buffer)
                        if (n <= 0) break
                        zos.write(buffer, 0, n)
                    }
                }
                zos.closeEntry()
            }
        }
    }

    // ------------------------------------------------------------------

    fun dispose() {
        channel.setMethodCallHandler(null)
        try {
            tts?.stop()
            tts?.shutdown()
        } catch (_: Exception) {
        }
        tts = null
        executor.shutdown()
        pendingPermission.clear()
    }
}
