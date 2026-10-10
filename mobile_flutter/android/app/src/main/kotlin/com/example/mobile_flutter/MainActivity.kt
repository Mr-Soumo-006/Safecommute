package com.example.mobile_flutter

import android.telephony.SmsManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.safecommute.app/sms"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
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
    }
}
