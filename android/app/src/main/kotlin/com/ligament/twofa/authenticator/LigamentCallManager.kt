package com.ligament.twofa.authenticator

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Нативный менеджер VoIP-вызовов Ligament для Android.
 * Реализует симметричный интерфейс для канала "ligament/callkit":
 * - Экран входящего вызова поверх экрана блокировки (FullScreenIntent)
 * - Нативное уведомление CallStyle с системным рингтоном
 * - Датчик приближения (экран гаснет у уха во время разговора)
 * - Интеграция с фоновой службой CallForegroundService (FGS phoneCall/microphone)
 */
object LigamentCallManager : MethodChannel.MethodCallHandler {

    const val INCOMING_CHANNEL_ID = "ligament_incoming_call_channel"
    const val INCOMING_CALL_NOTIFICATION_ID = 3001

    private var callKitChannel: MethodChannel? = null
    private var appContext: Context? = null

    private var currentCallUuid: String? = null
    private var currentCallerName: String = "Ligament 2FA"
    private var currentCallHasVideo: Boolean = false
    private var keepAliveEnabled: Boolean = true

    private var ringingWakeLock: PowerManager.WakeLock? = null
    private var proximityWakeLock: PowerManager.WakeLock? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    fun setup(context: Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext
        if (callKitChannel == null) {
            val channel = MethodChannel(messenger, "ligament/callkit")
            channel.setMethodCallHandler(this)
            callKitChannel = channel
        }
        createIncomingChannel()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()

        when (call.method) {
            "startBackgroundKeepAlive" -> {
                keepAliveEnabled = true
                val ctx = appContext
                if (ctx != null) {
                    CallForegroundService.startStandby(ctx)
                }
                result.success(true)
            }

            "stopBackgroundKeepAlive" -> {
                keepAliveEnabled = false
                val ctx = appContext
                if (ctx != null && currentCallUuid == null) {
                    CallForegroundService.stopService(ctx)
                }
                result.success(true)
            }

            "reportIncomingCall" -> {
                val uuid = args["uuid"] as? String ?: ""
                val callerName = (args["callerName"] as? String)?.takeIf { it.isNotBlank() } ?: "Ligament 2FA"
                val hasVideo = args["hasVideo"] as? Boolean ?: false

                if (uuid.isEmpty()) {
                    result.error("INVALID_UUID", "UUID вызова обязателен", null)
                    return
                }

                reportIncomingCall(uuid, callerName, hasVideo)
                result.success(true)
            }

            "answerCall" -> {
                val uuid = args["uuid"] as? String ?: currentCallUuid ?: ""
                val hasVideo = args["hasVideo"] as? Boolean ?: currentCallHasVideo
                currentCallHasVideo = hasVideo
                val ctx = appContext
                if (ctx != null) {
                    releaseRingingWakeLock()
                    val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    nm.cancel(INCOMING_CALL_NOTIFICATION_ID)
                }
                activateAudio(hasVideo)
                result.success(true)
            }

            "activateAudio" -> {
                val hasVideo = args["hasVideo"] as? Boolean ?: currentCallHasVideo
                currentCallHasVideo = hasVideo
                activateAudio(hasVideo)
                result.success(true)
            }

            "startOutgoingCall" -> {
                val uuid = args["uuid"] as? String ?: ""
                val recipientName = (args["recipientName"] as? String)?.takeIf { it.isNotBlank() } ?: "Ligament 2FA"
                val hasVideo = args["hasVideo"] as? Boolean ?: false

                currentCallUuid = uuid
                currentCallerName = recipientName
                currentCallHasVideo = hasVideo
                activateAudio(hasVideo)
                result.success(true)
            }

            "reportOutgoingCallConnected" -> {
                val uuid = args["uuid"] as? String ?: currentCallUuid ?: ""
                reportCallConnected(uuid)
                result.success(true)
            }

            "endCall" -> {
                val uuid = args["uuid"] as? String ?: currentCallUuid ?: ""
                endCall(uuid)
                result.success(true)
            }

            "setMuted" -> {
                val muted = args["muted"] as? Boolean ?: false
                result.success(true)
            }

            "canUseFullScreenIntent" -> {
                result.success(canUseFullScreenIntent())
            }

            "requestFullScreenIntentPermission" -> {
                requestFullScreenIntentPermission()
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    /**
     * Отображает нативное системное уведомление входящего вызова с высоким приоритетом,
     * запуском Activity поверх экрана блокировки и системным рингтоном.
     */
    fun reportIncomingCall(uuid: String, callerName: String, hasVideo: Boolean) {
        val ctx = appContext ?: return
        currentCallUuid = uuid
        currentCallerName = callerName
        currentCallHasVideo = hasVideo

        acquireRingingWakeLock(ctx)

        val fullScreenIntent = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("action", "ACTION_INCOMING_CALL")
            putExtra("uuid", uuid)
            putExtra("callerName", callerName)
            putExtra("hasVideo", hasVideo)
        }

        val fullScreenPendingIntent = PendingIntent.getActivity(
            ctx,
            uuid.hashCode(),
            fullScreenIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val acceptPendingIntent = CallActionReceiver.createAcceptPendingIntent(ctx, uuid)
        val declinePendingIntent = CallActionReceiver.createDeclinePendingIntent(ctx, uuid)

        val title = if (hasVideo) "📹 Входящий видеозвонок" else "📞 Входящий звонок"

        val builder = NotificationCompat.Builder(ctx, INCOMING_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(callerName)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setContentIntent(fullScreenPendingIntent)
            .setFullScreenIntent(fullScreenPendingIntent, true)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val person = Person.Builder()
                .setName(callerName)
                .setImportant(true)
                .build()
            builder.setStyle(
                NotificationCompat.CallStyle.forIncomingCall(
                    person,
                    declinePendingIntent,
                    acceptPendingIntent
                )
            )
        } else {
            builder.addAction(
                android.R.drawable.ic_menu_call,
                "Ответить",
                acceptPendingIntent
            )
            builder.addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Отклонить",
                declinePendingIntent
            )
        }

        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(INCOMING_CALL_NOTIFICATION_ID, builder.build())

        try {
            ctx.startActivity(fullScreenIntent)
        } catch (_: Exception) {}
    }

    private fun activateAudio(hasVideo: Boolean) {
        val ctx = appContext ?: return
        try {
            val am = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
            am.mode = AudioManager.MODE_IN_COMMUNICATION
            am.isMicrophoneMute = false
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = hasVideo
        } catch (_: Exception) {}
    }

    /**
     * Вызывается при соединении звонка: гасит рингтон, переводит звонок
     * в активную службу CallForegroundService и включает датчик приближения.
     */
    fun reportCallConnected(uuid: String) {
        val ctx = appContext ?: return
        releaseRingingWakeLock()

        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(INCOMING_CALL_NOTIFICATION_ID)

        CallForegroundService.startCall(ctx, uuid, currentCallerName)

        // Для аудиовызовов активируем датчик приближения: экран гаснет при поднесении к уху
        if (!currentCallHasVideo) {
            acquireProximityWakeLock(ctx)
        }
    }

    /**
     * Завершение звонка: снятие уведомлений, остановка фоновой службы и освобождение WakeLock.
     */
    fun endCall(uuid: String) {
        val ctx = appContext ?: return
        releaseRingingWakeLock()
        releaseProximityWakeLock()

        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(INCOMING_CALL_NOTIFICATION_ID)

        CallForegroundService.stopCall(ctx, keepStandby = keepAliveEnabled)
        currentCallUuid = null
        try {
            val am = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            am?.mode = AudioManager.MODE_NORMAL
        } catch (_: Exception) {}
    }

    fun onCallAccepted(uuid: String) {
        mainHandler.post {
            callKitChannel?.invokeMethod("onCallAccepted", mapOf("uuid" to uuid))
        }
    }

    fun onCallEnded(uuid: String) {
        endCall(uuid)
        mainHandler.post {
            callKitChannel?.invokeMethod("onCallEnded", mapOf("uuid" to uuid))
        }
    }

    fun handleIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.getStringExtra("action") ?: intent.action ?: return
        val uuid = intent.getStringExtra("uuid") ?: currentCallUuid ?: ""

        if (action == CallActionReceiver.ACTION_ACCEPT_CALL) {
            onCallAccepted(uuid)
        }
    }

    private fun acquireRingingWakeLock(context: Context) {
        try {
            if (ringingWakeLock?.isHeld == true) return
            val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            ringingWakeLock = pm?.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "ligament:call_ringing"
            )
            ringingWakeLock?.acquire(60 * 1000L) // Максимум 60 секунд на звонок
        } catch (_: Exception) {}
    }

