import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
// ignore: library_prefixes
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:permission_handler/permission_handler.dart'; // Added for SMS permission
import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'dart:io';

import 'settings.dart'; 
import 'responder_map.dart';
import 'accident_detector.dart';
import 'back_tap_detector.dart';

void main() {
  runApp(const SafeCommuteApp());
}

class SafeCommuteApp extends StatelessWidget {
  const SafeCommuteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SafeCommute',
      debugShowCheckedModeBanner: false, 
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF5F5F5), 
        primaryColor: const Color(0xFFE53935),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: IconThemeData(color: Colors.black87),
          titleTextStyle: TextStyle(color: Colors.black87, fontSize: 20, fontWeight: FontWeight.bold),
        ),
      ),
      home: const UnifiedSafetyScreen(), 
    );
  }
}

class UnifiedSafetyScreen extends StatefulWidget {
  final int initialTabIndex;
  const UnifiedSafetyScreen({super.key, this.initialTabIndex = 0});

  @override
  State<UnifiedSafetyScreen> createState() => _UnifiedSafetyScreenState();
}

class _UnifiedSafetyScreenState extends State<UnifiedSafetyScreen> {
  late int _currentTab;
  final GlobalKey<DashboardScreenState> _dashboardKey = GlobalKey<DashboardScreenState>();
  final GlobalKey<ResponderMapScreenState> _responderMapKey = GlobalKey<ResponderMapScreenState>();
  String? _selectedVictimForMap;
  static const MethodChannel _navVolumeChannel = MethodChannel('com.safecommute.app/volume');

  @override
  void initState() {
    super.initState();
    _currentTab = widget.initialTabIndex;
    _requestAppPermissions();
    _listenForNativeMapNav();
  }

  void _requestAppPermissions() async {
    try {
      await Permission.notification.request();
      await Permission.sms.request();
      await Permission.microphone.request();

      final prefs = await SharedPreferences.getInstance();
      bool backgroundEnabled = prefs.getBool('backgroundMonitoringEnabled') ?? true;
      if (backgroundEnabled) {
        await _navVolumeChannel.invokeMethod('startResponderBackgroundService');
      }
    } catch (_) {}
  }

  void _listenForNativeMapNav() {
    _navVolumeChannel.setMethodCallHandler((call) async {
      if (call.method == "openResponderMap") {
        setState(() {
          _currentTab = 1;
        });
      } else if (call.method == "onAlarmMutedExternally") {
        _responderMapKey.currentState?.muteAlarmFromExternal();
        _dashboardKey.currentState?.dismissIncomingDistressFromExternal();
      }
    });
  }

  void _onNavigateToMap(String? victim) {
    setState(() {
      _selectedVictimForMap = victim;
      _currentTab = 1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _responderMapKey.currentState?.focusVictim(victim);
    });
  }

  void _onTriggerSos() {
    _dashboardKey.currentState?.triggerSosFromExternal();
    setState(() {
      _currentTab = 0;
    });
  }

  void _onSwitchToCommuter() {
    setState(() {
      _currentTab = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentTab,
        children: [
          DashboardScreen(
            key: _dashboardKey,
            onNavigateToMap: _onNavigateToMap,
          ),
          ResponderMapScreen(
            key: _responderMapKey,
            initialVictimUsername: _selectedVictimForMap,
            onTriggerSos: _onTriggerSos,
            onSwitchToCommuter: _onSwitchToCommuter,
            isVisible: _currentTab == 1,
          ),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentTab,
        backgroundColor: Colors.white,
        elevation: 8,
        indicatorColor: _currentTab == 0
            ? Colors.redAccent.withValues(alpha: 0.18)
            : Colors.blueAccent.withValues(alpha: 0.18),
        onDestinationSelected: (index) {
          setState(() => _currentTab = index);
          if (index == 0) {
            _dashboardKey.currentState?.reloadSettings();
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.crisis_alert, color: Colors.black54),
            selectedIcon: Icon(Icons.crisis_alert, color: Colors.redAccent),
            label: 'SOS Defense',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined, color: Colors.black54),
            selectedIcon: Icon(Icons.map, color: Colors.blueAccent),
            label: 'Live Radar & Map',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined, color: Colors.black54),
            selectedIcon: Icon(Icons.settings, color: Colors.blueAccent),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  final bool autoTriggerSos;
  final String? responderInDistressUsername;
  final void Function(String? targetVictim)? onNavigateToMap;
  const DashboardScreen({
    super.key,
    this.autoTriggerSos = false,
    this.responderInDistressUsername,
    this.onNavigateToMap,
  });

  @override
  State<DashboardScreen> createState() => DashboardScreenState();
}

class DashboardScreenState extends State<DashboardScreen> with WidgetsBindingObserver {
  bool isSosActive = false;
  String batteryLevel = "Unknown";
  String locationStatus = "GPS Ready";
  Map<String, dynamic>? _incomingDistressAlert;
  
  late IO.Socket socket;
  final AudioPlayer _audioPlayer = AudioPlayer();
  Timer? _locationTimer;
  StreamSubscription<AccelerometerEvent>? _shakeSubscription;
  bool _isShakeEnabled = true;
  
  String serverUrl = 'https://safecommute-uvn5.onrender.com';
  
  static const MethodChannel _smsChannel = MethodChannel('com.safecommute.app/sms');
  static const MethodChannel _volumeChannel = MethodChannel('com.safecommute.app/volume');
  final List<DateTime> _volumePressTimestamps = [];
  final Set<String> _silencedVictims = {};

  // Incident Classification & Severity Escalation State
  int _currentSeverityLevel = 1; // 1 = Elevated, 2 = Urgent, 3 = Critical
  String _currentSeverityText = "ELEVATED";
  int _currentClicks = 3;
  String _detectedIncidentType = "PANIC_SOS";
  String _triggerSource = "MANUAL_SOS";
  double? _lastPeakGForce;
  double? _lastSpeedKmh;
  String? _lastVoiceNoteBase64;
  int _lastVoiceDurationSec = 0;
  final AudioPlayer _voicePlayer = AudioPlayer();
  bool _isPlayingVoiceNote = false;
  bool _isSosVoiceRecording = false;
  int _sosVoiceSecondsLeft = 15;
  Timer? _sosVoiceTimer;

  MobileAccidentDetector? _accidentDetector;
  BackTapDetector? _backTapDetector;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initBattery();
    _initSocket();
    _requestPermissions();
    _initShakeDetection();
    _initVolumeButtonDetection();
    _initAccidentAndBackTapDetectors();

    if (widget.autoTriggerSos) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!isSosActive) {
          toggleSOS();
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      reloadSettings();
    }
  }

  Future<void> reloadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    bool accidentEnabled = prefs.getBool('accidentDetectionEnabled') ?? false;
    bool backTapEnabled = prefs.getBool('backTapEnabled') ?? false;
    int backTapCount = prefs.getInt('backTapCount') ?? 2;
    _isShakeEnabled = prefs.getBool('shakeEnabled') ?? true;

    _accidentDetector ??= MobileAccidentDetector(
      onAccidentDetected: _onAccidentDetectedBySensors,
    );
    if (accidentEnabled) {
      _accidentDetector?.start(enabled: true);
    } else {
      _accidentDetector?.stop();
    }

    _backTapDetector ??= BackTapDetector(
      onBackTapTriggered: _onBackTapTriggered,
      enabled: backTapEnabled,
      requiredTaps: backTapCount,
    );
    if (backTapEnabled) {
      _backTapDetector?.start(enabled: true, requiredTaps: backTapCount);
    } else {
      _backTapDetector?.stop();
    }

    await _syncSettingsToNative();
  }

