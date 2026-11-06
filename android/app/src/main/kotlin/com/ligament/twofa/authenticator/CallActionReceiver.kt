package com.ligament.twofa.authenticator

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Приёмник системных действий уведомления звонка (Ответить / Отклонить / Завершить).
 * Для кнопки «Ответить» используется прямой PendingIntent.getActivity (MainActivity),
 * чтобы соответствовать ограничениям Android 12+ Notification Trampoline и исключить
 * двойной вызов onCallAccepted.
 */
class CallActionReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_ACCEPT_CALL = "com.ligament.twofa.authenticator.ACTION_ACCEPT_CALL"
        const val ACTION_DECLINE_CALL = "com.ligament.twofa.authenticator.ACTION_DECLINE_CALL"
        const val EXTRA_UUID = "extra_uuid"

        fun createAcceptPendingIntent(context: Context, uuid: String): PendingIntent {
            val intent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("action", ACTION_ACCEPT_CALL)
                putExtra("uuid", uuid)
                putExtra(EXTRA_UUID, uuid)
            }
            return PendingIntent.getActivity(
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
        if (intent == null) return
        val action = intent.action ?: return
        val uuid = intent.getStringExtra(EXTRA_UUID) ?: ""

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        nm?.cancel(LigamentCallManager.INCOMING_CALL_NOTIFICATION_ID)

        when (action) {
            ACTION_ACCEPT_CALL -> {
                LigamentCallManager.onCallAccepted(uuid)
            }
            ACTION_DECLINE_CALL -> {
                LigamentCallManager.onCallEnded(uuid)
            }
        }
    }
}
