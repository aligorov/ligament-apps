package com.ligament.twofa.authenticator

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.RingtoneManager
import android.media.ToneGenerator
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * Нативный менеджер VoIP-вызовов Ligament для Android.
 * Реализует симметричный интерфейс для канала "ligament/callkit":
 * - Экран входящего вызова поверх экрана блокировки (FullScreenIntent)
 * - Нативное уведомление CallStyle с безопасным фолбэком на стандартный баннер
 * - Предварительный запрос runtime-разрешений (RECORD_AUDIO, CAMERA, BLUETOOTH_CONNECT, POST_NOTIFICATIONS)
 * - Нативный генератор телефонных сигналов (ToneGenerator) без конфликтов с WebRTC AudioSwitch
 * - Датчик приближения (экран гаснет у уха во время разговора)
 * - Интеграция с фоновой службой CallForegroundService
 */
object LigamentCallManager : MethodChannel.MethodCallHandler {

    const val INCOMING_CHANNEL_ID = "ligament_incoming_call_channel"
    const val INCOMING_CALL_NOTIFICATION_ID = 3001
    private const val CALL_PERMISSIONS_REQUEST_CODE = 4301

    private var callKitChannel: MethodChannel? = null
    private var appContext: Context? = null
    private var activityRef: WeakReference<Activity>? = null

    private var currentCallUuid: String? = null
    private var currentCallerName: String = "Ligament 2FA"
    private var currentCallHasVideo: Boolean = false
    private var keepAliveEnabled: Boolean = true

    private var ringingWakeLock: PowerManager.WakeLock? = null
    private var proximityWakeLock: PowerManager.WakeLock? = null
    private var toneGenerator: ToneGenerator? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingPermissionCallbacks = mutableListOf<(Boolean) -> Unit>()
    private var permissionTimeoutRunnable: Runnable? = null

    fun attachActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    fun detachActivity(activity: Activity) {
        if (activityRef?.get() === activity) {
            activityRef = null
        }
    }

