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
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val SMS_CHANNEL = "com.safecommute.app/sms"
    private val VOLUME_CHANNEL = "com.safecommute.app/volume"
    private var volumeChannel: MethodChannel? = null

    companion object {
        var instance: MainActivity? = null

        fun notifySosTriggered() {
            instance?.runOnUiThread {
                instance?.volumeChannel?.invokeMethod("triggerSosNow", null)
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
        if (instance == this) {
            instance = null
        }
        super.onDestroy()
    }

    private fun checkIntentForSosTrigger(intent: Intent?) {
        if (intent?.getBooleanExtra("trigger_sos_direct", false) == true) {
            intent.removeExtra("trigger_sos_direct")
            notifySosTriggered()
        }
        if (intent?.getBooleanExtra("open_responder_map", false) == true) {
            intent.removeExtra("open_responder_map")
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
                    showEmergencyNotification(title, body)
                    result.success(true)
                }
                "cancelEmergencyNotification" -> {
                    cancelEmergencyNotification()
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
                else -> result.notImplemented()
            }
        }
    }

    private fun showEmergencyNotification(title: String, body: String) {
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

            // 2. If ResponderAlertService is running, trigger its looping sound as well
            if (ResponderAlertService.isRunning) {
                val serviceIntent = Intent(this, ResponderAlertService::class.java).apply {
                    action = ResponderAlertService.ACTION_TRIGGER_EMERGENCY
                    putExtra("title", title)
                    putExtra("body", body)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(serviceIntent)
                } else {
                    startService(serviceIntent)
                }
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

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, channelId)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }

            builder.setSmallIcon(R.mipmap.launcher_icon)
                .setContentTitle(title)
                .setContentText(body)
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)
                .setPriority(Notification.PRIORITY_MAX)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN) {
                builder.setStyle(Notification.BigTextStyle().bigText(body))
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

    private fun cancelEmergencyNotification() {
        try {
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            notificationManager?.cancel(911)
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
