package com.ligament.twofa.authenticator

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.Person

/**
 * Фоновая служба активного VoIP-вызова и фонового ожидания входящих вызовов/2FA.
 * Гарантирует непрерывность аудиопотока и удержание WebSocket-соединения при сворачивании
 * приложения или выключении экрана в соответствии с политиками Android 14+ FGS.
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

        fun startStandby(context: Context) {
            try {
                val intent = Intent(context, CallForegroundService::class.java).apply {
                    action = ACTION_START_STANDBY
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Exception) {}
        }

        fun stopService(context: Context) {
            try {
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
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Exception) {}
        }

        fun stopCall(context: Context, keepStandby: Boolean = true) {
            if (keepStandby) {
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
        val action = intent?.action ?: ACTION_START_STANDBY
        if (action == ACTION_STOP_SERVICE) {
            releaseLocks()
            stopSelf()
            return START_NOT_STICKY
        }

        acquireLocks()
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

        if (action == ACTION_START_STANDBY || action == ACTION_STOP_CALL) {
            val standbyNotification = NotificationCompat.Builder(this, STANDBY_CHANNEL_ID)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle("Ligament 2FA")
                .setContentText("Ожидание защищённых вызовов и уведомлений")
                .setOngoing(true)
                .setSilent(true)
                .setPriority(NotificationCompat.PRIORITY_MIN)
                .setContentIntent(mainPendingIntent)
                .build()

            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(
                        NOTIFICATION_ID,
                        standbyNotification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                    )
                } else {
                    startForeground(NOTIFICATION_ID, standbyNotification)
                }
            } catch (_: Exception) {}
            return START_STICKY
        }

        val uuid = intent?.getStringExtra(EXTRA_UUID) ?: ""
        val callerName = intent?.getStringExtra(EXTRA_CALLER_NAME) ?: "Ligament 2FA"

        val declinePendingIntent = CallActionReceiver.createDeclinePendingIntent(this, uuid)

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Идет защищенный звонок")
            .setContentText(callerName)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setContentIntent(mainPendingIntent)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Завершить",
                declinePendingIntent
            )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val person = Person.Builder().setName(callerName).setImportant(true).build()
            builder.setStyle(NotificationCompat.CallStyle.forOngoingCall(person, declinePendingIntent))
        }

        val notification = builder.build()

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                )
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) {}

        return START_STICKY
    }

    override fun onDestroy() {
        releaseLocks()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
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
