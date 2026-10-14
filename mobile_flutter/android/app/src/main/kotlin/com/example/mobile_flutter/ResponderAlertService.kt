package com.example.mobile_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log

class ResponderAlertService : Service() {

    private var mediaPlayer: MediaPlayer? = null
    private var isAlarmPlaying = false

    private val SERVICE_CHANNEL_ID = "safecommute_responder_service_channel"
    private val EMERGENCY_CHANNEL_ID = "safecommute_emergency_channel"
    private val SERVICE_NOTIFICATION_ID = 101
    private val EMERGENCY_NOTIFICATION_ID = 911

    companion object {
        var isRunning = false
        const val ACTION_START_MONITOR = "ACTION_START_MONITOR"
        const val ACTION_STOP_MONITOR = "ACTION_STOP_MONITOR"
        const val ACTION_TRIGGER_EMERGENCY = "ACTION_TRIGGER_EMERGENCY"
        const val ACTION_MUTE_ALARM = "ACTION_MUTE_ALARM"

        fun start(context: Context) {
            val intent = Intent(context, ResponderAlertService::class.java).apply {
                action = ACTION_START_MONITOR
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, ResponderAlertService::class.java).apply {
                action = ACTION_STOP_MONITOR
            }
            context.startService(intent)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START_MONITOR

        when (action) {
            ACTION_START_MONITOR -> {
                isRunning = true
                val notification = buildServiceNotification()
                startForeground(SERVICE_NOTIFICATION_ID, notification)
            }
            ACTION_STOP_MONITOR -> {
                isRunning = false
                stopAlarm()
                stopForeground(true)
                stopSelf()
            }
            ACTION_TRIGGER_EMERGENCY -> {
                val title = intent?.getStringExtra("title") ?: "🚨 CRITICAL SOS ALERT!"
                val body = intent?.getStringExtra("body") ?: "A commuter triggered an emergency SOS!"
                triggerEmergencyAlarm(title, body)
            }
            ACTION_MUTE_ALARM -> {
                stopAlarm()
                try {
                    val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    manager.cancel(EMERGENCY_NOTIFICATION_ID)
                } catch (_: Exception) {}
            }
        }

        return START_STICKY
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            // Background Service Monitoring Channel (Low Priority / Silent in tray)
            val serviceChannel = NotificationChannel(
                SERVICE_CHANNEL_ID,
                "SafeCommute Background Shield",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps emergency alert monitoring active in background"
                setShowBadge(false)
            }
            manager.createNotificationChannel(serviceChannel)

            // Critical Emergency Alert Channel (Max Priority / Loud Sound / Heavy Vibration)
            val emergencyChannel = NotificationChannel(
                EMERGENCY_CHANNEL_ID,
                "Critical SOS Emergency Alerts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Loud alarm and heads-up banner when SOS is triggered"
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 500, 200, 500, 200, 800)
                enableLights(true)
                lightColor = Color.RED
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                setBypassDnd(true)
            }
            manager.createNotificationChannel(emergencyChannel)
        }
    }

    private fun buildServiceNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE else PendingIntent.FLAG_UPDATE_CURRENT
        )

        val stopIntent = Intent(this, ResponderAlertService::class.java).apply {
            action = ACTION_STOP_MONITOR
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            10,
            stopIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE else PendingIntent.FLAG_UPDATE_CURRENT
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, SERVICE_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        builder.setSmallIcon(R.mipmap.launcher_icon)
            .setContentTitle("🛡️ SafeCommute Responder Shield: Active")
            .setContentText("Monitoring for emergency SOS alerts in background...")
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(Notification.PRIORITY_LOW)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN) {
            builder.addAction(Notification.Action.Builder(null, "STOP MONITORING", stopPendingIntent).build())
            builder.addAction(Notification.Action.Builder(null, "OPEN MAP", pendingIntent).build())
        }

        return builder.build()
    }

    private fun triggerEmergencyAlarm(title: String, body: String) {
        wakeUpDevice()
        playAlarmSound()
        triggerVibration()

        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("open_responder_map", true)
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            1,
            launchIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE else PendingIntent.FLAG_UPDATE_CURRENT
        )

        val muteIntent = Intent(this, ResponderAlertService::class.java).apply {
            action = ACTION_MUTE_ALARM
        }
        val mutePendingIntent = PendingIntent.getService(
            this,
            2,
            muteIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE else PendingIntent.FLAG_UPDATE_CURRENT
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, EMERGENCY_CHANNEL_ID)
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
            builder.addAction(Notification.Action.Builder(null, "MUTE ALARM", mutePendingIntent).build())
            builder.addAction(Notification.Action.Builder(null, "VIEW LIVE MAP", pendingIntent).build())
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            builder.setCategory(Notification.CATEGORY_ALARM)
            builder.setVisibility(Notification.VISIBILITY_PUBLIC)
        }

        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(EMERGENCY_NOTIFICATION_ID, builder.build())
    }

    private fun wakeUpDevice() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
            val wakeLock = powerManager?.newWakeLock(
                PowerManager.FULL_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP or PowerManager.ON_AFTER_RELEASE,
                "SafeCommute:EmergencyWakeLock"
            )
            wakeLock?.acquire(15000)
        } catch (_: Exception) {}
    }

    private fun playAlarmSound() {
        if (isAlarmPlaying) return
        try {
            mediaPlayer?.release()
            mediaPlayer = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .build()
                )
                try {
                    val assetFd = assets.openFd("flutter_assets/assets/siren.ogg")
                    setDataSource(assetFd.fileDescriptor, assetFd.startOffset, assetFd.length)
                    assetFd.close()
                } catch (e: Exception) {
                    val alarmUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                        ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                    setDataSource(this@ResponderAlertService, alarmUri)
                }
                isLooping = true
                prepare()
                start()
            }
            isAlarmPlaying = true
        } catch (_: Exception) {}
    }

    private fun stopAlarm() {
        try {
            if (mediaPlayer?.isPlaying == true) {
                mediaPlayer?.stop()
            }
            mediaPlayer?.release()
            mediaPlayer = null
            isAlarmPlaying = false
        } catch (_: Exception) {}
    }

    private fun triggerVibration() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vibratorManager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
                vibratorManager?.defaultVibrator?.vibrate(
                    VibrationEffect.createWaveform(longArrayOf(0, 500, 200, 500, 200, 800), -1)
                )
            } else {
                @Suppress("DEPRECATION")
                val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    vibrator?.vibrate(
                        VibrationEffect.createWaveform(longArrayOf(0, 500, 200, 500, 200, 800), -1)
                    )
                } else {
                    @Suppress("DEPRECATION")
                    vibrator?.vibrate(longArrayOf(0, 500, 200, 500, 200, 800), -1)
                }
            }
        } catch (_: Exception) {}
    }

    override fun onDestroy() {
        stopAlarm()
        isRunning = false
        super.onDestroy()
    }
}
