import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
// ignore: library_prefixes
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'main.dart';

enum MapLayerStyle { humanitarianOsm, standardOsm, roadDetailOsm }

class VictimAlert {
  final String username;
  final double lat;
  final double lng;
  final String battery;
  final DateTime lastUpdated;

  VictimAlert({
    required this.username,
    required this.lat,
    required this.lng,
    required this.battery,
    required this.lastUpdated,
  });
}

class ResponderMapScreen extends StatefulWidget {
  final String? initialVictimUsername;
  final VoidCallback? onTriggerSos;
  final VoidCallback? onSwitchToCommuter;
  final bool isVisible;
  const ResponderMapScreen({
    super.key,
    this.initialVictimUsername,
    this.onTriggerSos,
    this.onSwitchToCommuter,
    this.isVisible = true,
  });

  @override
  State<ResponderMapScreen> createState() => ResponderMapScreenState();
}

class ResponderMapScreenState extends State<ResponderMapScreen> {
  late IO.Socket socket;
  final MapController _mapController = MapController();
  String serverUrl = 'https://safecommute-uvn5.onrender.com';
  bool _isConnected = false;
  String _statusText = "Connecting...";

  Position? _myPosition;
  StreamSubscription<Position>? _positionStream;

  // Active emergencies keyed by commuter username
  final Map<String, VictimAlert> _activeAlerts = {};
  String? _selectedVictimUsername;
  LatLng _mapCenter = const LatLng(22.5726, 88.3639); // Default

  MapLayerStyle _currentMapLayer = MapLayerStyle.humanitarianOsm;
  final bool _autoFollowVictim = true;

  static const MethodChannel _volumeChannel = MethodChannel('com.safecommute.app/volume');
  final AudioPlayer _alertPlayer = AudioPlayer();
  bool _isAlarmPlaying = false;
  bool _backgroundMonitoringEnabled = true;

  StreamSubscription<AccelerometerEvent>? _shakeSubscription;
  final List<DateTime> _volumePressTimestamps = [];

  @override
  void initState() {
    super.initState();
    _selectedVictimUsername = widget.initialVictimUsername;
    _requestPermissionsAndStartService();
    _startLocationTracking();
    _initSocket();
    _initVolumeButtonDetection();
    _initShakeDetection();
  }

  void _initVolumeButtonDetection() {
    _volumeChannel.setMethodCallHandler((call) async {
      if (call.method == "triggerSosNow") {
        _triggerResponderEmergencyDistress();
      } else if (call.method == "onVolumePressed") {
        String direction = call.arguments as String? ?? "down";

        final prefs = await SharedPreferences.getInstance();
        bool volumeTriggerEnabled = prefs.getBool('volumeTriggerEnabled') ?? true;
        if (!volumeTriggerEnabled) return;

        String selectedButton = prefs.getString('volumeButtonType') ?? "down";
        int requiredClicks = prefs.getInt('volumeClickCount') ?? 3;

        if (direction == selectedButton) {
          final now = DateTime.now();
          _volumePressTimestamps.add(now);
          _volumePressTimestamps.removeWhere((t) => now.difference(t).inMilliseconds > 2000);

          if (_volumePressTimestamps.length >= requiredClicks) {
            _volumePressTimestamps.clear();
            _triggerResponderEmergencyDistress();
          }
        }
      }
    });
  }

  void _initShakeDetection() {
    _shakeSubscription = accelerometerEventStream().listen((AccelerometerEvent event) async {
      double gForce = math.sqrt(event.x * event.x + event.y * event.y + event.z * event.z) / 9.8;
      if (gForce > 3.0) {
        final prefs = await SharedPreferences.getInstance();
        bool shakeEnabled = prefs.getBool('shakeEnabled') ?? true;
        if (shakeEnabled) {
          _triggerResponderEmergencyDistress();
        }
      }
    });
  }

  void focusVictim(String? victimUsername) {
    if (victimUsername != null && _activeAlerts.containsKey(victimUsername)) {
      final victim = _activeAlerts[victimUsername]!;
      setState(() => _selectedVictimUsername = victimUsername);
      try {
        _mapController.move(LatLng(victim.lat, victim.lng), 16.5);
      } catch (_) {}
    }
  }

