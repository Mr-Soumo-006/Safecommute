package com.example.mobile_flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.provider.Telephony
import android.telephony.SmsMessage
import android.util.Log

class EmergencySmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Telephony.Sms.Intents.SMS_RECEIVED_ACTION) {
            val messages: Array<SmsMessage>? = Telephony.Sms.Intents.getMessagesFromIntent(intent)
            if (messages.isNullOrEmpty()) return

            val fullBody = StringBuilder()
            var sender = ""
            for (msg in messages) {
                fullBody.append(msg.messageBody)
                if (sender.isEmpty()) {
                    sender = msg.displayOriginatingAddress ?: ""
                }
            }

            val body = fullBody.toString()
            Log.d("EmergencySmsReceiver", "Incoming SMS from $sender: $body")

            // Check if this is an emergency message from SafeCommute
            if (body.contains("EMERGENCY!", ignoreCase = true)) {
                // Wake up screen immediately
                try {
                    val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
                    val wakeLock = powerManager?.newWakeLock(
                        PowerManager.FULL_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP or PowerManager.ON_AFTER_RELEASE,
                        "SafeCommute:SmsEmergencyWakeLock"
                    )
                    wakeLock?.acquire(15000)
                } catch (_: Exception) {}

                // Start emergency alarm and high-priority notification via ResponderAlertService
                val serviceIntent = Intent(context, ResponderAlertService::class.java).apply {
                    action = ResponderAlertService.ACTION_TRIGGER_EMERGENCY
                    putExtra("title", "🚨 CRITICAL SMS SOS ALERT!")
                    putExtra("body", body)
                    putExtra("sender", sender)
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(serviceIntent)
                } else {
                    context.startService(serviceIntent)
                }
            }
        }
    }
}
