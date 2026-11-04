package com.ligament.twofa.authenticator

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Приёмник системных действий уведомления звонка (Ответить / Отклонить / Завершить).
 * Обеспечивает мгновенный отклик при нажатии аппаратных кнопок уведомления в шторке
 * или на экране блокировки без необходимости полного холодного запуска UI.
 */
class CallActionReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_ACCEPT_CALL = "com.ligament.twofa.authenticator.ACTION_ACCEPT_CALL"
        const val ACTION_DECLINE_CALL = "com.ligament.twofa.authenticator.ACTION_DECLINE_CALL"
        const val EXTRA_UUID = "extra_uuid"

        fun createAcceptPendingIntent(context: Context, uuid: String): PendingIntent {
            val intent = Intent(context, CallActionReceiver::class.java).apply {
                action = ACTION_ACCEPT_CALL
                putExtra(EXTRA_UUID, uuid)
            }
            return PendingIntent.getBroadcast(
                context,
                uuid.hashCode() + 1,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        fun createDeclinePendingIntent(context: Context, uuid: String): PendingIntent {
            val intent = Intent(context, CallActionReceiver::class.java).apply {
                action = ACTION_DECLINE_CALL
                putExtra(EXTRA_UUID, uuid)
            }
            return PendingIntent.getBroadcast(
                context,
                uuid.hashCode() + 2,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        val uuid = intent.getStringExtra(EXTRA_UUID) ?: ""

        // Снимаем уведомление входящего вызова
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        nm?.cancel(LigamentCallManager.INCOMING_CALL_NOTIFICATION_ID)

        when (action) {
            ACTION_ACCEPT_CALL -> {
                // Поднимаем окно приложения на передний план поверх экрана блокировки
                val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                    putExtra("action", ACTION_ACCEPT_CALL)
                    putExtra("uuid", uuid)
                }
                if (launchIntent != null) {
                    context.startActivity(launchIntent)
                }
                LigamentCallManager.onCallAccepted(uuid)
            }
            ACTION_DECLINE_CALL -> {
                LigamentCallManager.onCallEnded(uuid)
            }
        }
    }
}
