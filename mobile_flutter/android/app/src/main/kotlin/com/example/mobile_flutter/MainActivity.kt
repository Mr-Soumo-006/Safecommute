package com.example.mobile_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.telephony.SmsManager
import android.text.TextUtils
import android.view.KeyEvent
import android.media.MediaRecorder
import android.util.Base64
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val SMS_CHANNEL = "com.safecommute.app/sms"
    private val VOLUME_CHANNEL = "com.safecommute.app/volume"
    internal var volumeChannel: MethodChannel? = null
    private val silencedVictimIds = java.util.Collections.synchronizedSet(HashSet<String>())
    private var activeEmergencyVictim: String? = null
    private var mediaRecorder: MediaRecorder? = null
    private var voiceNoteFile: File? = null
    private var recordingStartTime = 0L

    companion object {
        var instance: MainActivity? = null

        fun notifySosTriggered(clicks: Int = 3, severityLevel: Int = 1, severityText: String = "ELEVATED") {
            instance?.runOnUiThread {
                val args = mapOf(
                    "clicks" to clicks,
                    "severityLevel" to severityLevel,
                    "severityText" to severityText
                )
                instance?.volumeChannel?.invokeMethod("triggerSosNow", args)
            }
        }

        fun notifySeverityEscalated(clicks: Int, severityLevel: Int, severityText: String) {
            instance?.runOnUiThread {
                val args = mapOf(
                    "clicks" to clicks,
                    "severityLevel" to severityLevel,
                    "severityText" to severityText
                )
                instance?.volumeChannel?.invokeMethod("onSeverityEscalated", args)
            }
        }

        fun notifyAlarmMutedExternally() {
            instance?.runOnUiThread {
                instance?.volumeChannel?.invokeMethod("onAlarmMutedExternally", null)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        instance = this
        checkIntentForSosTrigger(intent)
    }

    override fun onResume() {
        super.onResume()
        instance = this
        checkIntentForSosTrigger(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        checkIntentForSosTrigger(intent)
    }

    override fun onDestroy() {
        try { mediaRecorder?.release(); mediaRecorder = null } catch (_: Exception) {}
        if (instance == this) {
            instance = null
        }
        super.onDestroy()
    }

    private fun checkIntentForSosTrigger(intent: Intent?) {
        if (intent?.getBooleanExtra("trigger_sos_direct", false) == true) {
            intent.removeExtra("trigger_sos_direct")
            val clicks = intent.getIntExtra("clicks", 3)
            val severityLevel = intent.getIntExtra("severityLevel", 1)
            val severityText = intent.getStringExtra("severityText") ?: "ELEVATED"
            notifySosTriggered(clicks, severityLevel, severityText)
        }
        if (intent?.getBooleanExtra("open_responder_map", false) == true) {
            intent.removeExtra("open_responder_map")
            // Crucial: DO NOT cancel the emergency notification or mute the alarm here!
            // The alarm rings continuously until the user explicitly stops it in the app.
            instance?.runOnUiThread {
                instance?.volumeChannel?.invokeMethod("openResponderMap", null)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SMS_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "sendSMS") {
                val phone = call.argument<String>("phone")
                val message = call.argument<String>("message")
                
                if (phone != null && message != null) {
                    try {
                        val smsManager = SmsManager.getDefault()
                        smsManager.sendTextMessage(phone, null, message, null, null)
                        result.success("SMS Sent to $phone")
                    } catch (e: Exception) {
                        result.error("SMS_FAILED", "Failed to send SMS", e.message)
                    }
                } else {
                    result.error("INVALID_ARGS", "Phone or message is null", null)
                }
            } else {
                result.notImplemented()
            }
        }

        volumeChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VOLUME_CHANNEL)
        volumeChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "syncSettings" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    val buttonType = call.argument<String>("buttonType") ?: "down"
                    val clickCount = call.argument<Int>("clickCount") ?: 3
                    val username = call.argument<String>("username") ?: "A Commuter"
                    val contacts = call.argument<List<String>>("contacts") ?: emptyList()

                    val prefs = getSharedPreferences("SafeCommuteNativePrefs", Context.MODE_PRIVATE)
                    prefs.edit().apply {
                        putBoolean("enabled", enabled)
                        putString("buttonType", buttonType)
                        putInt("clickCount", clickCount)
                        putString("username", username)
                        putStringSet("contacts", contacts.toSet())
                        apply()
                    }
                    result.success(true)
                }
                "isAccessibilityEnabled" -> {
                    val isEnabled = isAccessibilityServiceEnabled()
                    result.success(isEnabled)
                }
                "openAccessibilitySettings" -> {
                    openAccessibilitySettings()
                    result.success(true)
                }
                "openAppSettings" -> {
                    openAppSettings()
                    result.success(true)
                }
                "showEmergencyNotification" -> {
                    val title = call.argument<String>("title") ?: "🚨 EMERGENCY SOS ALERT"
                    val body = call.argument<String>("body") ?: "A commuter needs immediate help!"
                    val victimId = call.argument<String>("victimId")
                    showEmergencyNotification(title, body, victimId)
                    result.success(true)
                }
                "cancelEmergencyNotification", "muteEmergencyAlarm" -> {
                    val victimId = call.argument<String>("victimId")
                    cancelEmergencyNotification(victimId)
                    result.success(true)
                }
                "unmuteEmergencyAlarm" -> {
                    val victimId = call.argument<String>("victimId")
                    if (!victimId.isNullOrEmpty()) {
                        silencedVictimIds.remove(victimId)
                    } else {
                        silencedVictimIds.clear()
                    }
                    result.success(true)
                }
                "triggerHeavyVibration" -> {
                    triggerHeavyVibration()
                    result.success(true)
                }
                "startResponderBackgroundService" -> {
                    ResponderAlertService.start(this)
                    result.success(true)
                }
                "stopResponderBackgroundService" -> {
                    ResponderAlertService.stop(this)
                    result.success(true)
                }
                                "isResponderBackgroundServiceRunning" -> {
                    result.success(ResponderAlertService.isRunning)
                }
                "startVoiceRecording" -> {
                    result.success(startVoiceRecording())
                }
                "stopVoiceRecording" -> {
                    result.success(stopVoiceRecording())
                }
                "isVoiceRecording" -> {
                    result.success(mediaRecorder != null)
                }
                else -> result.notImplemented()
            }
        }
    }

        private fun startVoiceRecording(): Boolean {
        return try {
            val recorder = mediaRecorder
            if (recorder != null) {
                try { recorder.stop() } catch (_: Exception) {}
                recorder.release()
                mediaRecorder = null
            }
            val file = File(cacheDir, "accident_voice_" + System.currentTimeMillis() + ".m4a")
            voiceNoteFile = file
            mediaRecorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(this)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }.apply {
                setAudioSource(MediaRecorder.AudioSource.MIC)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setAudioEncodingBitRate(64000)
                setAudioSamplingRate(44100)
                setOutputFile(file.absolutePath)
                prepare()
                start()
            }
            recordingStartTime = System.currentTimeMillis()
            true
        } catch (e: Exception) {
            mediaRecorder = null
            false
        }
    }

    private fun stopVoiceRecording(): Map<String, Any?> {
        return try {
            val recorder = mediaRecorder
            if (recorder != null) {
                try { recorder.stop() } catch (_: Exception) {}
                recorder.release()
                mediaRecorder = null
            }
            val file = voiceNoteFile
            if (file != null && file.exists() && file.length() > 0) {
                val durationSec = ((System.currentTimeMillis() - recordingStartTime) / 1000).toInt()
                val bytes = file.readBytes()
                val base64 = Base64.encodeToString(bytes, Base64.NO_WRAP)
                mapOf(
                    "success" to true,
                    "filePath" to file.absolutePath,
                    "base64" to base64,
                    "durationSec" to durationSec,
                    "size" to file.length()
                )
            } else {
                mapOf("success" to false)
            }
        } catch (e: Exception) {
            mediaRecorder = null
            mapOf("success" to false, "error" to (e.message ?: "Unknown error"))
        }
    }

    private fun showEmergencyNotification(title: String, body: String, victimId: String? = null) {
        if (!victimId.isNullOrEmpty()) { silencedVictimIds.remove(victimId); activeEmergencyVictim = victimId }
        if (!victimId.isNullOrEmpty()) {
            activeEmergencyVictim = victimId
        }
        try {
            // 1. Wake screen up immediately if device is asleep
            try {
                val powerManager = getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager
                val wakeLock = powerManager?.newWakeLock(
                    android.os.PowerManager.FULL_WAKE_LOCK or android.os.PowerManager.ACQUIRE_CAUSES_WAKEUP or android.os.PowerManager.ON_AFTER_RELEASE,
                    "SafeCommute:ActivityEmergencyWakeLock"
                )
                wakeLock?.acquire(15000)
            } catch (_: Exception) {}

            triggerHeavyVibration()

            // 2. Always trigger ResponderAlertService for looping alarm and continuous vibration
            val serviceIntent = Intent(this, ResponderAlertService::class.java).apply {
                action = ResponderAlertService.ACTION_TRIGGER_EMERGENCY
                putExtra("title", title)
                putExtra("body", body)
                putExtra("victimId", victimId)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(serviceIntent)
            } else {
                startService(serviceIntent)
            }

            val channelId = "safecommute_emergency_channel"
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                var channel = notificationManager.getNotificationChannel(channelId)
                if (channel == null) {
                    channel = NotificationChannel(
                        channelId,
                        "Critical SOS Emergency Alerts",
                        NotificationManager.IMPORTANCE_HIGH
                    ).apply {
                        description = "High-priority alarms when a commuter triggers an SOS"
                        enableVibration(true)
                        vibrationPattern = longArrayOf(0, 500, 200, 500, 200, 800)
                        enableLights(true)
                        lightColor = Color.RED
                        lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    }
                    notificationManager.createNotificationChannel(channel)
                }
            }

            val launchIntent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("open_responder_map", true)
            }
            val pendingIntent = PendingIntent.getActivity(
                this,
                0,
                launchIntent,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE else PendingIntent.FLAG_UPDATE_CURRENT
            )

            val muteIntent = Intent(this, ResponderAlertService::class.java).apply {
                action = ResponderAlertService.ACTION_MUTE_ALARM
                putExtra("victimId", victimId)
            }
            val mutePendingIntent = PendingIntent.getService(
                this,
                912,
                muteIntent,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE else PendingIntent.FLAG_UPDATE_CURRENT
            )

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, channelId)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }

            builder.setSmallIcon(R.mipmap.launcher_icon)
                .setContentTitle(title)
                .setContentText(body)
                .setAutoCancel(false)
                .setOngoing(true)
                .setContentIntent(pendingIntent)
                .setPriority(Notification.PRIORITY_MAX)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN) {
                builder.setStyle(Notification.BigTextStyle().bigText(body))
                builder.addAction(Notification.Action.Builder(null, "STOP ALARM", mutePendingIntent).build())
                builder.addAction(Notification.Action.Builder(null, "VIEW LIVE RADAR", pendingIntent).build())
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                builder.setCategory(Notification.CATEGORY_ALARM)
                builder.setVisibility(Notification.VISIBILITY_PUBLIC)
                builder.setFullScreenIntent(pendingIntent, false)
            }

            notificationManager.notify(911, builder.build())
        } catch (_: Exception) {}
    }

    private fun cancelEmergencyNotification(victimId: String? = null) {
        val targetVictim = if (!victimId.isNullOrEmpty()) victimId else activeEmergencyVictim
        if (!targetVictim.isNullOrEmpty()) {
            silencedVictimIds.add(targetVictim)
        }
        try {
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            notificationManager?.cancel(911)
        } catch (_: Exception) {}

        try {
            val muteIntent = Intent(this, ResponderAlertService::class.java).apply {
                action = ResponderAlertService.ACTION_MUTE_ALARM
                putExtra("victimId", targetVictim)
            }
            startService(muteIntent)
        } catch (_: Exception) {}

        stopHeavyVibration()
    }

    private fun stopHeavyVibration() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vibratorManager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
                vibratorManager?.defaultVibrator?.cancel()
            } else {
                @Suppress("DEPRECATION")
                val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
                vibrator?.cancel()
            }
        } catch (_: Exception) {}
    }

    private fun triggerHeavyVibration() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vibratorManager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
                val vibrator = vibratorManager?.defaultVibrator
                val pattern = longArrayOf(0, 500, 200, 500, 200, 800)
                vibrator?.vibrate(VibrationEffect.createWaveform(pattern, -1))
            } else {
                @Suppress("DEPRECATION")
                val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val pattern = longArrayOf(0, 500, 200, 500, 200, 800)
                    vibrator?.vibrate(VibrationEffect.createWaveform(pattern, -1))
                } else {
                    @Suppress("DEPRECATION")
                    vibrator?.vibrate(longArrayOf(0, 500, 200, 500, 200, 800), -1)
                }
            }
        } catch (_: Exception) {}
    }

    private fun openAppSettings() {
        try {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", packageName, null)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
        } catch (_: Exception) {}
    }

    private fun isAccessibilityServiceEnabled(): Boolean {
        val expectedClassName = VolumeSosAccessibilityService::class.java.name
        val enabledServices = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false

        val splitter = TextUtils.SimpleStringSplitter(':')
        splitter.setString(enabledServices)

        while (splitter.hasNext()) {
            val componentStr = splitter.next()
            val component = ComponentName.unflattenFromString(componentStr)
            if (component != null && component.packageName == packageName &&
                (component.className == expectedClassName || component.shortClassName == ".VolumeSosAccessibilityService")) {
                return true
            }
        }
        return false
    }

    private fun openAccessibilitySettings() {
        try {
            val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
        } catch (_: Exception) {}
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    volumeChannel?.invokeMethod("onVolumePressed", "down")
                }
                KeyEvent.KEYCODE_VOLUME_UP -> {
                    volumeChannel?.invokeMethod("onVolumePressed", "up")
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }
}