    private fun releaseRingingWakeLock() {
        try {
            if (ringingWakeLock?.isHeld == true) {
                ringingWakeLock?.release()
            }
        } catch (_: Exception) {}
        ringingWakeLock = null
    }

    private fun acquireProximityWakeLock(context: Context) {
        try {
            if (proximityWakeLock?.isHeld == true) return
            val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP &&
                pm.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)
            ) {
                proximityWakeLock = pm.newWakeLock(
                    PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                    "ligament:proximity_lock"
                )
                proximityWakeLock?.acquire()
            }
        } catch (_: Exception) {}
    }

    private fun releaseProximityWakeLock() {
        try {
            if (proximityWakeLock?.isHeld == true) {
                proximityWakeLock?.release()
            }
        } catch (_: Exception) {}
        proximityWakeLock = null
    }

    private fun createIncomingChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ctx = appContext ?: return
            val ringtoneUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            val audioAttrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()

            val channel = NotificationChannel(
                INCOMING_CHANNEL_ID,
                "Входящие звонки",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Срочные входящие аудио- и видеозвонки"
                setSound(ringtoneUri, audioAttrs)
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 1000, 1000, 1000, 1000)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(channel)
        }
    }

    fun canUseFullScreenIntent(): Boolean {
        val ctx = appContext ?: return true
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            nm?.canUseFullScreenIntent() ?: true
        } else {
            true
        }
    }

    fun requestFullScreenIntentPermission() {
        val ctx = appContext ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            try {
                val intent = Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
                    data = Uri.parse("package:${ctx.packageName}")
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
                ctx.startActivity(intent)
            } catch (_: Exception) {}
        }
    }
}