  Future<void> _triggerResponderEmergencyDistress() async {
    HapticFeedback.heavyImpact();
    _muteAlarm();

    if (widget.onTriggerSos != null) {
      widget.onTriggerSos!();
      return;
    }

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => const DashboardScreen(autoTriggerSos: true),
      ),
    );
  }

  Future<void> _switchToCommuter() async {
    _muteAlarm();

    if (widget.onSwitchToCommuter != null) {
      widget.onSwitchToCommuter!();
      return;
    }

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const DashboardScreen()),
    );
  }

  Future<void> _requestPermissionsAndStartService() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      bool savedPref = prefs.getBool('backgroundMonitoringEnabled') ?? true;
      if (mounted) {
        setState(() => _backgroundMonitoringEnabled = savedPref);
      }
      await Permission.notification.request();
      await Permission.sms.request();
      if (savedPref) {
        await _volumeChannel.invokeMethod('startResponderBackgroundService');
      } else {
        await _volumeChannel.invokeMethod('stopResponderBackgroundService');
      }
    } catch (_) {}
  }

  Future<void> _toggleBackgroundMonitoring(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('backgroundMonitoringEnabled', value);
    setState(() => _backgroundMonitoringEnabled = value);

    if (value) {
      await _volumeChannel.invokeMethod('startResponderBackgroundService');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("🛡️ Background Alert Shield ON: Alerts will sound even if app is closed."),
            duration: Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Colors.green,
          ),
        );
      }
    } else {
      await _volumeChannel.invokeMethod('stopResponderBackgroundService');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("🛑 Background Alert Shield OFF: Notification cleared."),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Colors.blueGrey,
          ),
        );
      }
    }
  }

  @override
  void didUpdateWidget(covariant ResponderMapScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isVisible != oldWidget.isVisible) {
      if (widget.isVisible) {
        _resumeLocationTracking();
      } else {
        _pauseLocationTracking();
      }
    }
  }

  void _pauseLocationTracking() {
    _positionStream?.pause();
  }

  void _resumeLocationTracking() {
    if (_positionStream != null) {
      _positionStream?.resume();
    } else {
      _startLocationTracking();
    }
  }

  Future<void> _startLocationTracking() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
      // Fast instant fix from cache (0ms)
      try {
        Position? fastPos = await Geolocator.getLastKnownPosition();
        if (fastPos != null && mounted) {
          setState(() {
            _myPosition = fastPos;
            if (_activeAlerts.isEmpty) {
              _mapCenter = LatLng(fastPos.latitude, fastPos.longitude);
            }
          });
        }
      } catch (_) {}

      // High accuracy stream throttled to 10m to prevent CPU lag
      _positionStream?.cancel();
      _positionStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 10),
      ).listen((Position pos) {
        if (mounted) {
          setState(() {
            _myPosition = pos;
          });
        }
      });

      if (!widget.isVisible) {
        _positionStream?.pause();
      }
    }
  }

  Future<void> _initSocket() async {
    final prefs = await SharedPreferences.getInstance();
    serverUrl = prefs.getString('serverUrl') ?? 'https://safecommute-uvn5.onrender.com';

    socket = IO.io(serverUrl, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
    });

    socket.onConnect((_) {
      if (mounted) {
        setState(() {
          _isConnected = true;
          _statusText = _activeAlerts.isEmpty ? "Connected & Monitoring" : "🚨 ${_activeAlerts.length} Active SOS";
        });
      }
    });

    socket.onDisconnect((_) {
      if (mounted) {
        setState(() {
          _isConnected = false;
          _statusText = "Disconnected from Server";
        });
      }
    });

    socket.onConnectError((err) {
      if (mounted) {
        setState(() {
          _isConnected = false;
          _statusText = "Connection Error";
        });
      }
    });

    socket.on('incoming_alert', (payload) {
      if (payload['lat'] != null && payload['lng'] != null) {
        double lat = (payload['lat'] as num).toDouble();
        double lng = (payload['lng'] as num).toDouble();
        String username = payload['username'] ?? "Commuter in Distress";
        String battery = payload['batteryMetadata']?.toString() ?? "??";

        LatLng victimPos = LatLng(lat, lng);
        bool isNewAlert = !_activeAlerts.containsKey(username);

        setState(() {
          _activeAlerts[username] = VictimAlert(
            username: username,
            lat: lat,
            lng: lng,
            battery: battery,
            lastUpdated: DateTime.now(),
          );
          _selectedVictimUsername ??= username;
          _statusText = "🚨 ${_activeAlerts.length} Active Emergency";
        });

        // Trigger strong notification, siren, and heads-up banner on new alert!
        if (isNewAlert) {
          _handleNewEmergencyAlert(username, lat, lng);
        }

        // If auto-follow is on and this is the active victim, smoothly track position
        if (_autoFollowVictim && _selectedVictimUsername == username) {
          try {
            _mapController.move(victimPos, _mapController.camera.zoom);
          } catch (_) {}
        }
      }
    });

    socket.on('alert_cancelled', (payload) {
      String username = payload['username'] ?? "";
      if (mounted) {
        setState(() {
          _activeAlerts.remove(username);
          if (_selectedVictimUsername == username) {
            _selectedVictimUsername = _activeAlerts.isNotEmpty ? _activeAlerts.keys.first : null;
          }
          if (_activeAlerts.isEmpty) {
            _statusText = "Connected & Monitoring";
            _muteAlarm();
            try {
              _volumeChannel.invokeMethod('cancelEmergencyNotification');
            } catch (_) {}
          } else {
            _statusText = "🚨 ${_activeAlerts.length} Active Emergency";
          }
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("ℹ️ SOS cancelled by $username"),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Colors.blueGrey,
          ),
        );
      }
    });
  }

  Future<void> _handleNewEmergencyAlert(String username, double lat, double lng) async {
    // 0. Proximity Geofenced Filter: Only nearest responders are alerted with full siren & alarm!
    final prefs = await SharedPreferences.getInstance();
    double radiusKm = prefs.getDouble('alertRadiusKm') ?? 5.0; // Default 5 km

    Position? pos = _myPosition;
    if (pos == null) {
      try {
        pos = await Geolocator.getLastKnownPosition();
        if (pos != null) _myPosition = pos;
      } catch (_) {}
    }

    double distanceMeters = 0.0;
    bool isNearby = true;
    if (pos != null) {
      distanceMeters = Geolocator.distanceBetween(
        pos.latitude,
        pos.longitude,
        lat,
        lng,
      );
      if (radiusKm > 0.0 && distanceMeters > (radiusKm * 1000.0)) {
        isNearby = false;
      }
    }

    if (!isNearby) {
      final distStr = distanceMeters < 1000
          ? "${distanceMeters.round()} m"
          : "${(distanceMeters / 1000).toStringAsFixed(1)} km";
      debugPrint("[PROXIMITY FILTER] SOS from $username is $distStr away (> ${radiusKm.toStringAsFixed(0)} km). Siren and alarm suppressed.");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("ℹ️ Distant SOS active: $username ($distStr away). Siren silenced to avoid false alarm."),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Colors.blueGrey.shade800,
            duration: const Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    final distDesc = pos != null
        ? (distanceMeters < 1000 ? "${distanceMeters.round()} m away" : "${(distanceMeters / 1000).toStringAsFixed(1)} km away")
        : "nearby";

    // 1. Native Android Heads-Up Notification & Heavy Vibration for Nearest Responders
    try {
      await _volumeChannel.invokeMethod('showEmergencyNotification', {
        'title': "🚨 SOS ALERT: $username NEEDS HELP!",
        'body': "$username is in danger ($distDesc)! Tap to view Live GPS Radar.",
      });
    } catch (_) {}

    // 2. Play Urgent Audio Siren Loop (check sirenEnabled setting)
    bool sirenEnabled = prefs.getBool('sirenEnabled') ?? true;
    if (sirenEnabled) {
      try {
        await _alertPlayer.setReleaseMode(ReleaseMode.loop);
        await _alertPlayer.play(AssetSource('siren.ogg'));
        if (mounted) setState(() => _isAlarmPlaying = true);
      } catch (_) {}
    }

    // 3. Heavy In-App Haptics
    HapticFeedback.heavyImpact();

    // 4. Center map immediately on victim
    try {
      _mapController.move(LatLng(lat, lng), 16.5);
    } catch (_) {}

    // 5. In-App High-Visibility Alert Dialog
    if (mounted) {
      _showEmergencyModal(username, lat, lng);
    }
  }

  void muteAlarmFromExternal() {
    _muteAlarm();
  }

  void _muteAlarm() async {
    try {
      await _alertPlayer.stop();
    } catch (_) {}
    try {
      await _volumeChannel.invokeMethod('cancelEmergencyNotification');
    } catch (_) {}
    try {
      await _volumeChannel.invokeMethod('muteEmergencyAlarm');
    } catch (_) {}
    if (mounted) setState(() => _isAlarmPlaying = false);
  }

  void _showEmergencyModal(String username, double lat, double lng) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          backgroundColor: Colors.white,
          titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.shade100,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 28),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  "🚨 CRITICAL SOS!",
                  style: TextStyle(fontWeight: FontWeight.w900, color: Colors.redAccent, fontSize: 18),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "$username triggered an urgent SOS alert!",
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
              ),
              const SizedBox(height: 8),
              Text(
                "Distance: ${_formatDistance(lat, lng)}",
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.blueAccent),
              ),
              const SizedBox(height: 6),
              const Text(
                "Real-time GPS coordinates are streaming. Immediate response is required.",
                style: TextStyle(fontSize: 13, color: Colors.black54),
              ),
              const SizedBox(height: 20),
              // Big Turn-by-Turn GPS Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.navigation, size: 22),
                  label: const Text(
                    "Start Turn-by-Turn GPS",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _muteAlarm();
                    _startTurnByTurnNavigation(lat, lng);
                  },
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Icon(Icons.volume_off, size: 18),
                      label: const Text("Mute Siren", style: TextStyle(fontWeight: FontWeight.bold)),
                      onPressed: () {
                        _muteAlarm();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Icon(Icons.map, size: 18),
                      label: const Text("View Map", style: TextStyle(fontWeight: FontWeight.bold)),
                      onPressed: () {
                        Navigator.pop(ctx);
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  void _startTurnByTurnNavigation(double lat, double lng) async {
    final nativeUri = Uri.parse("google.navigation:q=$lat,$lng&mode=d");
    final webUri = Uri.parse("https://www.google.com/maps/dir/?api=1&destination=$lat,$lng");

    try {
      if (await canLaunchUrl(nativeUri)) {
        await launchUrl(nativeUri, mode: LaunchMode.externalApplication);
      } else if (await canLaunchUrl(webUri)) {
        await launchUrl(webUri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      await launchUrl(webUri, mode: LaunchMode.externalApplication);
    }
  }

  void _copyLocationLink(double lat, double lng, String username) {
    final link = "https://maps.google.com/?q=$lat,$lng";
    Clipboard.setData(ClipboardData(text: link));
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("📍 Google Maps link for $username copied! Share with backup responders."),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.blueAccent,
      ),
    );
  }

  void _fitRouteBetweenResponderAndVictim(VictimAlert victim) {
    if (_myPosition == null) {
      _mapController.move(LatLng(victim.lat, victim.lng), 16.0);
      return;
    }

    try {
      _mapController.fitCamera(
        CameraFit.coordinates(
          coordinates: [
            LatLng(_myPosition!.latitude, _myPosition!.longitude),
            LatLng(victim.lat, victim.lng),
          ],
          padding: const EdgeInsets.symmetric(horizontal: 50, vertical: 140),
        ),
      );
    } catch (_) {}
  }

  String _formatDistance(double victimLat, double victimLng) {
    if (_myPosition == null) return "Locating you...";
    double meters = Geolocator.distanceBetween(
      _myPosition!.latitude,
      _myPosition!.longitude,
      victimLat,
      victimLng,
    );
    if (meters < 1000) {
      return "${meters.round()} meters away";
    } else {
      return "${(meters / 1000).toStringAsFixed(1)} km away";
    }
  }

  Map<String, dynamic> _getNavigationTurn(double victimLat, double victimLng) {
    if (_myPosition == null) {
      return {'text': 'Locating you...', 'icon': Icons.my_location, 'color': Colors.grey};
    }

    double distanceMeters = Geolocator.distanceBetween(
      _myPosition!.latitude,
      _myPosition!.longitude,
      victimLat,
      victimLng,
    );

    // If within 8 meters, responder is right beside the victim
    if (distanceMeters <= 8) {
      return {
        'text': 'Beside you (<8m)',
        'icon': Icons.check_circle,
        'color': Colors.green,
      };
    }

    double lat1 = _myPosition!.latitude * (math.pi / 180.0);
    double lon1 = _myPosition!.longitude * (math.pi / 180.0);
    double lat2 = victimLat * (math.pi / 180.0);
    double lon2 = victimLng * (math.pi / 180.0);

    double dLon = lon2 - lon1;
    double y = math.sin(dLon) * math.cos(lat2);
    double x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    double bearing = (math.atan2(y, x) * (180.0 / math.pi) + 360.0) % 360.0;

    double heading = _myPosition!.heading;

    // When device is in motion or has compass heading (heading > 0)
    if (heading > 0.0) {
      double rel = (bearing - heading + 360.0) % 360.0;
      if (rel <= 25.0 || rel >= 335.0) {
        return {'text': 'Straight Ahead', 'icon': Icons.arrow_upward, 'color': Colors.blue};
      } else if (rel > 25.0 && rel <= 70.0) {
        return {'text': 'Bear Right', 'icon': Icons.north_east, 'color': Colors.orange};
      } else if (rel > 70.0 && rel <= 115.0) {
        return {'text': 'Turn Right', 'icon': Icons.turn_right, 'color': Colors.deepOrange};
      } else if (rel > 115.0 && rel <= 160.0) {
        return {'text': 'Sharp Right', 'icon': Icons.south_east, 'color': Colors.redAccent};
      } else if (rel > 160.0 && rel <= 200.0) {
        return {'text': 'Turn Around', 'icon': Icons.arrow_downward, 'color': Colors.red};
      } else if (rel > 200.0 && rel <= 245.0) {
        return {'text': 'Sharp Left', 'icon': Icons.south_west, 'color': Colors.redAccent};
      } else if (rel > 245.0 && rel <= 290.0) {
        return {'text': 'Turn Left', 'icon': Icons.turn_left, 'color': Colors.deepOrange};
      } else {
        return {'text': 'Bear Left', 'icon': Icons.north_west, 'color': Colors.orange};
      }
    } else {
      // Stationary (Standing still) - intuitive directional guide
      if (bearing >= 337.5 || bearing < 22.5) {
        return {'text': 'Ahead (North)', 'icon': Icons.arrow_upward, 'color': Colors.blue};
      } else if (bearing >= 22.5 && bearing < 67.5) {
        return {'text': 'Ahead-Right', 'icon': Icons.north_east, 'color': Colors.orange};
      } else if (bearing >= 67.5 && bearing < 112.5) {
        return {'text': 'To your Right', 'icon': Icons.turn_right, 'color': Colors.deepOrange};
      } else if (bearing >= 112.5 && bearing < 157.5) {
        return {'text': 'Behind-Right', 'icon': Icons.south_east, 'color': Colors.redAccent};
      } else if (bearing >= 157.5 && bearing < 202.5) {
        return {'text': 'Behind you', 'icon': Icons.arrow_downward, 'color': Colors.red};
      } else if (bearing >= 202.5 && bearing < 247.5) {
        return {'text': 'Behind-Left', 'icon': Icons.south_west, 'color': Colors.redAccent};
      } else if (bearing >= 247.5 && bearing < 292.5) {
        return {'text': 'To your Left', 'icon': Icons.turn_left, 'color': Colors.deepOrange};
      } else {
        return {'text': 'Ahead-Left', 'icon': Icons.north_west, 'color': Colors.orange};
      }
    }
  }

  String _getTileUrl() {
    switch (_currentMapLayer) {
      case MapLayerStyle.humanitarianOsm:
        // Humanitarian OSM (HOT): Designed for emergency rescue, clear roads, 100% Free, NO API KEY
        return 'https://{s}.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png';
      case MapLayerStyle.standardOsm:
        // Standard OpenStreetMap: Global reference map, 100% Free, NO API KEY
        return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
      case MapLayerStyle.roadDetailOsm:
        // High-Detail Road Map (OSM-FR): Clear road hierarchy, 100% Free, NO API KEY
        return 'https://{s}.tile.openstreetmap.fr/osmfr/{z}/{x}/{y}.png';
    }
  }

  void _cycleMapLayer() {
    setState(() {
      switch (_currentMapLayer) {
        case MapLayerStyle.humanitarianOsm:
          _currentMapLayer = MapLayerStyle.standardOsm;
          break;
        case MapLayerStyle.standardOsm:
          _currentMapLayer = MapLayerStyle.roadDetailOsm;
          break;
        case MapLayerStyle.roadDetailOsm:
          _currentMapLayer = MapLayerStyle.humanitarianOsm;
          break;
      }
    });

    String layerName = _currentMapLayer == MapLayerStyle.humanitarianOsm
        ? "🚨 Emergency Roads (HOT)"
        : _currentMapLayer == MapLayerStyle.standardOsm
            ? "🗺️ Standard OpenStreetMap"
            : "🛣️ High-Detail Roads (OSM-FR)";

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("Map switched to $layerName"),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _shakeSubscription?.cancel();
    _alertPlayer.stop();
    _alertPlayer.dispose();
    socket.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    List<Marker> markers = [];
    List<Polyline> polylines = [];

    VictimAlert? currentVictim = _selectedVictimUsername != null ? _activeAlerts[_selectedVictimUsername] : null;

    // 1. Blue Dot for Responder
    if (_myPosition != null) {
      markers.add(
        Marker(
          point: LatLng(_myPosition!.latitude, _myPosition!.longitude),
          width: 52,
          height: 52,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.blueAccent.withValues(alpha: 0.25),
            ),
            child: Center(
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.blueAccent,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 6)],
                ),
              ),
            ),
          ),
        ),
      );
    }

    // 2. Red Pins for all active Victims
    for (var victim in _activeAlerts.values) {
      bool isSelected = victim.username == _selectedVictimUsername;
      markers.add(
        Marker(
          point: LatLng(victim.lat, victim.lng),
          width: 170,
          height: 95,
          child: GestureDetector(
            onTap: () {
              setState(() => _selectedVictimUsername = victim.username);
              _mapController.move(LatLng(victim.lat, victim.lng), 16.0);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isSelected ? Colors.redAccent : Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.redAccent, width: 1.5),
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
                    ],
                  ),
                  child: Text(
                    "${victim.username} (${victim.battery}%)",
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.redAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                  ),
                ),
                Icon(
                  Icons.location_on,
                  color: Colors.redAccent,
                  size: isSelected ? 46 : 38,
                ),
              ],
            ),
          ),
        ),
      );
    }

    // 3. Dynamic Road Approach Polyline connecting Responder to Victim
    if (_myPosition != null && currentVictim != null) {
      polylines.add(
        Polyline(
          points: [
            LatLng(_myPosition!.latitude, _myPosition!.longitude),
            LatLng(currentVictim.lat, currentVictim.lng),
          ],
          color: Colors.blueAccent,
          strokeWidth: 4.5,
          borderStrokeWidth: 2.0,
          borderColor: Colors.white,
          pattern: StrokePattern.dashed(segments: [12, 8]),
        ),
      );
    }



    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Responder Live Map", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _isConnected ? Colors.greenAccent : Colors.orangeAccent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _statusText,
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ],
            ),
          ],
        ),
        backgroundColor: Colors.blueAccent,
        actions: [
          // Rapid Dual-Role Switch Button: Instant transition to Commuter Mode
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 4.0),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.blue.shade900,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              ),
              icon: const Icon(Icons.directions_walk, size: 16, color: Colors.blueAccent),
              label: const Text("Commuter", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              onPressed: _switchToCommuter,
            ),
          ),
          IconButton(
            icon: Icon(
              _backgroundMonitoringEnabled ? Icons.shield : Icons.shield_outlined,
              color: _backgroundMonitoringEnabled ? Colors.greenAccent : Colors.white70,
            ),
            tooltip: _backgroundMonitoringEnabled ? "Background Alert Shield: ACTIVE" : "Background Alert Shield: OFF",
            onPressed: () => _toggleBackgroundMonitoring(!_backgroundMonitoringEnabled),
          ),
          IconButton(
            icon: const Icon(Icons.layers, color: Colors.white),
            tooltip: "Switch Map Layer",
            onPressed: _cycleMapLayer,
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
      floatingActionButton: Padding(
        padding: EdgeInsets.only(bottom: currentVictim != null ? 180.0 : 0.0),
        child: FloatingActionButton.extended(
          heroTag: "responder_panic_sos_btn",
          backgroundColor: Colors.red.shade800,
          elevation: 6,
          icon: const Icon(Icons.crisis_alert, color: Colors.white, size: 22),
          label: const Text(
            "I'M IN DANGER (SOS)",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 0.5),
          ),
          onPressed: _triggerResponderEmergencyDistress,
        ),
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _mapCenter,
              initialZoom: 14.5,
            ),
            children: [
              TileLayer(
                urlTemplate: _getTileUrl(),
                subdomains: const ['a', 'b', 'c'],
                userAgentPackageName: 'com.safecommute.app.v2',
                maxZoom: 19,
              ),
              PolylineLayer(polylines: polylines),
              MarkerLayer(markers: markers),
            ],
          ),

          // Multi-Victim Emergency Switcher Bar
          if (_activeAlerts.length > 1)
            Positioned(
              top: 10,
              left: 12,
              right: 12,
              child: SizedBox(
                height: 42,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _activeAlerts.length,
                  itemBuilder: (context, index) {
                    final victim = _activeAlerts.values.elementAt(index);
                    final isSelected = victim.username == _selectedVictimUsername;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: ActionChip(
                        elevation: 3,
                        backgroundColor: isSelected ? Colors.redAccent : Colors.white,
                        avatar: Icon(
                          Icons.warning_amber_rounded,
                          color: isSelected ? Colors.white : Colors.redAccent,
                          size: 16,
                        ),
                        label: Text(
                          "${victim.username} (${_formatDistance(victim.lat, victim.lng)})",
                          style: TextStyle(
                            color: isSelected ? Colors.white : Colors.black87,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                        onPressed: () {
                          setState(() => _selectedVictimUsername = victim.username);
                          _mapController.move(LatLng(victim.lat, victim.lng), 16.0);
                        },
                      ),
                    );
                  },
                ),
              ),
            ),

          // Active Siren Mute Bar
          if (_isAlarmPlaying)
            Positioned(
              top: _activeAlerts.length > 1 ? 60 : 14,
              left: 14,
              right: 14,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.red.shade900,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [
                    BoxShadow(color: Colors.redAccent, blurRadius: 10, spreadRadius: 1),
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.campaign, color: Colors.white, size: 22),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        "🚨 CRITICAL SOS ALARM ACTIVE",
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12),
                      ),
                    ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.red.shade900,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.volume_off, size: 15),
                      label: const Text("TURN OFF ALARM", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                      onPressed: _muteAlarm,
                    ),
                  ],
                ),
              ),
            ),

          // Idle State Banner with Clean On/Off Toggle
          if (_activeAlerts.isEmpty)
            Positioned(
              top: 14,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.96),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: const [
                    BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, 3)),
                  ],
                  border: Border.all(
                    color: _backgroundMonitoringEnabled ? Colors.green.shade300 : Colors.grey.shade300,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _backgroundMonitoringEnabled ? Icons.shield : Icons.shield_outlined,
                      color: _backgroundMonitoringEnabled ? Colors.green : Colors.grey,
                      size: 26,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _backgroundMonitoringEnabled
                                ? "Background Alert Shield: ACTIVE"
                                : "Background Alert Shield: OFF",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: _backgroundMonitoringEnabled ? Colors.green.shade900 : Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _backgroundMonitoringEnabled
                                ? "Rings alarm even if SafeCommute is closed. Tap switch to turn OFF."
                                : "Tap switch to monitor for SOS alerts in the background.",
                            style: const TextStyle(color: Colors.black54, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: _backgroundMonitoringEnabled,
                      activeThumbColor: Colors.green,
                      onChanged: (val) => _toggleBackgroundMonitoring(val),
                    ),
                  ],
                ),
              ),
            ),

          // Floating Fast-Action Side Toolbar (Right Column)
          Positioned(
            right: 14,
            top: _activeAlerts.length > 1 ? 65 : 75,
            child: Column(
              children: [
                // Zoom In
                _buildFloatingToolButton(
                  icon: Icons.add,
                  tooltip: "Zoom In",
                  onPressed: () {
                    _mapController.move(_mapController.camera.center, _mapController.camera.zoom + 1);
                  },
                ),
                const SizedBox(height: 8),
                // Zoom Out
                _buildFloatingToolButton(
                  icon: Icons.remove,
                  tooltip: "Zoom Out",
                  onPressed: () {
                    _mapController.move(_mapController.camera.center, _mapController.camera.zoom - 1);
                  },
                ),
                const SizedBox(height: 14),
                // Route Overview (Fit Both Responder & Victim in View)
                if (currentVictim != null && _myPosition != null) ...[
                  _buildFloatingToolButton(
                    icon: Icons.route,
                    tooltip: "Fit Route in View",
                    color: Colors.blueAccent,
                    onPressed: () => _fitRouteBetweenResponderAndVictim(currentVictim),
                  ),
                  const SizedBox(height: 8),
                ],
                // Focus Victim
                if (currentVictim != null) ...[
                  _buildFloatingToolButton(
                    icon: Icons.person_pin_circle,
                    tooltip: "Focus Victim",
                    color: Colors.redAccent,
                    onPressed: () {
                      _mapController.move(LatLng(currentVictim.lat, currentVictim.lng), 16.5);
                    },
                  ),
                  const SizedBox(height: 8),
                ],
                // My Location
                _buildFloatingToolButton(
                  icon: Icons.my_location,
                  tooltip: "My Location",
                  onPressed: () {
                    if (_myPosition != null) {
                      _mapController.move(LatLng(_myPosition!.latitude, _myPosition!.longitude), 16.0);
                    }
                  },
                ),
                const SizedBox(height: 8),
                // Map Style Switcher
                _buildFloatingToolButton(
                  icon: Icons.map,
                  tooltip: "Toggle Map Roads",
                  onPressed: _cycleMapLayer,
                ),
              ],
            ),
          ),

          // Workable Active Emergency Bottom Navigation Card
          if (currentVictim != null)
            Positioned(
              bottom: 16,
              left: 14,
              right: 14,
              child: Card(
                elevation: 8,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header Row
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.redAccent.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 24),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        currentVictim.username,
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.black87),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.green.shade50,
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(color: Colors.green.shade200),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.battery_charging_full, size: 14, color: Colors.green),
                                          const SizedBox(width: 3),
                                          Text(
                                            "${currentVictim.battery}%",
                                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.green),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Builder(
                                  builder: (context) {
                                    final nav = _getNavigationTurn(currentVictim.lat, currentVictim.lng);
                                    return Wrap(
                                      crossAxisAlignment: WrapCrossAlignment.center,
                                      spacing: 6,
                                      runSpacing: 4,
                                      children: [
                                        Text(
                                          _formatDistance(currentVictim.lat, currentVictim.lng),
                                          style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 13),
                                        ),
                                        if (_myPosition != null) ...[
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: (nav['color'] as Color).withValues(alpha: 0.12),
                                              borderRadius: BorderRadius.circular(6),
                                              border: Border.all(color: (nav['color'] as Color).withValues(alpha: 0.4)),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(nav['icon'] as IconData, size: 13, color: nav['color'] as Color),
                                                const SizedBox(width: 4),
                                                Text(
                                                  nav['text'] as String,
                                                  style: TextStyle(
                                                    color: nav['color'] as Color,
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ],
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      // Action Buttons Row (Clean, Highly Workable)
                      Row(
                        children: [
                          // Fit Route
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
                              side: const BorderSide(color: Colors.blueAccent),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: const Icon(Icons.crop_free, color: Colors.blueAccent, size: 18),
                            label: const Text("Fit", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                            onPressed: () => _fitRouteBetweenResponderAndVictim(currentVictim),
                          ),
                          const SizedBox(width: 8),
                          // Copy Coordinates
                          IconButton(
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.grey.shade100,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: const Icon(Icons.copy, color: Colors.black87, size: 20),
                            tooltip: "Copy Link",
                            onPressed: () => _copyLocationLink(currentVictim.lat, currentVictim.lng, currentVictim.username),
                          ),
                          const SizedBox(width: 8),
                          // Primary Turn-by-Turn GPS Navigation
                          Expanded(
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.redAccent,
                                foregroundColor: Colors.white,
                                elevation: 3,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.navigation, color: Colors.white, size: 20),
                              label: const Text(
                                "Turn-by-Turn GPS",
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                              onPressed: () => _startTurnByTurnNavigation(currentVictim.lat, currentVictim.lng),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }



  Widget _buildFloatingToolButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? color,
  }) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      child: IconButton(
        icon: Icon(icon, color: color ?? Colors.black87, size: 22),
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        onPressed: onPressed,
      ),
    );
  }
}
