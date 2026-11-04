package com.ligament.twofa.authenticator

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.Person

/**
 * Фоновая служба активного VoIP-вызова.
 * Гарантирует непрерывность аудиопотока и доступ к микрофону при сворачивании
 * приложения или выключении экрана в соответствии с политиками Android 14+ FGS.
 */
class CallForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "ligament_active_call_channel"
        const val NOTIFICATION_ID = 3002

        const val ACTION_START_CALL = "com.ligament.twofa.authenticator.ACTION_START_CALL"
        const val ACTION_STOP_CALL = "com.ligament.twofa.authenticator.ACTION_STOP_CALL"

        const val EXTRA_UUID = "extra_uuid"
        const val EXTRA_CALLER_NAME = "extra_caller_name"

        fun startCall(context: Context, uuid: String, callerName: String) {
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
        }

        fun stopCall(context: Context) {
            val intent = Intent(context, CallForegroundService::class.java).apply {
                action = ACTION_STOP_CALL
            }
            context.stopService(intent)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP_CALL) {
            stopSelf()
            return START_NOT_STICKY
        }

        val uuid = intent?.getStringExtra(EXTRA_UUID) ?: ""
        val callerName = intent?.getStringExtra(EXTRA_CALLER_NAME) ?: "Ligament 2FA"

        createNotificationChannel()

        val mainIntent = Intent(this, MainActivity::class.java).apply {
            this.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val mainPendingIntent = PendingIntent.getActivity(
            this,
            0,
            mainIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

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

        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Активный звонок Ligament",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Постоянное системное уведомление во время активного разговора"
                setShowBadge(false)
            }
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(channel)
        }
    }
}
