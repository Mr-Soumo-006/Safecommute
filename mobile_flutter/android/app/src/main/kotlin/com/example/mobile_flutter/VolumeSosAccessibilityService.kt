package com.example.mobile_flutter

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.telephony.SmsManager
import android.util.Log
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent
import java.util.ArrayList

class VolumeSosAccessibilityService : AccessibilityService() {

    private var sessionClicks = 0
    private var lastClickTime = 0L
    private var currentSeverityLevel = 0
    private var emergencyActiveUntil = 0L

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Required by AccessibilityService interface
    }

    override fun onInterrupt() {
        Log.d("VolumeSosService", "SafeCommute Accessibility Service interrupted")
    }

    override fun onKeyEvent(event: KeyEvent?): Boolean {
        if (event == null) return false

        if (event.action == KeyEvent.ACTION_DOWN) {
            val keyCode = event.keyCode
            if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
                handleVolumeKey(keyCode)
            }
        }

        // Return false so the system can still process normal volume adjustments
        return false
    }

    private fun handleVolumeKey(keyCode: Int) {
        val prefs = getSharedPreferences("SafeCommuteNativePrefs", Context.MODE_PRIVATE)
        val enabled = prefs.getBoolean("enabled", true)
        if (!enabled) return

        val buttonType = prefs.getString("buttonType", "down") ?: "down"
        val requiredClicks = prefs.getInt("clickCount", 3)

        val isTargetKey = if (buttonType == "up") {
            keyCode == KeyEvent.KEYCODE_VOLUME_UP
        } else {
            keyCode == KeyEvent.KEYCODE_VOLUME_DOWN
        }

        if (!isTargetKey) return

        val now = System.currentTimeMillis()

        // If more than 3.5 seconds have elapsed since last press AND outside escalation window, reset session
        if (now - lastClickTime > 3500L && now > emergencyActiveUntil) {
            sessionClicks = 1
            currentSeverityLevel = 0
        } else {
            sessionClicks++
        }
        lastClickTime = now

        Log.d("VolumeSosService", "Volume key ($buttonType) press: $sessionClicks clicks (required: $requiredClicks)")

        if (sessionClicks >= requiredClicks && currentSeverityLevel == 0) {
            // First threshold met: Trigger initial SOS (Level 1: ELEVATED)
            currentSeverityLevel = 1
            emergencyActiveUntil = now + 60000L // 60-second active escalation window
            triggerEmergencySos(sessionClicks, 1, "ELEVATED")
        } else if (sessionClicks in 4..5 && currentSeverityLevel < 2) {
            // Second threshold met: Escalate to Level 2 (URGENT DANGER)
            currentSeverityLevel = 2
            emergencyActiveUntil = now + 60000L
            escalateEmergencySeverity(sessionClicks, 2, "URGENT")
        } else if (sessionClicks >= 6 && currentSeverityLevel < 3) {
            // Third threshold met: Escalate to Level 3 (CRITICAL LIFE THREAT)
            currentSeverityLevel = 3
            emergencyActiveUntil = now + 60000L
            escalateEmergencySeverity(sessionClicks, 3, "CRITICAL")
        }
    }

    private fun triggerEmergencySos(clicks: Int, severityLevel: Int, severityText: String) {
        Log.i("VolumeSosService", "EMERGENCY TRIGGERED VIA HARDWARE VOLUME BUTTON! (Clicks: $clicks, Level: $severityLevel)")

        // 1. Wake the CPU for 15 seconds to finish SMS and app launch even if screen is locked
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            val wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SafeCommute:SosWakeLock")
            wakeLock.acquire(15000L)
        } catch (e: Exception) {
            Log.e("VolumeSosService", "Failed to acquire wake lock: ${e.message}")
        }

        // 2. Heavy Haptic Vibration Feedback
        vibratePattern(longArrayOf(0, 250, 150, 350))

        val prefs = getSharedPreferences("SafeCommuteNativePrefs", Context.MODE_PRIVATE)
        val username = prefs.getString("username", "A Commuter") ?: "A Commuter"
        val contacts = prefs.getStringSet("contacts", emptySet()) ?: emptySet()

        // 3. Acquire latest available GPS coordinates for SMS fallback
        val mapLink = fetchLocationLink()

        // 4. Send background SMS to all saved contacts
        val smsMessage = "$username's EMERGENCY! I need help. Track my live location: $mapLink"
        dispatchSms(contacts, smsMessage)

        // 5. Notify MainActivity if running or launch it to foreground
        MainActivity.notifySosTriggered(clicks, severityLevel, severityText)

        try {
            val launchIntent = Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                putExtra("trigger_sos_direct", true)
                putExtra("clicks", clicks)
                putExtra("severityLevel", severityLevel)
                putExtra("severityText", severityText)
            }
            startActivity(launchIntent)
        } catch (e: Exception) {
            Log.e("VolumeSosService", "Failed to launch MainActivity: ${e.message}")
        }
    }

    private fun escalateEmergencySeverity(clicks: Int, severityLevel: Int, severityText: String) {
        Log.i("VolumeSosService", "EMERGENCY ESCALATED! (Clicks: $clicks, Level: $severityLevel - $severityText)")

        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            val wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SafeCommute:SosEscalateWakeLock")
            wakeLock.acquire(10000L)
        } catch (_: Exception) {}

        // Distinct escalating vibration bursts
        val pattern = if (severityLevel == 2) {
            longArrayOf(0, 300, 100, 300, 100, 450)
        } else {
            longArrayOf(0, 400, 80, 400, 80, 400, 80, 600)
        }
        vibratePattern(pattern)

        val prefs = getSharedPreferences("SafeCommuteNativePrefs", Context.MODE_PRIVATE)
        val username = prefs.getString("username", "A Commuter") ?: "A Commuter"
        val contacts = prefs.getStringSet("contacts", emptySet()) ?: emptySet()
        val mapLink = fetchLocationLink()

        val escalatedMessage = "[$severityText - $clicks SOS PRESSES] $username in ESCALATED DANGER! Track live: $mapLink"
        dispatchSms(contacts, escalatedMessage)

        MainActivity.notifySeverityEscalated(clicks, severityLevel, severityText)
    }

    private fun vibratePattern(pattern: LongArray) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vibratorManager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                vibratorManager.defaultVibrator.vibrate(VibrationEffect.createWaveform(pattern, -1))
            } else {
                @Suppress("DEPRECATION")
                val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    vibrator.vibrate(VibrationEffect.createWaveform(pattern, -1))
                } else {
                    @Suppress("DEPRECATION")
                    vibrator.vibrate(pattern, -1)
                }
            }
        } catch (_: Exception) {}
    }

    private fun fetchLocationLink(): String {
        try {
            val locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
            var bestLocation: Location? = null
            if (checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED) {
                val gpsLoc = locationManager.getLastKnownLocation(LocationManager.GPS_PROVIDER)
                val netLoc = locationManager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
                bestLocation = when {
                    gpsLoc == null -> netLoc
                    netLoc == null -> gpsLoc
                    gpsLoc.time > netLoc.time -> gpsLoc
                    else -> netLoc
                }
            }
            if (bestLocation != null) {
                return "https://maps.google.com/?q=${bestLocation.latitude},${bestLocation.longitude}"
            }
        } catch (_: Exception) {}
        return "Location unknown"
    }

    private fun dispatchSms(contacts: Set<String>, message: String) {
        try {
            val smsManager = SmsManager.getDefault()
            for (contact in contacts) {
                val parts = contact.split(": ")
                val phone = if (parts.size > 1) parts[1].trim() else contact.trim()
                if (phone.isNotEmpty()) {
                    smsManager.sendTextMessage(phone, null, message, null, null)
                    Log.i("VolumeSosService", "SMS dispatched to $phone")
                }
            }
        } catch (e: Exception) {
            Log.e("VolumeSosService", "SMS dispatch failed: ${e.message}")
        }
    }
}
