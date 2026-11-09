package com.safenet.safenet_collector

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * Foreground service chỉ để giữ process sống và giữ CPU thức (PARTIAL_WAKE_LOCK).
 * Việc đọc cảm biến và ghi file nằm hoàn toàn ở Dart main isolate.
 */
class LoggerService : Service() {

    companion object {
        private const val TAG = "SafeNetLogger"
        const val CHANNEL_ID = "safenet_logger"
        const val NOTIFICATION_ID = 1001
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"

        /** true sau khi startForeground thành công, false sau onDestroy. */
        @Volatile
        var running: Boolean = false
            private set

        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Ghi dữ liệu cảm biến",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Thông báo thường trực khi SafeNet Collector đang ghi"
                setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }

        fun buildNotification(context: Context, title: String, text: String): Notification {
            ensureChannel(context)
            val openIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pending = PendingIntent.getActivity(
                context,
                0,
                openIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            return builder
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle(title)
                .setContentText(text)
                .setContentIntent(pending)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .build()
        }

        /** Chỉ cập nhật nội dung notification khi service đang chạy. */
        fun updateNotification(context: Context, title: String, text: String) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIFICATION_ID, buildNotification(context, title, text))
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "SafeNet Collector"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Đang ghi dữ liệu"
        val notification = buildNotification(this, title, text)

        if (running) {
            // Đã là foreground service: chỉ cập nhật notification.
            updateNotification(this, title, text)
            return START_NOT_STICKY
        }

        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.e(TAG, "startForeground thất bại", e)
            stopSelf()
            return START_NOT_STICKY
        }

        acquireWakeLock()
        running = true
        return START_NOT_STICKY
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SafeNet:LoggerWakeLock").apply {
                setReferenceCounted(false)
                // Giới hạn 24 giờ để tránh giữ CPU vô hạn nếu có sự cố.
                acquire(24L * 60 * 60 * 1000)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Không lấy được wake lock", e)
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Người dùng vuốt bỏ app: Flutter engine đã chết, không còn gì để giữ.
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (e: Exception) {
            Log.e(TAG, "Lỗi khi nhả wake lock", e)
        }
        wakeLock = null
        super.onDestroy()
    }
}