    fun setup(context: Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext
        val channel = MethodChannel(messenger, "ligament/callkit")
        channel.setMethodCallHandler(this)
        callKitChannel = channel
        createIncomingChannel()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()

        when (call.method) {
            "ensurePermissions" -> {
                val hasVideo = args["hasVideo"] as? Boolean ?: false
                ensureCallPermissions(hasVideo) { granted ->
                    try {
                        result.success(granted)
                    } catch (_: Exception) {}
                }
            }

            "playCallTone" -> {
                val tone = args["tone"] as? String ?: ""
                playCallTone(tone)
                result.success(true)
            }

            "stopCallTone" -> {
                stopCallTone()
                result.success(true)
            }

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
                val hasVideo = args["hasVideo"] as? Boolean ?: currentCallHasVideo
                currentCallHasVideo = hasVideo
                val ctx = appContext
                if (ctx != null) {
                    releaseRingingWakeLock()
                    try {
                        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                        nm?.cancel(INCOMING_CALL_NOTIFICATION_ID)
                    } catch (_: Exception) {}
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

    private fun hasPermission(ctx: Context, perm: String): Boolean {
        return ContextCompat.checkSelfPermission(ctx, perm) == PackageManager.PERMISSION_GRANTED
    }

    /**
     * Запрашивает необходимые для звонка разрешения до вызова getUserMedia во FlutterWebRTC,
     * чтобы избежать гонки устаревшего android.app.Fragment в PermissionUtils (flutter_webrtc)
     * и получить доступ к BLUETOOTH_CONNECT (Android 12+) и POST_NOTIFICATIONS (Android 13+).
     */
    private fun ensureCallPermissions(hasVideo: Boolean, callback: (Boolean) -> Unit) {
        val ctx = appContext
        if (ctx == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            callback(true)
            return
        }

        val needed = mutableListOf<String>()
        if (!hasPermission(ctx, Manifest.permission.RECORD_AUDIO)) {
            needed.add(Manifest.permission.RECORD_AUDIO)
        }
        if (hasVideo && !hasPermission(ctx, Manifest.permission.CAMERA)) {
            needed.add(Manifest.permission.CAMERA)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            !hasPermission(ctx, Manifest.permission.BLUETOOTH_CONNECT)
        ) {
            needed.add(Manifest.permission.BLUETOOTH_CONNECT)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !hasPermission(ctx, Manifest.permission.POST_NOTIFICATIONS)
        ) {
            needed.add(Manifest.permission.POST_NOTIFICATIONS)
        }

        if (needed.isEmpty()) {
            callback(true)
            return
        }

        val activity = activityRef?.get()
        if (activity == null || activity.isFinishing || activity.isDestroyed) {
            callback(hasPermission(ctx, Manifest.permission.RECORD_AUDIO))
            return
        }

        val wasEmpty = pendingPermissionCallbacks.isEmpty()
        pendingPermissionCallbacks.add(callback)

        if (wasEmpty) {
            val timeout = Runnable {
                finishPermissionRequests()
            }
            permissionTimeoutRunnable = timeout
            mainHandler.postDelayed(timeout, 15000L)

            try {
                ActivityCompat.requestPermissions(
                    activity,
                    needed.toTypedArray(),
                    CALL_PERMISSIONS_REQUEST_CODE
                )
            } catch (_: Exception) {
                finishPermissionRequests()
            }
        }
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        @Suppress("UNUSED_PARAMETER") permissions: Array<out String>,
        @Suppress("UNUSED_PARAMETER") grantResults: IntArray
    ): Boolean {
        if (requestCode != CALL_PERMISSIONS_REQUEST_CODE) {
            return false
        }
        finishPermissionRequests()
        return true
    }

    private fun finishPermissionRequests() {
        permissionTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        permissionTimeoutRunnable = null

        val ctx = appContext
        val hasAudio = ctx != null && hasPermission(ctx, Manifest.permission.RECORD_AUDIO)
        val callbacks = pendingPermissionCallbacks.toList()
        pendingPermissionCallbacks.clear()
        for (cb in callbacks) {
            try {
                cb(hasAudio)
            } catch (_: Exception) {}
        }
    }

    /**
     * Генерация телефонных тонов (КПВ, соединение, занято, отбой) через системный ToneGenerator
     * в потоке STREAM_VOICE_CALL без перехвата AudioManager у WebRTC.
     */
    private fun playCallTone(tone: String) {
        try {
            stopCallTone()
            val tg = ToneGenerator(AudioManager.STREAM_VOICE_CALL, 70)
            toneGenerator = tg
            when (tone) {
                "ringback" -> tg.startTone(ToneGenerator.TONE_SUP_RINGTONE)
                "connect" -> tg.startTone(ToneGenerator.TONE_PROP_BEEP, 150)
                "busy" -> tg.startTone(ToneGenerator.TONE_SUP_BUSY, 1200)
                "end" -> tg.startTone(ToneGenerator.TONE_PROP_PROMPT, 200)
                else -> {}
            }
        } catch (_: Exception) {}
    }

    private fun stopCallTone() {
        try {
            toneGenerator?.stopTone()
            toneGenerator?.release()
        } catch (_: Exception) {}
        toneGenerator = null
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
        createIncomingChannel()

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

        val safeCallerName = callerName.takeIf { it.isNotBlank() } ?: "Ligament 2FA"
        val title = if (hasVideo) "📹 Входящий видеозвонок" else "📞 Входящий звонок"

        val baseBuilder = NotificationCompat.Builder(ctx, INCOMING_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(safeCallerName)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setContentIntent(fullScreenPendingIntent)
            .setFullScreenIntent(fullScreenPendingIntent, true)
            .addAction(
                android.R.drawable.ic_menu_call,
                "Ответить",
                acceptPendingIntent
            )
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Отклонить",
                declinePendingIntent
            )

        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        if (nm != null) {
            var notified = false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                try {
                    val person = Person.Builder()
                        .setName(safeCallerName)
                        .setImportant(true)
                        .build()
                    val callStyleNotification = NotificationCompat.Builder(ctx, INCOMING_CHANNEL_ID)
                        .setSmallIcon(R.mipmap.ic_launcher)
                        .setContentTitle(title)
                        .setContentText(safeCallerName)
                        .setPriority(NotificationCompat.PRIORITY_MAX)
                        .setCategory(NotificationCompat.CATEGORY_CALL)
                        .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                        .setOngoing(true)
                        .setAutoCancel(false)
                        .setContentIntent(fullScreenPendingIntent)
                        .setFullScreenIntent(fullScreenPendingIntent, true)
                        .setStyle(
                            NotificationCompat.CallStyle.forIncomingCall(
                                person,
                                declinePendingIntent,
                                acceptPendingIntent
                            )
                        )
                        .build()
                    nm.notify(INCOMING_CALL_NOTIFICATION_ID, callStyleNotification)
                    notified = true
                } catch (_: Exception) {
                    notified = false
                }
            }
            if (!notified) {
                try {
                    nm.notify(INCOMING_CALL_NOTIFICATION_ID, baseBuilder.build())
                } catch (_: Exception) {}
            }
        }

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
        stopCallTone()
        releaseRingingWakeLock()

        try {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            nm?.cancel(INCOMING_CALL_NOTIFICATION_ID)
        } catch (_: Exception) {}

        CallForegroundService.startCall(ctx, uuid, currentCallerName)

        // Для аудиовызовов активируем датчик приближения: экран гаснет при поднесении к уху
        if (!currentCallHasVideo) {
            acquireProximityWakeLock(ctx)
        }
    }

    /**
     * Завершение звонка: снятие уведомлений, остановка фоновой службы и освобождение WakeLock.
     */
    fun endCall(@Suppress("UNUSED_PARAMETER") uuid: String) {
        val ctx = appContext ?: return
        stopCallTone()
        releaseRingingWakeLock()
        releaseProximityWakeLock()

        try {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            nm?.cancel(INCOMING_CALL_NOTIFICATION_ID)
        } catch (_: Exception) {}

        CallForegroundService.stopCall(ctx, keepStandby = keepAliveEnabled)
        currentCallUuid = null
        try {
            val am = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            am?.mode = AudioManager.MODE_NORMAL
        } catch (_: Exception) {}
    }

    fun onCallAccepted(uuid: String) {
        val ctx = appContext
        if (ctx != null) {
            releaseRingingWakeLock()
            try {
                val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                nm?.cancel(INCOMING_CALL_NOTIFICATION_ID)
            } catch (_: Exception) {}
        }
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
        val uuid = intent.getStringExtra("uuid")
            ?: intent.getStringExtra(CallActionReceiver.EXTRA_UUID)
            ?: currentCallUuid
            ?: ""

        if (action == CallActionReceiver.ACTION_ACCEPT_CALL) {
            intent.removeExtra("action")
            if (intent.action == CallActionReceiver.ACTION_ACCEPT_CALL) {
                intent.action = null
            }
            onCallAccepted(uuid)
        }
    }

    private fun acquireRingingWakeLock(context: Context) {
        try {
            if (ringingWakeLock?.isHeld == true) return
            val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            @Suppress("DEPRECATION")
            ringingWakeLock = pm?.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "ligament:call_ringing"
            )
            ringingWakeLock?.acquire(60 * 1000L)
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
                proximityWakeLock?.acquire(4 * 60 * 60 * 1000L)
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
            try {
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
                val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                nm?.createNotificationChannel(channel)
            } catch (_: Exception) {}
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
