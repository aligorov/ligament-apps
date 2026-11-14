package com.ligament.twofa.authenticator

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * Фоновая служба активного VoIP-вызова и фонового ожидания входящих вызовов/2FA.
 * Гарантирует непрерывность аудиопотока и удержание WebSocket-соединения при сворачивании
 * приложения или выключении экрана в соответствии с политиками Android 12–15 FGS.
 */
class CallForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "ligament_active_call_channel"
        const val STANDBY_CHANNEL_ID = "ligament_bg_standby_channel"
        const val NOTIFICATION_ID = 3002

        const val ACTION_START_CALL = "com.ligament.twofa.authenticator.ACTION_START_CALL"
        const val ACTION_STOP_CALL = "com.ligament.twofa.authenticator.ACTION_STOP_CALL"
        const val ACTION_START_STANDBY = "com.ligament.twofa.authenticator.ACTION_START_STANDBY"
        const val ACTION_STOP_SERVICE = "com.ligament.twofa.authenticator.ACTION_STOP_SERVICE"

        const val EXTRA_UUID = "extra_uuid"
        const val EXTRA_CALLER_NAME = "extra_caller_name"

        @Volatile
        var isServiceRunning: Boolean = false

        private fun isAppInForeground(context: Context): Boolean {
            return try {
                val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return false
                val processes = am.runningAppProcesses ?: return false
                val myUid = context.applicationInfo.uid
                processes.any {
                    it.uid == myUid &&
                        it.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
                }
            } catch (_: Exception) {
                false
            }
        }

        fun startStandby(context: Context) {
            try {
                // На Android 12+ (API 31+) запуск нового FGS типа dataSync из фона запрещён
                // (ForegroundServiceStartNotAllowedException). Запускаем только если служба
                // уже работает (перевод из звонка в standby) или приложение на переднем плане.
                if (!isServiceRunning && !isAppInForeground(context)) {
                    return
                }
                val intent = Intent(context, CallForegroundService::class.java).apply {
                    action = ACTION_START_STANDBY
                }
                if (isServiceRunning || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                    context.startService(intent)
                } else {
                    context.startForegroundService(intent)
                }
            } catch (_: Exception) {}
        }

        fun stopService(context: Context) {
            try {
                if (!isServiceRunning) return
                val intent = Intent(context, CallForegroundService::class.java).apply {
                    action = ACTION_STOP_SERVICE
                }
                context.stopService(intent)
            } catch (_: Exception) {}
        }

        fun startCall(context: Context, uuid: String, callerName: String) {
            try {
                val intent = Intent(context, CallForegroundService::class.java).apply {
                    action = ACTION_START_CALL
                    putExtra(EXTRA_UUID, uuid)
                    putExtra(EXTRA_CALLER_NAME, callerName)
                }
                if (isServiceRunning || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                    context.startService(intent)
                } else {
                    context.startForegroundService(intent)
                }
            } catch (_: Exception) {}
        }

        fun stopCall(context: Context, keepStandby: Boolean = true) {
            if (keepStandby && (isServiceRunning || isAppInForeground(context))) {
                startStandby(context)
            } else {
                stopService(context)
            }
        }
    }

    private var cpuWakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createNotificationChannels()

        val mainIntent = Intent(this, MainActivity::class.java).apply {
            this.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val mainPendingIntent = PendingIntent.getActivity(
            this,
            0,
            mainIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val standbyNotification = NotificationCompat.Builder(this, STANDBY_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Ligament 2FA")
            .setContentText("Ожидание защищённых вызовов и уведомлений")
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setContentIntent(mainPendingIntent)
            .build()

        val action = intent?.action ?: ACTION_START_STANDBY
        if (action == ACTION_STOP_SERVICE) {
            if (!isServiceRunning) {
                startForegroundStandby(standbyNotification)
            }
            releaseLocks()
            stopForegroundCompat()
            isServiceRunning = false
            stopSelf()
            return START_NOT_STICKY
        }

        if (action == ACTION_START_STANDBY || action == ACTION_STOP_CALL) {
            // В режиме ожидания освобождаем CPU/Wi-Fi блокировки, чтобы не разряжать батарею
            releaseLocks()
            if (startForegroundStandby(standbyNotification)) {
                isServiceRunning = true
                return START_STICKY
            }
            isServiceRunning = false
            stopSelf()
            return START_NOT_STICKY
        }

        // Захватываем WakeLock и WifiLock только на время активного звонка
        acquireLocks()

        val uuid = intent?.getStringExtra(EXTRA_UUID) ?: ""
        val callerName = intent?.getStringExtra(EXTRA_CALLER_NAME)?.takeIf { it.isNotBlank() } ?: "Ligament 2FA"
        val declinePendingIntent = CallActionReceiver.createDeclinePendingIntent(this, uuid)

        // Используем стандартный NotificationCompat.Builder без CallStyle.forOngoingCall:
        // на Android 12–15 CallStyle для активного звонка требует строго FGS типа phoneCall
        // с активным TelecomConnection / ROLE_DIALER, иначе NotificationManagerService
        // выбрасывает IllegalArgumentException / SecurityException.
        val callNotification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Идет защищенный звонок")
            .setContentText(callerName)
            .setOngoing(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(mainPendingIntent)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Завершить",
                declinePendingIntent
            )
            .build()

        if (startForegroundWithFallback(callNotification)) {
            isServiceRunning = true
            return START_STICKY
        }

        // Если ни один тип не прошёл, пробуем базовый standby перед остановкой
        if (startForegroundStandby(standbyNotification)) {
            isServiceRunning = true
            return START_STICKY
        }

        releaseLocks()
        isServiceRunning = false
        stopSelf()
        return START_NOT_STICKY
    }

    private fun startForegroundStandby(notification: Notification): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (_: Exception) {
            try {
                startForeground(NOTIFICATION_ID, notification)
                true
            } catch (_: Exception) {
                false
            }
        }
    }

    private fun startForegroundWithFallback(notification: Notification): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return try {
                startForeground(NOTIFICATION_ID, notification)
                true
            } catch (_: Exception) {
                false
            }
        }
        val types = mutableListOf<Int>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && hasMicPermission()) {
            types.add(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        }
        types.add(ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        types.add(ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL)
        for (t in types) {
            try {
                startForeground(NOTIFICATION_ID, notification, t)
                return true
            } catch (_: Exception) {}
        }
        return try {
            startForeground(NOTIFICATION_ID, notification)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun hasMicPermission(): Boolean =
        checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun stopForegroundCompat() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (_: Exception) {}
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        releaseLocks()
        stopForegroundCompat()
        isServiceRunning = false
        stopSelf(startId)
    }

    override fun onDestroy() {
        isServiceRunning = false
        releaseLocks()
        stopForegroundCompat()
        super.onDestroy()
    }

    private fun acquireLocks() {
        try {
            if (cpuWakeLock?.isHeld != true) {
                val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
                cpuWakeLock = pm?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ligament:bg_standby_cpu")?.apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
            if (wifiLock?.isHeld != true) {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                @Suppress("DEPRECATION")
                val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifiLock = wm?.createWifiLock(mode, "ligament:bg_standby_wifi")?.apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        } catch (_: Exception) {}
    }

    private fun releaseLocks() {
        try {
            if (cpuWakeLock?.isHeld == true) {
                cpuWakeLock?.release()
            }
        } catch (_: Exception) {}
        cpuWakeLock = null

        try {
            if (wifiLock?.isHeld == true) {
                wifiLock?.release()
            }
        } catch (_: Exception) {}
        wifiLock = null
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            val callChannel = NotificationChannel(
                CHANNEL_ID,
                "Активный звонок Ligament",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Постоянное системное уведомление во время активного разговора"
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
            }
            nm.createNotificationChannel(callChannel)

            val standbyChannel = NotificationChannel(
                STANDBY_CHANNEL_ID,
                "Фоновая связь Ligament",
                NotificationManager.IMPORTANCE_MIN
            ).apply {
                description = "Поддержание защищённого канала для приёма входящих вызовов в фоне"
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
            }
            nm.createNotificationChannel(standbyChannel)
        }
    }
}
