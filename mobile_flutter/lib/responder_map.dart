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
import 'role_screen.dart';

enum MapLayerStyle { streetRoads, classicOsm, darkTactical }

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

  MapLayerStyle _currentMapLayer = MapLayerStyle.streetRoads;
  final bool _autoFollowVictim = true;

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
                _mapController.move(_mapCenter, 15.0);
              } catch (_) {}
            }
          });
        }
      } catch (_) {}

      _positionStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 3),
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
          } else {
            _statusText = "🚨 ${_activeAlerts.length} Active Emergency";
          }
        });
      }
    });
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

  String _calculateBearing(double victimLat, double victimLng) {
    if (_myPosition == null) return "";
    double lat1 = _myPosition!.latitude * (math.pi / 180.0);
    double lon1 = _myPosition!.longitude * (math.pi / 180.0);
    double lat2 = victimLat * (math.pi / 180.0);
    double lon2 = victimLng * (math.pi / 180.0);

    double dLon = lon2 - lon1;
    double y = math.sin(dLon) * math.cos(lat2);
    double x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    double brng = math.atan2(y, x) * (180.0 / math.pi);
    brng = (brng + 360.0) % 360.0;

    const directions = ["North ↑", "North-East ↗", "East →", "South-East ↘", "South ↓", "South-West ↙", "West ←", "North-West ↖"];
    int index = ((brng + 22.5) / 45.0).floor() % 8;
    return directions[index];
  }

  String _getTileUrl() {
    switch (_currentMapLayer) {
      case MapLayerStyle.streetRoads:
        // CartoDB Voyager: High-contrast roads, street labels, and navigation typography
        return 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png';
      case MapLayerStyle.classicOsm:
        return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
      case MapLayerStyle.darkTactical:
        return 'https://{s}.basemaps.cartocdn.com/rastertiles/dark_all/{z}/{x}/{y}{r}.png';
    }
  }

  void _cycleMapLayer() {
    setState(() {
      switch (_currentMapLayer) {
        case MapLayerStyle.streetRoads:
          _currentMapLayer = MapLayerStyle.classicOsm;
          break;
        case MapLayerStyle.classicOsm:
          _currentMapLayer = MapLayerStyle.darkTactical;
          break;
        case MapLayerStyle.darkTactical:
          _currentMapLayer = MapLayerStyle.streetRoads;
          break;
      }
    });

    String layerName = _currentMapLayer == MapLayerStyle.streetRoads
        ? "🛣️ Detailed Street Roads"
        : _currentMapLayer == MapLayerStyle.classicOsm
            ? "🗺️ Classic OpenStreetMap"
            : "🌑 Dark Tactical Night Mode";

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
          IconButton(
            icon: const Icon(Icons.layers, color: Colors.white),
            tooltip: "Switch Map Layer",
            onPressed: _cycleMapLayer,
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
              initialZoom: 14.5,
            ),
            children: [
              TileLayer(
                urlTemplate: _getTileUrl(),
                subdomains: const ['a', 'b', 'c', 'd'],
                retinaMode: true,
                userAgentPackageName: 'com.safecommute.app.v2',
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
                        "Listening for live emergency SOS alerts... (Road Navigation Ready)",
                        style: TextStyle(color: Colors.black87, fontSize: 13, fontWeight: FontWeight.w500),
                      ),
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
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.redAccent.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 24),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  currentVictim.username,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: Colors.black87),
                                ),
                                Row(
                                  children: [
                                    Text(
                                      _formatDistance(currentVictim.lat, currentVictim.lng),
                                      style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 13),
                                    ),
                                    if (_myPosition != null) ...[
                                      const SizedBox(width: 8),
                                      Text(
                                        "• ${_calculateBearing(currentVictim.lat, currentVictim.lng)}",
                                        style: const TextStyle(color: Colors.black54, fontSize: 12, fontWeight: FontWeight.w600),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.green.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.green.shade200),
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
