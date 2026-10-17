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

import 'settings.dart'; 
import 'role_screen.dart'; 
import 'responder_map.dart';

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
      home: const RoleCheckScreen(), 
    );
  }
}

class RoleCheckScreen extends StatefulWidget {
  const RoleCheckScreen({super.key});

  @override
  State<RoleCheckScreen> createState() => _RoleCheckScreenState();
}

class _RoleCheckScreenState extends State<RoleCheckScreen> {
  @override
  void initState() {
    super.initState();
    _checkSavedRole();
  }

  Future<void> _checkSavedRole() async {
    final prefs = await SharedPreferences.getInstance();
    final role = prefs.getString('userRole');
    if (!mounted) return;

    if (role == 'commuter') {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const DashboardScreen()),
      );
    } else if (role == 'responder') {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const ResponderMapScreen()),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const RoleSelectionScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFFF5F5F5),
      body: Center(
        child: CircularProgressIndicator(color: Colors.redAccent),
      ),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  final bool autoTriggerSos;
  final String? responderInDistressUsername;
  const DashboardScreen({
    super.key,
    this.autoTriggerSos = false,
    this.responderInDistressUsername,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool isSosActive = false;
  String batteryLevel = "Unknown";
  String locationStatus = "GPS Ready";
  Map<String, dynamic>? _incomingDistressAlert;
  
  late IO.Socket socket;
  final AudioPlayer _audioPlayer = AudioPlayer();
  Timer? _locationTimer;
  StreamSubscription<AccelerometerEvent>? _shakeSubscription;
  
  String serverUrl = 'https://safecommute-uvn5.onrender.com';
  
  static const MethodChannel _smsChannel = MethodChannel('com.safecommute.app/sms');
  static const MethodChannel _volumeChannel = MethodChannel('com.safecommute.app/volume');
  final List<DateTime> _volumePressTimestamps = [];

  @override
  void initState() {
    super.initState();
    _initBattery();
    _initSocket();
    _requestPermissions();
    _initShakeDetection();
    _initVolumeButtonDetection();

    if (widget.autoTriggerSos) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!isSosActive) {
          toggleSOS();
        }
      });
    }
  }

  void _initVolumeButtonDetection() {
    _syncSettingsToNative();

    _volumeChannel.setMethodCallHandler((call) async {
      if (call.method == "triggerSosNow") {
        if (!isSosActive) {
          HapticFeedback.heavyImpact();
          toggleSOS();
        }
      } else if (call.method == "onVolumePressed") {
        String direction = call.arguments as String? ?? "down";
        
        final prefs = await SharedPreferences.getInstance();
        bool volumeTriggerEnabled = prefs.getBool('volumeTriggerEnabled') ?? true;
        if (!volumeTriggerEnabled) return;

        String selectedButton = prefs.getString('volumeButtonType') ?? "down"; // "down" or "up"
        int requiredClicks = prefs.getInt('volumeClickCount') ?? 3; // default 3 clicks

        if (direction == selectedButton) {
          final now = DateTime.now();
          _volumePressTimestamps.add(now);

          // Keep only presses within the last 2.0 seconds
          _volumePressTimestamps.removeWhere((t) => now.difference(t).inMilliseconds > 2000);

          if (_volumePressTimestamps.length >= requiredClicks) {
            _volumePressTimestamps.clear();
            HapticFeedback.heavyImpact();
            toggleSOS();
          }
        }
      }
    });
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
      if (isSosActive) return; 
      
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

    // Listen for incoming alerts from other users / responders in distress
    socket.on('incoming_alert', (payload) {
      if (!isSosActive && mounted) {
        setState(() {
          _incomingDistressAlert = payload is Map<String, dynamic>
              ? payload
              : Map<String, dynamic>.from(payload as Map);
        });
        HapticFeedback.mediumImpact();
      }
    });

    socket.on('alert_cancelled', (payload) {
      if (mounted) {
        String cancelledUser = payload['username']?.toString() ?? "";
        if (_incomingDistressAlert != null &&
            (_incomingDistressAlert!['username'] == cancelledUser || cancelledUser.isEmpty)) {
          setState(() {
            _incomingDistressAlert = null;
          });
        }
      }
    });
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

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('userRole', 'responder');

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => ResponderMapScreen(initialVictimUsername: targetVictim),
      ),
    );
  }

  Future<void> _sendNativeSMS(String message) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> savedContacts = prefs.getStringList('savedContacts') ?? [];
    
    for (String contactInfo in savedContacts) {
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

  Future<void> _startActiveDefense() async {
    final prefs = await SharedPreferences.getInstance();
    bool sirenEnabled = prefs.getBool('sirenEnabled') ?? true;
    String myName = prefs.getString('username') ?? "A Commuter";
    if (myName.trim().isEmpty) myName = "A Commuter";

    // Grab quick location for the SMS link
    String mapLink = "Location unknown";
    try {
      Position position = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));
      mapLink = "https://maps.google.com/?q=${position.latitude},${position.longitude}";
    } catch (e) {
      debugPrint("Could not get quick location for SMS");
    }

    // 1. Send SMS to all emergency contacts silently via Kotlin
    String emergencyMessage = "$myName's EMERGENCY! I need help. Track my live location: $mapLink";
    await _sendNativeSMS(emergencyMessage);

    // 2. Start Loud Siren (If user enabled it in settings)
    if (sirenEnabled) {
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      await _audioPlayer.play(AssetSource('siren.ogg'));
    }

    // 3. Start Live Tracking Loop (Every 5 seconds)
    _locationTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      try {
        Position position = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));
        setState(() {
          locationStatus = "Lat: ${position.latitude.toStringAsFixed(4)}, Lng: ${position.longitude.toStringAsFixed(4)}";
        });
        
        var battery = Battery();
        int level = await battery.batteryLevel;
        
        socket.emit('encrypted_alert', {
          'targetContactId': 'all',
          'lat': position.latitude,
          'lng': position.longitude,
          'username': myName,
          'batteryMetadata': level,
          'timestamp': DateTime.now().toIso8601String(),
          'isLiveUpdate': true,
        });
      } catch (e) {
        setState(() {
          locationStatus = "GPS Failed";
        });
      }
    });
  }

  Future<void> _stopActiveDefense() async {
    // 1. Stop Siren
    await _audioPlayer.stop();
    // 2. Stop Tracking
    _locationTimer?.cancel();
    setState(() {
      locationStatus = "GPS Ready";
    });

    // 3. Notify server and responders that emergency is resolved
    final prefs = await SharedPreferences.getInstance();
    String myName = prefs.getString('username') ?? "A Commuter";
    socket.emit('cancel_alert', {
      'username': myName,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  void toggleSOS() async {
    setState(() {
      isSosActive = !isSosActive;
    });
    
    if (isSosActive) {
      await _startActiveDefense();
    } else {
      await _stopActiveDefense();
    }
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _locationTimer?.cancel();
    _shakeSubscription?.cancel();
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
            onPressed: () {
              // Navigate to Settings Screen
              Navigator.push(context, MaterialPageRoute(builder: (context) => const SettingsScreen()));
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
                            "🚨 SOS: ${_incomingDistressAlert!['username'] ?? 'Someone'} NEEDS HELP!",
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            "Tap to switch to Responder Mode & navigate.",
                            style: TextStyle(color: Colors.white70, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
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
                        _switchToResponder(targetVictim: victim);
                      },
                      child: const Text(
                        "RESPOND",
                        style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11),
                      ),
                    ),
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: () => setState(() => _incomingDistressAlert = null),
                      child: const Icon(Icons.close, color: Colors.white70, size: 18),
                    ),
                  ],
                ),
              ),

            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      isSosActive ? "EMERGENCY ACTIVE" : "READY TO TRACK",
                      style: TextStyle(
                        color: isSosActive ? Colors.redAccent : Colors.black54,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.5,
                      ),
                    ),
            const SizedBox(height: 50),
            
            // Pulsing SOS Button
            GestureDetector(
              onTap: toggleSOS,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                height: 220,
                width: 220,
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
                      fontSize: 48,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            
            const SizedBox(height: 60),
            
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
          ],
        ),
      ),
    ),
  ],
),
),
);
}
}
