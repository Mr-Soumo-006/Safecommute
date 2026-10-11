import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:shared_preferences/shared_preferences.dart';
import 'role_screen.dart';

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
  
  // Track active victims by username so their dot moves smoothly
  final Map<String, Marker> _activeSOSMarkers = {};
  LatLng _mapCenter = const LatLng(22.5726, 88.3639); // Default (Kolkata)

  @override
  void initState() {
    super.initState();
    _initSocket();
  }

  Future<void> _initSocket() async {
    final prefs = await SharedPreferences.getInstance();
    serverUrl = prefs.getString('serverUrl') ?? 'https://safecommute-uvn5.onrender.com';

    socket = IO.io(serverUrl, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
    });
    
    socket.onConnect((_) {
      print("Responder Map Connected to Server: $serverUrl");
      if (mounted) {
        setState(() {
          _isConnected = true;
          _statusText = "Connected & Monitoring";
        });
      }
    });

    socket.onDisconnect((_) {
      print("Responder Map Disconnected");
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
          _mapCenter = victimPos;
          _statusText = "🚨 Alert from $username (Bat: $battery%)";
          _activeSOSMarkers[username] = Marker(
            point: victimPos,
            width: 160,
            height: 90,
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
                    "$username ($battery%)",
                    style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 11),
                  ),
                ),
                const Icon(Icons.location_on, color: Colors.red, size: 42),
              ],
            ),
          );
        });

        // Automatically animate / move camera to the live location!
        try {
          _mapController.move(victimPos, 15.0);
        } catch (_) {}
      }
    });
  }

  @override
  void dispose() {
    socket.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
              MarkerLayer(
                markers: _activeSOSMarkers.values.toList(),
              ),
            ],
          ),
          
          if (_activeSOSMarkers.isEmpty)
            Positioned(
              top: 15,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.92),
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
                        "Listening for live emergency SOS alerts...",
                        style: TextStyle(color: Colors.black87, fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
