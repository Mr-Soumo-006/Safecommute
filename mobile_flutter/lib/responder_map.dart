import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

class ResponderMapScreen extends StatefulWidget {
  const ResponderMapScreen({super.key});

  @override
  State<ResponderMapScreen> createState() => _ResponderMapScreenState();
}

class _ResponderMapScreenState extends State<ResponderMapScreen> {
  late IO.Socket socket;
  // Replace with your current Wi-Fi IP!
  final String serverUrl = 'http://192.168.29.218:3000';
  
  // Track active victims by username so their dot moves instead of creating multiple dots
  final Map<String, Marker> _activeSOSMarkers = {};
  
  // Center map on the latest alert
  LatLng _mapCenter = const LatLng(22.5726, 88.3639); // Default (Kolkata)

  @override
  void initState() {
    super.initState();
    _initSocket();
  }

  void _initSocket() {
    socket = IO.io(serverUrl, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
    });
    
    socket.onConnect((_) => print("Responder Map Connected to Server"));

    socket.on('incoming_alert', (payload) {
      if (payload['lat'] != null && payload['lng'] != null) {
        double lat = (payload['lat'] as num).toDouble();
        double lng = (payload['lng'] as num).toDouble();
        String username = payload['username'] ?? "Unknown Victim";

        setState(() {
          _mapCenter = LatLng(lat, lng);
          _activeSOSMarkers[username] = Marker(
            point: LatLng(lat, lng),
            width: 150,
            height: 100,
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                  child: Text(username, style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12)),
                ),
                const Icon(Icons.location_on, color: Colors.red, size: 40),
              ],
            ),
          );
        });
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
        title: const Text("Active SOS Alerts"),
        backgroundColor: Colors.blueAccent,
      ),
      body: FlutterMap(
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
    );
  }
}
