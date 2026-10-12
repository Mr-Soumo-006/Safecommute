import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'role_screen.dart';

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
  const ResponderMapScreen({super.key});

  @override
  State<ResponderMapScreen> createState() => _ResponderMapScreenState();
}

class _ResponderMapScreenState extends State<ResponderMapScreen> {
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

  @override
  void initState() {
    super.initState();
    _startLocationTracking();
    _initSocket();
  }

  Future<void> _startLocationTracking() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
      try {
        Position pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
        );
        if (mounted) {
          setState(() {
            _myPosition = pos;
            if (_activeAlerts.isEmpty) {
              _mapCenter = LatLng(pos.latitude, pos.longitude);
              try {
                _mapController.move(_mapCenter, 14.0);
              } catch (_) {}
            }
          });
        }
      } catch (_) {}

      _positionStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5),
      ).listen((Position pos) {
        if (mounted) {
          setState(() {
            _myPosition = pos;
          });
        }
      });
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

        // If this is the active selected victim, smoothly glide camera to update position
        if (_selectedVictimUsername == username) {
          try {
            _mapController.move(victimPos, 15.0);
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
          } else {
            _statusText = "🚨 ${_activeAlerts.length} Active Emergency";
          }
        });
      }
    });
  }

  void _openNavigation(double lat, double lng) async {
    final uri = Uri.parse("https://www.google.com/maps/dir/?api=1&destination=$lat,$lng");
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
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

  @override
  void dispose() {
    _positionStream?.cancel();
    socket.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    List<Marker> markers = [];

    // 1. Blue Dot for Responder
    if (_myPosition != null) {
      markers.add(
        Marker(
          point: LatLng(_myPosition!.latitude, _myPosition!.longitude),
          width: 50,
          height: 50,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.blueAccent.withValues(alpha: 0.25),
            ),
            child: Center(
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.blueAccent,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                ),
              ),
            ),
          ),
        ),
      );
    }

    // 2. Red Pins for all active Victims
    for (var victim in _activeAlerts.values) {
      markers.add(
        Marker(
          point: LatLng(victim.lat, victim.lng),
          width: 160,
          height: 90,
          child: GestureDetector(
            onTap: () {
              setState(() => _selectedVictimUsername = victim.username);
              _mapController.move(LatLng(victim.lat, victim.lng), 15.0);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
                    ],
                  ),
                  child: Text(
                    "${victim.username} (${victim.battery}%)",
                    style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 11),
                  ),
                ),
                const Icon(Icons.location_on, color: Colors.red, size: 42),
              ],
            ),
          ),
        ),
      );
    }

    VictimAlert? currentVictim = _selectedVictimUsername != null ? _activeAlerts[_selectedVictimUsername] : null;

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
          IconButton(
            icon: const Icon(Icons.my_location, color: Colors.white),
            tooltip: "Center on My Location",
            onPressed: () {
              if (_myPosition != null) {
                _mapController.move(LatLng(_myPosition!.latitude, _myPosition!.longitude), 15.0);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white),
            tooltip: "Log Out / Switch Role",
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('userRole');
              if (!context.mounted) return;
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (context) => const RoleSelectionScreen()),
                (route) => false,
              );
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _mapCenter,
              initialZoom: 13.0,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.safecommute.app.v2',
              ),
              MarkerLayer(markers: markers),
            ],
          ),

          // Idle State Banner
          if (_activeAlerts.isEmpty)
            Positioned(
              top: 15,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.94),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [
                    BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, 3)),
                  ],
                ),
                child: const Row(
                  children: [
                    Icon(Icons.radar, color: Colors.blueAccent, size: 24),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        "Listening for live emergency SOS alerts... (Idle)",
                        style: TextStyle(color: Colors.black87, fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Active Emergency Navigation Card
          if (currentVictim != null)
            Positioned(
              bottom: 20,
              left: 16,
              right: 16,
              child: Card(
                elevation: 6,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.redAccent.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.warning, color: Colors.redAccent, size: 22),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  currentVictim.username,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.black87),
                                ),
                                Text(
                                  _formatDistance(currentVictim.lat, currentVictim.lng),
                                  style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.w600, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.green.shade50,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.battery_charging_full, size: 16, color: Colors.green),
                                const SizedBox(width: 4),
                                Text(
                                  "${currentVictim.battery}%",
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.green),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                side: const BorderSide(color: Colors.blueAccent),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.center_focus_strong, color: Colors.blueAccent, size: 18),
                              label: const Text("Focus", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                              onPressed: () {
                                _mapController.move(LatLng(currentVictim.lat, currentVictim.lng), 16.0);
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.redAccent,
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.navigation, color: Colors.white, size: 18),
                              label: const Text(
                                "Navigate (Google Maps)",
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                              onPressed: () => _openNavigation(currentVictim.lat, currentVictim.lng),
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
}