  void _initAccidentAndBackTapDetectors() async {
    await reloadSettings();
  }

  void _onBackTapTriggered() async {
    if (isSosActive) return;
    final prefs = await SharedPreferences.getInstance();
    bool backTapEnabled = prefs.getBool('backTapEnabled') ?? false;
    if (!backTapEnabled) {
      _backTapDetector?.stop();
      return;
    }

    HapticFeedback.heavyImpact();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("iPhone Back Tap Detected: Emergency SOS Triggered!"),
          backgroundColor: Colors.blueAccent,
          duration: Duration(seconds: 3),
        ),
      );
    }
    toggleSOS(
      severityLevel: 2,
      severityText: "URGENT",
      clickCount: 2,
      triggerSource: "BACK_TAP",
      incidentType: "BACK_TAP_SOS",
    );
  }

  void _onAccidentDetectedBySensors(AccidentTelemetry telemetry) async {
    if (isSosActive) return;
    final prefs = await SharedPreferences.getInstance();
    bool accidentEnabled = prefs.getBool('accidentDetectionEnabled') ?? false;
    if (!accidentEnabled) {
      _accidentDetector?.stop();
      return;
    }

    _showAccidentCountdownDialog(telemetry);
  }

  void _showAccidentCountdownDialog(AccidentTelemetry telemetry) {
    int countdown = 10;
    Timer? countdownTimer;
    Timer? recordingTimer;
    int recordingSecondsLeft = 15;
    bool isRecordingVoice = false;
    bool hasRecordedVoice = false;
    String? recordedVoiceBase64;
    int recordedDurationSec = 0;
    HapticFeedback.heavyImpact();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            // Only start the auto-dispatch countdown if NOT actively recording
            if (!isRecordingVoice && countdownTimer == null) {
              countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) async {
                if (countdown > 1) {
                  setDialogState(() => countdown--);
                  HapticFeedback.mediumImpact();
                } else {
                  t.cancel();
                  countdownTimer = null;
                  if (ctx.mounted) {
                    Navigator.of(ctx, rootNavigator: true).pop();
                  }
                  _triggerAccidentSos(
                    telemetry,
                    voiceBase64: recordedVoiceBase64,
                    voiceDurationSec: recordedDurationSec,
                  );
                }
              });
            }

            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Row(
                children: [
                  Text(telemetry.type.iconEmoji, style: const TextStyle(fontSize: 28)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "ACCIDENT DETECTED",
                      style: TextStyle(fontWeight: FontWeight.w900, color: Colors.red.shade900, fontSize: 16),
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    telemetry.type.displayName,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Impact G-Force: ${telemetry.peakGForce.toStringAsFixed(1)} G"
                    "${telemetry.estimatedSpeedKmh > 0 ? '\nEstimated Speed: ${telemetry.estimatedSpeedKmh.toStringAsFixed(1)} km/h' : ''}",
                    style: const TextStyle(fontSize: 13, color: Colors.black54),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: isRecordingVoice ? Colors.amber.shade50 : Colors.red.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: isRecordingVoice ? Colors.amber.shade400 : Colors.red.shade300),
                    ),
                    child: Column(
                      children: [
                        Text(
                          isRecordingVoice
                              ? "🎙️ Recording Voice Note (Countdown Paused):"
                              : "Broadcasting SOS & Incident Email in:",
                          style: TextStyle(fontSize: 12, color: isRecordingVoice ? Colors.amber.shade900 : Colors.black54),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isRecordingVoice ? "${recordingSecondsLeft}s left" : "$countdown s",
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            color: isRecordingVoice ? Colors.deepOrange.shade800 : Colors.red.shade900,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Voice Recording Box
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isRecordingVoice
                          ? Colors.red.shade100
                          : hasRecordedVoice
                              ? Colors.green.shade50
                              : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isRecordingVoice
                            ? Colors.redAccent
                            : hasRecordedVoice
                                ? Colors.green.shade400
                                : Colors.grey.shade300,
                        width: isRecordingVoice ? 1.8 : 1.0,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!isRecordingVoice && !hasRecordedVoice) ...[
                          Row(
                            children: [
                              const Icon(Icons.mic, color: Colors.redAccent, size: 22),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text("Voice Record What Happened:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                    Text("Explains situation to responders", style: TextStyle(fontSize: 9, color: Colors.black54)),
                                  ],
                                ),
                              ),
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.redAccent,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                                ),
                                icon: const Icon(Icons.fiber_manual_record, size: 12, color: Colors.white),
                                label: const Text("RECORD"),
                                onPressed: () async {
                                  try {
                                    // Pause countdown so commuter can explain clearly
                                    countdownTimer?.cancel();
                                    countdownTimer = null;

                                    await Permission.microphone.request();
                                    final started = await _volumeChannel.invokeMethod('startVoiceRecording') ?? false;
                                    if (started == true) {
                                      setDialogState(() {
                                        isRecordingVoice = true;
                                        recordingSecondsLeft = 15;
                                      });

                                      recordingTimer?.cancel();
                                      recordingTimer = Timer.periodic(const Duration(seconds: 1), (rt) async {
                                        if (recordingSecondsLeft > 1) {
                                          setDialogState(() => recordingSecondsLeft--);
                                        } else {
                                          rt.cancel();
                                          recordingTimer = null;
                                          try {
                                            final dynamic res = await _volumeChannel.invokeMethod('stopVoiceRecording');
                                            if (res is Map && res['success'] == true) {
                                              setDialogState(() {
                                                isRecordingVoice = false;
                                                hasRecordedVoice = true;
                                                recordedVoiceBase64 = res['base64']?.toString();
                                                recordedDurationSec = (res['durationSec'] as num?)?.toInt() ?? 15;
                                                countdown = 5;
                                              });
                                            } else {
                                              setDialogState(() => isRecordingVoice = false);
                                            }
                                          } catch (_) {
                                            setDialogState(() => isRecordingVoice = false);
                                          }
                                        }
                                      });
                                    }
                                  } catch (_) {}
                                },
                              ),
                            ],
                          ),
                        ] else if (isRecordingVoice) ...[
                          Row(
                            children: [
                              const Icon(Icons.record_voice_over, color: Colors.red, size: 22),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  "🔴 RECORDING... Speak now! (${recordingSecondsLeft}s)",
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.red),
                                ),
                              ),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.black87,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                                ),
                                child: const Text("SAVE & ATTACH"),
                                onPressed: () async {
                                  recordingTimer?.cancel();
                                  recordingTimer = null;
                                  try {
                                    final dynamic res = await _volumeChannel.invokeMethod('stopVoiceRecording');
                                    if (res is Map && res['success'] == true) {
                                      setDialogState(() {
                                        isRecordingVoice = false;
                                        hasRecordedVoice = true;
                                        recordedVoiceBase64 = res['base64']?.toString();
                                        recordedDurationSec = (res['durationSec'] as num?)?.toInt() ?? 0;
                                        countdown = 5; // Give 5s to review before auto-dispatch
                                      });
                                    } else {
                                      setDialogState(() => isRecordingVoice = false);
                                    }
                                  } catch (_) {
                                    setDialogState(() => isRecordingVoice = false);
                                  }
                                },
                              ),
                            ],
                          ),
                        ] else if (hasRecordedVoice) ...[
                          Row(
                            children: [
                              const Icon(Icons.check_circle, color: Colors.green, size: 20),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  "Voice Note Attached (${recordedDurationSec}s) • Ready for Responders",
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.green.shade900),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.refresh, size: 16, color: Colors.black54),
                                tooltip: "Re-record",
                                onPressed: () {
                                  countdownTimer?.cancel();
                                  countdownTimer = null;
                                  setDialogState(() {
                                    hasRecordedVoice = false;
                                    recordedVoiceBase64 = null;
                                    recordedDurationSec = 0;
                                    countdown = 10;
                                  });
                                },
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.black87,
                    side: const BorderSide(color: Colors.grey),
                  ),
                  onPressed: () async {
                    recordingTimer?.cancel();
                    countdownTimer?.cancel();
                    if (isRecordingVoice) {
                      try { await _volumeChannel.invokeMethod('stopVoiceRecording'); } catch (_) {}
                    }
                    if (ctx.mounted) {
                      Navigator.of(ctx, rootNavigator: true).pop();
                    }
                  },
                  child: const Text("I'M OKAY - CANCEL", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade900,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () async {
                    recordingTimer?.cancel();
                    countdownTimer?.cancel();
                    if (isRecordingVoice) {
                      try {
                        final dynamic res = await _volumeChannel.invokeMethod('stopVoiceRecording');
                        if (res is Map && res['success'] == true) {
                          recordedVoiceBase64 = res['base64']?.toString();
                          recordedDurationSec = (res['durationSec'] as num?)?.toInt() ?? 0;
                        }
                      } catch (_) {}
                    }
                    if (ctx.mounted) {
                      Navigator.of(ctx, rootNavigator: true).pop();
                    }
                    _triggerAccidentSos(
                      telemetry,
                      voiceBase64: recordedVoiceBase64,
                      voiceDurationSec: recordedDurationSec,
                    );
                  },
                  child: Text(
                    hasRecordedVoice ? "SEND SOS WITH VOICE" : "DISPATCH NOW",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _triggerAccidentSos(
    AccidentTelemetry telemetry, {
    String? voiceBase64,
    int? voiceDurationSec,
  }) {
    if (isSosActive) return;
    _lastPeakGForce = telemetry.peakGForce;
    _lastSpeedKmh = telemetry.estimatedSpeedKmh;
    _lastVoiceNoteBase64 = voiceBase64;
    _lastVoiceDurationSec = voiceDurationSec ?? 0;

    toggleSOS(
      incidentType: telemetry.type.code,
      severityLevel: 3,
      severityText: "CRITICAL",
      triggerSource: "ACCIDENT_DETECTOR",
      peakGForce: telemetry.peakGForce,
      speedKmh: telemetry.estimatedSpeedKmh,
      voiceBase64: voiceBase64,
      voiceDurationSec: voiceDurationSec,
    );
  }

  void _initVolumeButtonDetection() {
    _syncSettingsToNative();

    _volumeChannel.setMethodCallHandler((call) async {
      if (call.method == "triggerSosNow") {
        final prefs = await SharedPreferences.getInstance();
        bool volumeTriggerEnabled = prefs.getBool('volumeTriggerEnabled') ?? true;
        if (!volumeTriggerEnabled) return;

        final args = call.arguments as Map<dynamic, dynamic>?;
        int clicks = args?['clicks'] ?? 3;
        int level = args?['severityLevel'] ?? 1;
        String text = args?['severityText'] ?? "ELEVATED";

        if (!isSosActive) {
          HapticFeedback.heavyImpact();
          toggleSOS(
            severityLevel: level,
            severityText: text,
            clickCount: clicks,
            triggerSource: "VOLUME_BUTTON",
            incidentType: "PANIC_SOS",
          );
        } else {
          _escalateSeverity(clicks, level, text);
        }
      } else if (call.method == "onSeverityEscalated") {
        final prefs = await SharedPreferences.getInstance();
        bool volumeTriggerEnabled = prefs.getBool('volumeTriggerEnabled') ?? true;
        if (!volumeTriggerEnabled) return;

        final args = call.arguments as Map<dynamic, dynamic>?;
        int clicks = args?['clicks'] ?? 4;
        int level = args?['severityLevel'] ?? 2;
        String text = args?['severityText'] ?? "URGENT";
        _escalateSeverity(clicks, level, text);
      } else if (call.method == "onVolumePressed") {
        String direction = call.arguments as String? ?? "down";
        
        final prefs = await SharedPreferences.getInstance();
        bool volumeTriggerEnabled = prefs.getBool('volumeTriggerEnabled') ?? true;
        if (!volumeTriggerEnabled) return;

        String selectedButton = prefs.getString('volumeButtonType') ?? "down";
        int requiredClicks = prefs.getInt('volumeClickCount') ?? 3;

        if (direction == selectedButton) {
          if (isSosActive) {
            // SOS is active: Multi-click volume button escalation
            int newClicks = _currentClicks + 1;
            int newLevel = newClicks >= 6 ? 3 : (newClicks >= 4 ? 2 : _currentSeverityLevel);
            String newText = newLevel == 3 ? "CRITICAL" : (newLevel == 2 ? "URGENT" : "ELEVATED");
            _escalateSeverity(newClicks, newLevel, newText);
          } else {
            final now = DateTime.now();
            _volumePressTimestamps.add(now);
            _volumePressTimestamps.removeWhere((t) => now.difference(t).inMilliseconds > 3500);

            int totalCount = _volumePressTimestamps.length;
            if (totalCount >= requiredClicks) {
              HapticFeedback.heavyImpact();
              toggleSOS(
                severityLevel: 1,
                severityText: "ELEVATED",
                clickCount: totalCount,
                triggerSource: "VOLUME_BUTTON",
                incidentType: "PANIC_SOS",
              );
            }
          }
        }
      }
    });
  }

  void _escalateSeverity(int clicks, int level, String text) async {
    if (level < _currentSeverityLevel && clicks <= _currentClicks) return;

    setState(() {
      _currentClicks = clicks;
      _currentSeverityLevel = level;
      _currentSeverityText = text;
    });

    HapticFeedback.heavyImpact();

    final prefs = await SharedPreferences.getInstance();
    String myName = prefs.getString('username') ?? "A Commuter";

    Position? pos;
    try {
      pos = await Geolocator.getLastKnownPosition();
    } catch (_) {}

    socket.emit('encrypted_alert', {
      'targetContactId': 'all',
      'lat': pos?.latitude ?? 22.5726,
      'lng': pos?.longitude ?? 88.3639,
      'username': myName,
      'batteryMetadata': 85,
      'timestamp': DateTime.now().toIso8601String(),
      'isLiveUpdate': false,
      'incidentType': _detectedIncidentType,
      'severityLevel': _currentSeverityLevel,
      'severityText': _currentSeverityText,
      'clickCount': _currentClicks,
      'triggerSource': "VOLUME_BUTTON_ESCALATION",
      'hasVoiceNote': _lastVoiceNoteBase64 != null && _lastVoiceNoteBase64!.isNotEmpty,
      'voiceNoteBase64': _lastVoiceNoteBase64,
      'voiceNoteDuration': _lastVoiceDurationSec,
    });

    String mapLink = "https://maps.google.com/?q=${pos?.latitude ?? 22.5726},${pos?.longitude ?? 88.3639}";
    String escalatedMessage = "[SafeCommute EMERGENCY SOS] [$text - $clicks SOS PRESSES] $myName's EMERGENCY ESCALATED! Immediate help needed: $mapLink";
    _sendNativeSMS(escalatedMessage);

    _dispatchIncidentEmail(
      incidentType: _detectedIncidentType,
      severityText: text,
      severityLevel: level,
      triggerSource: "VOLUME_BUTTON_ESCALATION",
      lat: pos?.latitude ?? 22.5726,
      lng: pos?.longitude ?? 88.3639,
      clickCount: clicks,
      hasVoiceNote: _lastVoiceNoteBase64 != null && _lastVoiceNoteBase64!.isNotEmpty,
      voiceNoteDuration: _lastVoiceDurationSec,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("🚨 Priority Escalated: $text (Tier $level - $clicks presses)"),
          backgroundColor: level == 3 ? Colors.red.shade900 : Colors.deepOrange,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _dispatchIncidentEmail({
    required String incidentType,
    required String severityText,
    required int severityLevel,
    required String triggerSource,
    required double lat,
    required double lng,
    double? peakGForce,
    double? speedKmh,
    int? clickCount,
    bool hasVoiceNote = false,
    int voiceNoteDuration = 0,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    String myName = prefs.getString('username') ?? "A Commuter";
    String recipientEmail = prefs.getString('emergencyEmail') ?? "";

    final emailPayload = {
      'recipientEmail': recipientEmail.isNotEmpty ? recipientEmail : 'emergency-dispatch@safecommute.internal',
      'username': myName,
      'incidentType': incidentType,
      'severityText': severityText,
      'severityLevel': severityLevel,
      'triggerSource': triggerSource,
      'lat': lat,
      'lng': lng,
      'peakGForce': peakGForce,
      'speedKmh': speedKmh,
      'clickCount': clickCount ?? 3,
      'hasVoiceNote': hasVoiceNote,
      'voiceNoteDuration': voiceNoteDuration,
      'timestamp': DateTime.now().toIso8601String(),
    };

    socket.emit('incident_email_dispatch', emailPayload);
    debugPrint("[EMAIL DISPATCH] Automated Incident Email dispatched to relay server.");
  }

  Future<void> _syncSettingsToNative() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      bool enabled = prefs.getBool('volumeTriggerEnabled') ?? true;
      String buttonType = prefs.getString('volumeButtonType') ?? "down";
      int clickCount = prefs.getInt('volumeClickCount') ?? 3;
      String username = prefs.getString('username') ?? "A Commuter";
      List<String> contacts = prefs.getStringList('savedContacts') ?? [];

      await _volumeChannel.invokeMethod('syncSettings', {
        'enabled': enabled,
        'buttonType': buttonType,
        'clickCount': clickCount,
        'username': username,
        'contacts': contacts,
      });
    } catch (_) {}
  }

  void _initShakeDetection() {
    _shakeSubscription = accelerometerEventStream().listen((AccelerometerEvent event) async {
      if (!_isShakeEnabled || isSosActive) return; 
      
      double gForce = sqrt(event.x * event.x + event.y * event.y + event.z * event.z) / 9.8;
      
      if (gForce > 3.0) {
        final prefs = await SharedPreferences.getInstance();
        bool shakeEnabled = prefs.getBool('shakeEnabled') ?? true;
        if (shakeEnabled) {
          toggleSOS();
        }
      }
    });
  }

  Future<void> _requestPermissions() async {
    // 1. Request Location Permission
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      await Geolocator.requestPermission();
    }
    
    // 2. Request SMS Permission at Runtime
    if (await Permission.sms.isDenied) {
      await Permission.sms.request();
    }

    // 3. Request Microphone Permission Upfront for Voice Messages
    if (await Permission.microphone.isDenied) {
      await Permission.microphone.request();
    }
  }

  Future<void> _initBattery() async {
    var battery = Battery();
    int level = await battery.batteryLevel;
    setState(() {
      batteryLevel = "$level%";
    });
  }

  Future<void> _initSocket() async {
    final prefs = await SharedPreferences.getInstance();
    serverUrl = prefs.getString('serverUrl') ?? 'https://safecommute-uvn5.onrender.com';
    socket = IO.io(serverUrl, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
    });
    socket.onConnect((_) => debugPrint("Connected to Backend Server: $serverUrl"));

    // Incoming alerts from other users / responders in distress
    socket.on('incoming_alert', (payload) async {
      if (!isSosActive && mounted) {
        final alertData = payload is Map<String, dynamic>
            ? payload
            : Map<String, dynamic>.from(payload as Map);

        final String victimName = alertData['username']?.toString() ?? "Someone";
        final bool isLiveUpdate = alertData['isLiveUpdate'] == true;

        // If this is a fresh emergency dispatch, un-silence so the alarm rings loud:
        if (!isLiveUpdate) {
          _silencedVictims.remove(victimName);
        }

        // 1. If currently silenced for this specific session and it's not a fresh alert:
        if (_silencedVictims.contains(victimName) && isLiveUpdate) {
          return;
        }

        // 2. Proximity Distance Calculation (Informational):
        if (alertData['lat'] != null && alertData['lng'] != null) {
          try {
            Position? currentPos = await Geolocator.getLastKnownPosition();
            double? distM;
            if (currentPos != null) {
              distM = Geolocator.distanceBetween(
                currentPos.latitude,
                currentPos.longitude,
                (alertData['lat'] as num).toDouble(),
                (alertData['lng'] as num).toDouble(),
              );
            }
            if (distM != null) {
              alertData['distanceText'] = distM < 1000
                  ? "${distM.round()} m away"
                  : "${(distM / 1000).toStringAsFixed(1)} km away";
            } else {
              alertData['distanceText'] = "Nearest Dispatch (GPS Offline)";
            }
          } catch (_) {
            alertData['distanceText'] = "Nearest Dispatch (GPS Offline)";
          }
        } else {
          alertData['distanceText'] = "Nearest Dispatch";
        }

        // 3. If continuous live GPS streaming update:
        if (isLiveUpdate) {
          // Update coordinates quietly on banner if already open, but NEVER re-ring notifications:
          if (_incomingDistressAlert != null && _incomingDistressAlert!['username'] == victimName) {
            setState(() {
              _incomingDistressAlert = alertData;
            });
          }
          return;
        }

        // 4. If already showing distress banner for this victim, update data:
        setState(() {
          _incomingDistressAlert = alertData;
        });
        HapticFeedback.heavyImpact();

        // 5. Trigger native heads-up emergency notification & alarm
        try {
          String dist = alertData['distanceText'] ?? "Nearest Dispatch";
          String incident = alertData['incidentType'] == "VEHICLE_CRASH"
              ? "🚗 Vehicle Crash"
              : alertData['incidentType'] == "HARD_FALL"
                  ? "⚠️ Hard Fall"
                  : alertData['incidentType'] == "PHYSICAL_ASSAULT"
                      ? "🚨 Assault / Struggle"
                      : alertData['incidentType'] == "BACK_TAP_SOS"
                          ? "📱 Back Tap SOS"
                          : "🚨 EMERGENCY SOS";
          String voiceNotice = alertData['hasVoiceNote'] == true ? " • 🎙️ Voice Note Attached" : "";
          await _volumeChannel.invokeMethod('showEmergencyNotification', {
            'title': "$incident: $victimName NEEDS HELP!",
            'body': "$victimName triggered emergency SOS ($dist)$voiceNotice! Tap to view Live GPS Radar.",
            'victimId': victimName,
            'hasVoiceNote': alertData['hasVoiceNote'] == true,
          });
        } catch (_) {}
      }
    });

    // Dedicated Emergency Voice Message from another Commuter
    socket.on('emergency_voice_note', (payload) async {
      if (!isSosActive && mounted) {
        final alertData = payload is Map<String, dynamic>
            ? payload
            : Map<String, dynamic>.from(payload as Map);

        final String victimName = alertData['username']?.toString() ?? "Someone";
        final int duration = (alertData['voiceNoteDuration'] as num?)?.toInt() ?? 0;
        final String? b64 = alertData['voiceNoteBase64']?.toString();

        _silencedVictims.remove(victimName);
        setState(() {
          if (_incomingDistressAlert != null && _incomingDistressAlert!['username'] == victimName) {
            _incomingDistressAlert!['hasVoiceNote'] = true;
            _incomingDistressAlert!['voiceNoteBase64'] = b64;
            _incomingDistressAlert!['voiceNoteDuration'] = duration;
          } else {
            _incomingDistressAlert = {
              ...alertData,
              'hasVoiceNote': true,
              'voiceNoteBase64': b64,
              'voiceNoteDuration': duration,
              'distanceText': "Nearest Dispatch",
            };
          }
        });

        HapticFeedback.heavyImpact();

        try {
          await _volumeChannel.invokeMethod('showEmergencyNotification', {
            'title': "🎙️ EMERGENCY VOICE: $victimName Sent Audio!",
            'body': "$victimName recorded an emergency voice note ($duration s). Tap to listen now!",
            'victimId': victimName,
            'hasVoiceNote': true,
          });
        } catch (_) {}

        if (b64 != null && b64.isNotEmpty) {
          _playVictimVoiceNote(b64);
        }
      }
    });

    socket.on('alert_cancelled', (payload) {
      if (mounted) {
        String cancelledUser = payload['username']?.toString() ?? "";
        _silencedVictims.remove(cancelledUser);
        try {
          _volumeChannel.invokeMethod('unmuteEmergencyAlarm', {
            'victimId': cancelledUser,
          });
        } catch (_) {}
        if (_incomingDistressAlert != null &&
            (_incomingDistressAlert!['username'] == cancelledUser || cancelledUser.isEmpty)) {
          _dismissIncomingDistressAlert();
        }
      }
    });
  }

  void dismissIncomingDistressFromExternal() {
    if (mounted) {
      if (_incomingDistressAlert != null) {
        String? victim = _incomingDistressAlert!['username']?.toString();
        if (victim != null && victim.isNotEmpty) {
          _silencedVictims.add(victim);
        }
      }
      setState(() => _incomingDistressAlert = null);
    }
  }

  void _dismissIncomingDistressAlert() {
    String? victim = _incomingDistressAlert?['username']?.toString();
    if (victim != null && victim.isNotEmpty) {
      _silencedVictims.add(victim);
    }
    setState(() => _incomingDistressAlert = null);
    try {
      _volumeChannel.invokeMethod('cancelEmergencyNotification', {
        'victimId': victim ?? '',
      });
    } catch (_) {}
    try {
      _volumeChannel.invokeMethod('muteEmergencyAlarm', {
        'victimId': victim ?? '',
      });
    } catch (_) {}
  }

  void triggerSosFromExternal() {
    if (!isSosActive) {
      HapticFeedback.heavyImpact();
      toggleSOS();
    }
  }

  Future<void> _switchToResponder({String? targetVictim}) async {
    if (isSosActive) {
      final shouldSwitch = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 26),
              SizedBox(width: 8),
              Text("SOS is Active!", style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          content: const Text(
            "You have an ongoing emergency SOS. Do you want to cancel your SOS and switch to Responder mode to assist?",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Keep SOS Active"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("Cancel SOS & Switch", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );

      if (shouldSwitch != true) return;
      await _stopActiveDefense();
      setState(() => isSosActive = false);
    }

    if (widget.onNavigateToMap != null) {
      widget.onNavigateToMap!(targetVictim);
      return;
    }

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => ResponderMapScreen(initialVictimUsername: targetVictim),
      ),
    );
  }

  Future<void> _playVictimVoiceNote(dynamic base64Str) async {
    if (base64Str == null) return;
    try {
      if (_isPlayingVoiceNote) {
        await _voicePlayer.stop();
        setState(() => _isPlayingVoiceNote = false);
        return;
      }
      setState(() => _isPlayingVoiceNote = true);
      final bytes = base64Decode(base64Str.toString());
      final tempFile = File('${Directory.systemTemp.path}/victim_voice_${DateTime.now().millisecondsSinceEpoch}.m4a');
      await tempFile.writeAsBytes(bytes);
      await _voicePlayer.play(DeviceFileSource(tempFile.path));
      _voicePlayer.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _isPlayingVoiceNote = false);
      });
    } catch (_) {
      if (mounted) setState(() => _isPlayingVoiceNote = false);
    }
  }

  Future<void> _startSosVoiceMessageRecording() async {
    try {
      await Permission.microphone.request();
      final started = await _volumeChannel.invokeMethod('startVoiceRecording') ?? false;
      if (started == true) {
        setState(() {
          _isSosVoiceRecording = true;
          _sosVoiceSecondsLeft = 15;
        });
        HapticFeedback.mediumImpact();
        _sosVoiceTimer?.cancel();
        _sosVoiceTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (_sosVoiceSecondsLeft > 1) {
            setState(() => _sosVoiceSecondsLeft--);
          } else {
            timer.cancel();
            _stopAndSendSosVoiceMessage();
          }
        });
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Microphone permission required to record emergency audio."),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint("Failed to start SOS voice recording: $e");
    }
  }

  Future<void> _stopAndSendSosVoiceMessage() async {
    _sosVoiceTimer?.cancel();
    _sosVoiceTimer = null;
    try {
      final dynamic res = await _volumeChannel.invokeMethod('stopVoiceRecording');
      if (res is Map && res['success'] == true) {
        final b64 = res['base64']?.toString();
        final duration = (res['durationSec'] as num?)?.toInt() ?? 15;

        if (b64 != null && b64.isNotEmpty) {
          setState(() {
            _isSosVoiceRecording = false;
            _lastVoiceNoteBase64 = b64;
            _lastVoiceDurationSec = duration;
          });

          final prefs = await SharedPreferences.getInstance();
          String myName = prefs.getString('username') ?? "A Commuter";
          if (myName.trim().isEmpty) myName = "A Commuter";

          Position? currentPos;
          try {
            currentPos = await Geolocator.getLastKnownPosition();
          } catch (_) {}

          double lat = currentPos?.latitude ?? 22.5726;
          double lng = currentPos?.longitude ?? 88.3639;

          // Instant socket dispatch of voice note to all responders
          socket.emit('emergency_voice_note', {
            'username': myName,
            'voiceNoteBase64': b64,
            'voiceNoteDuration': duration,
            'lat': lat,
            'lng': lng,
            'batteryMetadata': batteryLevel,
            'incidentType': _detectedIncidentType,
            'severityLevel': _currentSeverityLevel,
            'severityText': _currentSeverityText,
            'clickCount': _currentClicks,
            'triggerSource': _triggerSource,
            'timestamp': DateTime.now().toIso8601String(),
          });

          // If SOS is not active yet, arm SOS Tier 2 with voice note
          if (!isSosActive) {
            toggleSOS(
              severityLevel: 2,
              severityText: "URGENT",
              triggerSource: "VOICE_SOS",
              incidentType: "VOICE_SOS",
              voiceBase64: b64,
              voiceDurationSec: duration,
            );
          }

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: Colors.green.shade800,
                content: Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text("🎙️ Emergency Voice Message (${duration}s) sent to all responders!"),
                    ),
                  ],
                ),
                duration: const Duration(seconds: 4),
              ),
            );
          }
        } else {
          setState(() => _isSosVoiceRecording = false);
        }
      } else {
        setState(() => _isSosVoiceRecording = false);
      }
    } catch (e) {
      setState(() => _isSosVoiceRecording = false);
      debugPrint("Failed to stop voice recording: $e");
    }
  }

  Future<void> _cancelSosVoiceMessage() async {
    _sosVoiceTimer?.cancel();
    _sosVoiceTimer = null;
    try {
      await _volumeChannel.invokeMethod('stopVoiceRecording');
    } catch (_) {}
    setState(() {
      _isSosVoiceRecording = false;
    });
  }

  Future<void> _sendNativeSMS(String message) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> savedContacts = prefs.getStringList('savedContacts') ?? [];
    
    // Nearest Contact Dispatch Policy:
    // If <= 3 contacts: send to all (intimate trusted circle).
    // If > 3 contacts: send to the primary top 3 contacts to prevent widespread alarm.
    List<String> targetContacts = savedContacts.length <= 3 
        ? savedContacts 
        : savedContacts.take(3).toList();

    for (String contactInfo in targetContacts) {
      // Extract just the phone number from "Name: Phone" format
      List<String> parts = contactInfo.split(': ');
      if (parts.length > 1) {
        String phone = parts[1].trim();
        try {
          final String result = await _smsChannel.invokeMethod('sendSMS', {
            'phone': phone,
            'message': message,
          });
          debugPrint(result);
        } catch (e) {
          debugPrint("Failed to send SMS to $phone: $e");
        }
      }
    }
  }

  Future<void> _startActiveDefense({
    String? voiceBase64,
    int? voiceDurationSec,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    bool sirenEnabled = prefs.getBool('sirenEnabled') ?? true;
    String myName = prefs.getString('username') ?? "A Commuter";
    if (myName.trim().isEmpty) myName = "A Commuter";

    // 1. Instant coordinates from device cache (<10ms)
    double initialLat = 22.5726;
    double initialLng = 88.3639;
    try {
      Position? cachedPos = await Geolocator.getLastKnownPosition();
      if (cachedPos != null) {
        initialLat = cachedPos.latitude;
        initialLng = cachedPos.longitude;
      }
    } catch (_) {}

    var battery = Battery();
    int batteryLevelVal = 85;
    try {
      batteryLevelVal = await battery.batteryLevel;
    } catch (_) {}

    final effectiveVoiceBase64 = voiceBase64 ?? _lastVoiceNoteBase64;
    final effectiveVoiceDuration = voiceDurationSec ?? _lastVoiceDurationSec;

    // 2. IMMEDIATE ZERO-DELAY SOCKET SOS BROADCAST (Millisecond 0):
    // Alerts all nearby responders instantly without waiting for GPS lock or SMS loop!
    socket.emit('encrypted_alert', {
      'targetContactId': 'all',
      'lat': initialLat,
      'lng': initialLng,
      'username': myName,
      'batteryMetadata': batteryLevelVal,
      'timestamp': DateTime.now().toIso8601String(),
      'isLiveUpdate': false,
      'incidentType': _detectedIncidentType,
      'severityLevel': _currentSeverityLevel,
      'severityText': _currentSeverityText,
      'clickCount': _currentClicks,
      'triggerSource': _triggerSource,
      'peakGForce': _lastPeakGForce,
      'speedKmh': _lastSpeedKmh,
      'hasVoiceNote': effectiveVoiceBase64 != null && effectiveVoiceBase64.isNotEmpty,
      'voiceNoteBase64': effectiveVoiceBase64,
      'voiceNoteDuration': effectiveVoiceDuration,
    });
    debugPrint("[INSTANT SOS] Broadcast emitted in <20ms to all nearby responders!");

    // 3. START LOUD SIREN (Non-blocking)
    if (sirenEnabled) {
      _audioPlayer.setReleaseMode(ReleaseMode.loop);
      _audioPlayer.play(AssetSource('siren.ogg')).catchError((_) {});
    }

    // 4. DISPATCH NATIVE SMS ASYNCHRONOUSLY (Non-blocking)
    String mapLink = "https://maps.google.com/?q=$initialLat,$initialLng";
    String emergencyMessage = _currentSeverityLevel == 3
        ? "[SafeCommute EMERGENCY SOS] [CRITICAL - $_detectedIncidentType - $_currentClicks PRESSES] $myName in SEVERE DANGER! Live GPS: $mapLink"
        : _currentSeverityLevel == 2
            ? "[SafeCommute EMERGENCY SOS] [URGENT - $_detectedIncidentType - $_currentClicks PRESSES] $myName needs help! Live GPS: $mapLink"
            : "[SafeCommute EMERGENCY SOS] $myName's EMERGENCY! I need help. My live location: $mapLink";
    _sendNativeSMS(emergencyMessage);

    // 4b. DISPATCH AUTOMATED INCIDENT EMAIL REPORT
    _dispatchIncidentEmail(
      incidentType: _detectedIncidentType,
      severityText: _currentSeverityText,
      severityLevel: _currentSeverityLevel,
      triggerSource: _triggerSource,
      lat: initialLat,
      lng: initialLng,
      peakGForce: _lastPeakGForce,
      speedKmh: _lastSpeedKmh,
      clickCount: _currentClicks,
      hasVoiceNote: effectiveVoiceBase64 != null && effectiveVoiceBase64.isNotEmpty,
      voiceNoteDuration: effectiveVoiceDuration,
    );

    // 5. ASYNC HIGH-ACCURACY GPS REFINEMENT & CONTINUOUS 4s STREAMING
    Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    ).then((pos) {
      _accidentDetector?.updateSpeed(pos.speed);
      if (isSosActive && mounted) {
        setState(() {
          locationStatus = "Lat: ${pos.latitude.toStringAsFixed(4)}, Lng: ${pos.longitude.toStringAsFixed(4)}";
        });
        socket.emit('encrypted_alert', {
          'targetContactId': 'all',
          'lat': pos.latitude,
          'lng': pos.longitude,
          'username': myName,
          'batteryMetadata': batteryLevelVal,
          'timestamp': DateTime.now().toIso8601String(),
          'isLiveUpdate': true,
          'incidentType': _detectedIncidentType,
          'severityLevel': _currentSeverityLevel,
          'severityText': _currentSeverityText,
          'clickCount': _currentClicks,
          'triggerSource': _triggerSource,
          'hasVoiceNote': _lastVoiceNoteBase64 != null && _lastVoiceNoteBase64!.isNotEmpty,
          'voiceNoteBase64': _lastVoiceNoteBase64,
          'voiceNoteDuration': _lastVoiceDurationSec,
        });
      }
    }).catchError((_) {});

    _locationTimer = Timer.periodic(const Duration(seconds: 4), (timer) async {
      try {
        Position position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
        );
        _accidentDetector?.updateSpeed(position.speed);
        if (mounted) {
          setState(() {
            locationStatus = "Lat: ${position.latitude.toStringAsFixed(4)}, Lng: ${position.longitude.toStringAsFixed(4)}";
          });
        }
        
        int level = batteryLevelVal;
        try {
          level = await battery.batteryLevel;
        } catch (_) {}
        
        socket.emit('encrypted_alert', {
          'targetContactId': 'all',
          'lat': position.latitude,
          'lng': position.longitude,
          'username': myName,
          'batteryMetadata': level,
          'timestamp': DateTime.now().toIso8601String(),
          'isLiveUpdate': true,
          'incidentType': _detectedIncidentType,
          'severityLevel': _currentSeverityLevel,
          'severityText': _currentSeverityText,
          'clickCount': _currentClicks,
          'triggerSource': _triggerSource,
          'hasVoiceNote': _lastVoiceNoteBase64 != null && _lastVoiceNoteBase64!.isNotEmpty,
          'voiceNoteBase64': _lastVoiceNoteBase64,
          'voiceNoteDuration': _lastVoiceDurationSec,
        });
      } catch (e) {
        if (mounted) {
          setState(() {
            locationStatus = "GPS Searching...";
          });
        }
      }
    });
  }

  Future<void> _stopActiveDefense() async {
    // 1. Stop Siren
    await _audioPlayer.stop();
    // 2. Stop Tracking & Voice Recording
    _locationTimer?.cancel();
    _sosVoiceTimer?.cancel();
    if (_isSosVoiceRecording) {
      try { await _volumeChannel.invokeMethod('stopVoiceRecording'); } catch (_) {}
    }
    setState(() {
      locationStatus = "GPS Ready";
      _currentSeverityLevel = 1;
      _currentSeverityText = "ELEVATED";
      _currentClicks = 3;
      _detectedIncidentType = "PANIC_SOS";
      _triggerSource = "MANUAL_SOS";
      _isSosVoiceRecording = false;
      _lastVoiceNoteBase64 = null;
      _lastVoiceDurationSec = 0;
    });

    // 3. Notify server and responders that emergency is resolved
    final prefs = await SharedPreferences.getInstance();
    String myName = prefs.getString('username') ?? "A Commuter";
    socket.emit('cancel_alert', {
      'username': myName,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  void toggleSOS({
    int severityLevel = 1,
    String severityText = "ELEVATED",
    int clickCount = 3,
    String triggerSource = "MANUAL_SOS",
    String incidentType = "PANIC_SOS",
    double? peakGForce,
    double? speedKmh,
    String? voiceBase64,
    int? voiceDurationSec,
  }) async {
    setState(() {
      isSosActive = !isSosActive;
      if (isSosActive) {
        _currentSeverityLevel = severityLevel;
        _currentSeverityText = severityText;
        _currentClicks = clickCount;
        _triggerSource = triggerSource;
        _detectedIncidentType = incidentType;
        _lastPeakGForce = peakGForce;
        _lastSpeedKmh = speedKmh;
        _lastVoiceNoteBase64 = voiceBase64;
        _lastVoiceDurationSec = voiceDurationSec ?? 0;
      }
    });
    
    if (isSosActive) {
      await _startActiveDefense(
        voiceBase64: voiceBase64,
        voiceDurationSec: voiceDurationSec,
      );
    } else {
      await _stopActiveDefense();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _audioPlayer.dispose();
    _voicePlayer.dispose();
    _locationTimer?.cancel();
    _shakeSubscription?.cancel();
    _accidentDetector?.stop();
    _backTapDetector?.stop();
    socket.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SafeCommute', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          // Rapid Dual-Role Switch Button: Instant transition to Responder Mode
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 4.0),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              ),
              icon: const Icon(Icons.shield, size: 16, color: Colors.white),
              label: const Text(
                "Responder Map",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
              onPressed: () => _switchToResponder(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: "Settings",
            onPressed: () async {
              // Navigate to Settings Screen and reload immediately on return
              await Navigator.push(context, MaterialPageRoute(builder: (context) => const SettingsScreen()));
              await reloadSettings();
            },
          )
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Instant Distress Alert Banner for Commuter (Commuter becomes Responder)
            if (_incomingDistressAlert != null && !isSosActive)
              Container(
                margin: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.red.shade900, Colors.redAccent.shade700],
                  ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.redAccent.withValues(alpha: 0.4),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.crisis_alert, color: Colors.white, size: 24),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "🚨 [${_incomingDistressAlert!['severityText'] ?? 'CRITICAL'}]: ${_incomingDistressAlert!['username'] ?? 'Someone'} NEEDS HELP!",
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            "${_incomingDistressAlert!['incidentType'] == 'VEHICLE_CRASH' ? '🚗 Vehicle Crash' : _incomingDistressAlert!['incidentType'] == 'HARD_FALL' ? '⚠️ Hard Fall' : _incomingDistressAlert!['incidentType'] == 'PHYSICAL_ASSAULT' ? '🚨 Violent Struggle' : '🆘 Emergency SOS'} • ${_incomingDistressAlert!['distanceText'] ?? 'Nearby'}",
                            style: const TextStyle(color: Colors.white70, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (_incomingDistressAlert!['hasVoiceNote'] == true &&
                        _incomingDistressAlert!['voiceNoteBase64'] != null) ...[
                      IconButton(
                        icon: Icon(
                          _isPlayingVoiceNote ? Icons.stop_circle : Icons.play_circle_fill,
                          color: Colors.amberAccent,
                          size: 28,
                        ),
                        tooltip: "Play Victim's Voice Message",
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () => _playVictimVoiceNote(_incomingDistressAlert!['voiceNoteBase64']),
                      ),
                      const SizedBox(width: 8),
                    ],
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.red.shade900,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () {
                        final victim = _incomingDistressAlert!['username']?.toString();
                        _dismissIncomingDistressAlert();
                        _switchToResponder(targetVictim: victim);
                      },
                      child: const Text(
                        "RESPOND",
                        style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11),
                      ),
                    ),
                    const SizedBox(width: 6),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white70),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: _dismissIncomingDistressAlert,
                      child: const Text(
                        "STOP ALARM",
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                      ),
                    ),
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: _dismissIncomingDistressAlert,
                      child: const Icon(Icons.close, color: Colors.white70, size: 18),
                    ),
                  ],
                ),
              ),

            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        isSosActive
                            ? "🚨 TIER $_currentSeverityLevel: $_currentSeverityText"
                            : "READY TO TRACK",
                        style: TextStyle(
                          color: isSosActive ? Colors.redAccent : Colors.black54,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                      if (isSosActive) ...[
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(
                            color: _currentSeverityLevel == 3
                                ? Colors.red.shade900
                                : _currentSeverityLevel == 2
                                    ? Colors.orange.shade800
                                    : Colors.red.shade700,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _detectedIncidentType == "VEHICLE_CRASH"
                                ? "🚗 Vehicle Crash Detected"
                                : _detectedIncidentType == "HARD_FALL"
                                    ? "⚠️ Hard Fall Detected"
                                    : _detectedIncidentType == "PHYSICAL_ASSAULT"
                                        ? "🚨 Struggle / Assault Detected"
                                        : _detectedIncidentType == "BACK_TAP_SOS"
                                            ? " iPhone Back Tap SOS"
                                            : "🆘 Panic SOS ($_currentClicks Clicks)",
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                          ),
                        ),
                      ],
                      const SizedBox(height: 30),

                      // Pulsing SOS Button
                      GestureDetector(
                        onTap: toggleSOS,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          height: 200,
                          width: 200,
                          decoration: BoxDecoration(
                            color: isSosActive ? Colors.red[800] : const Color(0xFFE53935),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: isSosActive ? Colors.red.withValues(alpha: 0.9) : Colors.red.withValues(alpha: 0.3),
                                blurRadius: isSosActive ? 50 : 20,
                                spreadRadius: isSosActive ? 15 : 5,
                              )
                            ],
                          ),
                          child: Center(
                            child: Text(
                              isSosActive ? "CANCEL" : "SOS",
                              style: const TextStyle(
                                fontSize: 44,
                                fontWeight: FontWeight.w900,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 24),

                      // Dedicated Emergency Voice Message Card
                      _buildEmergencyVoiceCard(),

                      const SizedBox(height: 20),

                      // Telemetry Readouts
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, spreadRadius: 2)
                          ]
                        ),
                        child: Column(
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.battery_charging_full, color: Colors.green, size: 20),
                                const SizedBox(width: 8),
                                Text("Battery Level: $batteryLevel", style: const TextStyle(color: Colors.black87, fontSize: 16, fontWeight: FontWeight.w500)),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.location_on, color: isSosActive ? Colors.redAccent : Colors.blueAccent, size: 20),
                                const SizedBox(width: 8),
                                Text(locationStatus, style: const TextStyle(color: Colors.black87, fontSize: 16, fontWeight: FontWeight.w500)),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      // SafeCommute Active Shield Status Card
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 20),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: isSosActive ? Colors.red.shade50 : Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSosActive ? Colors.redAccent : Colors.green.shade200,
                            width: isSosActive ? 1.5 : 1.0,
                          ),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
                          ],
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Icon(
                                  isSosActive ? Icons.crisis_alert : Icons.verified_user,
                                  color: isSosActive ? Colors.redAccent : Colors.green,
                                  size: 22,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    isSosActive ? "EMERGENCY BROADCAST ACTIVE" : "SafeCommute Active Defense",
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: isSosActive ? Colors.red.shade900 : Colors.black87,
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: isSosActive ? Colors.redAccent : Colors.green.shade50,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: isSosActive ? Colors.redAccent : Colors.green.shade300),
                                  ),
                                  child: Text(
                                    isSosActive ? "PRIORITY: $_currentSeverityText ($_currentClicks CLICKS)" : "ARMED",
                                    style: TextStyle(
                                      color: isSosActive ? Colors.white : Colors.green.shade800,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              isSosActive
                                  ? "Broadcasting live GPS telemetry, incident classification ($_detectedIncidentType) & siren alarms to nearest responders. Emergency email & SMS dispatched."
                                  : "Ready for immediate protection. Trigger via big SOS button, volume clicks (3x-6x priority escalation),  iPhone Back Tap, or automatic vehicle crash & fall detection.",
                              style: TextStyle(
                                fontSize: 11,
                                color: isSosActive ? Colors.red.shade900 : Colors.black54,
                                height: 1.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmergencyVoiceCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _isSosVoiceRecording
            ? Colors.red.shade50
            : (_lastVoiceNoteBase64 != null ? Colors.amber.shade50 : Colors.white),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _isSosVoiceRecording
              ? Colors.redAccent
              : (_lastVoiceNoteBase64 != null ? Colors.amber.shade600 : Colors.grey.shade300),
          width: _isSosVoiceRecording ? 1.8 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: _isSosVoiceRecording
                ? Colors.redAccent.withValues(alpha: 0.2)
                : Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: _isSosVoiceRecording
                      ? Colors.redAccent
                      : (_lastVoiceNoteBase64 != null ? Colors.amber.shade700 : Colors.blueGrey.shade700),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _isSosVoiceRecording
                      ? Icons.mic
                      : (_lastVoiceNoteBase64 != null ? Icons.mic_external_on : Icons.mic_none),
                  color: Colors.white,
                  size: 18,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isSosVoiceRecording
                          ? "RECORDING EMERGENCY VOICE MESSAGE"
                          : (_lastVoiceNoteBase64 != null
                              ? "VOICE MESSAGE ATTACHED (${_lastVoiceDurationSec}s)"
                              : "EMERGENCY VOICE MESSAGE"),
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 11.5,
                        color: _isSosVoiceRecording
                            ? Colors.red.shade900
                            : (_lastVoiceNoteBase64 != null ? Colors.amber.shade900 : Colors.black87),
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      _isSosVoiceRecording
                          ? "Speaking into mic... Responders will receive this immediately."
                          : (_lastVoiceNoteBase64 != null
                              ? "Dispatched to nearby responders & attached to SOS."
                              : "Record an explanation for responders of what is happening."),
                      style: const TextStyle(fontSize: 10, color: Colors.black54),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_isSosVoiceRecording) ...[
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.red.shade100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: Text(
                        "🔴 RECORDING: $_sosVoiceSecondsLeft s remaining",
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: Colors.red.shade900,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade900,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.send, size: 14),
                  label: const Text("SEND NOW", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                  onPressed: _stopAndSendSosVoiceMessage,
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.black54, size: 18),
                  tooltip: "Cancel",
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: _cancelSosVoiceMessage,
                ),
              ],
            ),
          ] else ...[
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _lastVoiceNoteBase64 != null ? Colors.amber.shade800 : Colors.red.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: Icon(
                      _lastVoiceNoteBase64 != null ? Icons.refresh : Icons.fiber_manual_record,
                      size: 14,
                    ),
                    label: Text(
                      _lastVoiceNoteBase64 != null
                          ? "RE-RECORD EXPLANATION"
                          : "🎙️ RECORD EMERGENCY VOICE MESSAGE (15s)",
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                    ),
                    onPressed: _startSosVoiceMessageRecording,
                  ),
                ),
                if (_lastVoiceNoteBase64 != null) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.amber.shade900,
                      side: BorderSide(color: Colors.amber.shade800),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: Icon(_isPlayingVoiceNote ? Icons.stop : Icons.play_arrow, size: 14),
                    label: Text(_isPlayingVoiceNote ? "STOP" : "PREVIEW", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                    onPressed: () => _playVictimVoiceNote(_lastVoiceNoteBase64),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}
