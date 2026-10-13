package com.example.mobile_flutter

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
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
                else -> result.notImplemented()
            }
        }
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
