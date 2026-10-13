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

    private val clickTimestamps = ArrayList<Long>()
    private var lastTriggerTime = 0L

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

        // Debounce: prevent re-triggering within 10 seconds of an existing trigger
        if (now - lastTriggerTime < 10000L) return

        clickTimestamps.add(now)

        // Keep presses only within the last 2.5 seconds
        clickTimestamps.removeAll { now - it > 2500L }

        Log.d("VolumeSosService", "Volume key ($buttonType) press detected: ${clickTimestamps.size}/$requiredClicks")

        if (clickTimestamps.size >= requiredClicks) {
            clickTimestamps.clear()
            lastTriggerTime = now
            triggerEmergencySos()
        }
    }

    private fun triggerEmergencySos() {
        Log.i("VolumeSosService", "EMERGENCY TRIGGERED VIA HARDWARE VOLUME BUTTON!")

        // 1. Wake the CPU for 15 seconds to finish SMS and app launch even if screen is locked
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            val wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SafeCommute:SosWakeLock")
            wakeLock.acquire(15000L)
        } catch (e: Exception) {
            Log.e("VolumeSosService", "Failed to acquire wake lock: ${e.message}")
        }

        // 2. Heavy Haptic Vibration Feedback (double strong buzz)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vibratorManager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                val vibrator = vibratorManager.defaultVibrator
                vibrator.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 300, 150, 500), -1))
            } else {
                @Suppress("DEPRECATION")
                val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    vibrator.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 300, 150, 500), -1))
                } else {
                    @Suppress("DEPRECATION")
                    vibrator.vibrate(longArrayOf(0, 300, 150, 500), -1)
                }
            }
        } catch (e: Exception) {
            Log.e("VolumeSosService", "Vibration failed: ${e.message}")
        }

        val prefs = getSharedPreferences("SafeCommuteNativePrefs", Context.MODE_PRIVATE)
        val username = prefs.getString("username", "A Commuter") ?: "A Commuter"
        val contacts = prefs.getStringSet("contacts", emptySet()) ?: emptySet()

        // 3. Acquire latest available GPS coordinates for SMS fallback
        var mapLink = "Location unknown"
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
                mapLink = "https://maps.google.com/?q=${bestLocation.latitude},${bestLocation.longitude}"
            }
        } catch (e: Exception) {
            Log.e("VolumeSosService", "Location fetch failed: ${e.message}")
        }

        // 4. Send background SMS to all saved contacts
        val smsMessage = "$username's EMERGENCY! I need help. Track my live location: $mapLink"
        try {
            val smsManager = SmsManager.getDefault()
            for (contact in contacts) {
                val parts = contact.split(": ")
                val phone = if (parts.size > 1) parts[1].trim() else contact.trim()
                if (phone.isNotEmpty()) {
                    smsManager.sendTextMessage(phone, null, smsMessage, null, null)
                    Log.i("VolumeSosService", "Emergency background SMS dispatched to $phone")
                }
            }
        } catch (e: Exception) {
            Log.e("VolumeSosService", "SMS dispatch failed: ${e.message}")
        }

        // 5. Notify MainActivity if running or launch it to foreground
        MainActivity.notifySosTriggered()

        try {
            val launchIntent = Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                putExtra("trigger_sos_direct", true)
            }
            startActivity(launchIntent)
        } catch (e: Exception) {
            Log.e("VolumeSosService", "Failed to launch MainActivity: ${e.message}")
        }
    }
}
