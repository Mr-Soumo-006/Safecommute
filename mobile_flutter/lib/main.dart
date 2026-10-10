import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:permission_handler/permission_handler.dart'; // Added for SMS permission
import 'dart:async';
import 'dart:math';

import 'settings.dart'; 
import 'role_screen.dart'; 

void main() {
  runApp(const SafeCommuteApp());
}

class SafeCommuteApp extends StatelessWidget {
  const SafeCommuteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SafeCommute Phase 2',
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
      home: const RoleSelectionScreen(), 
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool isSosActive = false;
  String batteryLevel = "Unknown";
  String locationStatus = "GPS Ready";
  
  late IO.Socket socket;
  final AudioPlayer _audioPlayer = AudioPlayer();
  Timer? _locationTimer;
  StreamSubscription<AccelerometerEvent>? _shakeSubscription;
  
  final String serverUrl = 'http://192.168.29.218:3000';
  
  static const MethodChannel _smsChannel = MethodChannel('com.safecommute.app/sms');

  @override
  void initState() {
    super.initState();
    _initBattery();
    _initSocket();
    _requestPermissions();
    _initShakeDetection();
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

  void _initSocket() {
    socket = IO.io(serverUrl, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
    });
    socket.onConnect((_) => print("Connected to Backend Server"));
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
          print(result);
        } catch (e) {
          print("Failed to send SMS to $phone: $e");
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
      Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      mapLink = "https://maps.google.com/?q=${position.latitude},${position.longitude}";
    } catch (e) {
      print("Could not get quick location for SMS");
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
        Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
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
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              // Navigate to the new Settings Screen!
              Navigator.push(context, MaterialPageRoute(builder: (context) => const SettingsScreen()));
            },
          )
        ],
      ),
      body: Center(
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
                      color: isSosActive ? Colors.red.withOpacity(0.9) : Colors.red.withOpacity(0.3),
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
                  BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, spreadRadius: 2)
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
    );
  }
}
