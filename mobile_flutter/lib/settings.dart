import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  bool _sirenEnabled = true;
  bool _shakeEnabled = true;
  bool _bleEnabled = false;
  bool _volumeTriggerEnabled = true;
  bool _accessibilityServiceActive = false;
  String _volumeButtonType = "down"; // "down" or "up"
  int _volumeClickCount = 3; // 2, 3, 4, 5
  double _alertRadiusKm = 5.0; // 2.0, 5.0, 10.0, 0.0 (All)
  List<String> _savedContacts = [];
  String _myUsername = "";

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();

  static const MethodChannel _volumeChannel = MethodChannel('com.safecommute.app/volume');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAccessibilityStatus();
    }
  }

  Future<void> _checkAccessibilityStatus() async {
    try {
      bool active = await _volumeChannel.invokeMethod('isAccessibilityEnabled') ?? false;
      if (mounted) setState(() => _accessibilityServiceActive = active);
    } catch (_) {}
  }

  Future<void> _syncToNative() async {
    try {
      await _volumeChannel.invokeMethod('syncSettings', {
        'enabled': _volumeTriggerEnabled,
        'buttonType': _volumeButtonType,
        'clickCount': _volumeClickCount,
        'username': _myUsername,
        'contacts': _savedContacts,
      });
    } catch (_) {}
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _sirenEnabled = prefs.getBool('sirenEnabled') ?? true;
      _shakeEnabled = prefs.getBool('shakeEnabled') ?? true;
      _bleEnabled = prefs.getBool('bleEnabled') ?? false;
      _volumeTriggerEnabled = prefs.getBool('volumeTriggerEnabled') ?? true;
      _volumeButtonType = prefs.getString('volumeButtonType') ?? "down";
      _volumeClickCount = prefs.getInt('volumeClickCount') ?? 3;
      _alertRadiusKm = prefs.getDouble('alertRadiusKm') ?? 5.0;
      _savedContacts = prefs.getStringList('savedContacts') ?? [];
      _myUsername = prefs.getString('username') ?? "";
      _usernameController.text = _myUsername;
    });
    _checkAccessibilityStatus();
  }

  Future<void> _saveToggleSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sirenEnabled', _sirenEnabled);
    await prefs.setBool('shakeEnabled', _shakeEnabled);
    await prefs.setBool('bleEnabled', _bleEnabled);
    await prefs.setBool('volumeTriggerEnabled', _volumeTriggerEnabled);
    await prefs.setString('volumeButtonType', _volumeButtonType);
    await prefs.setInt('volumeClickCount', _volumeClickCount);
    await prefs.setDouble('alertRadiusKm', _alertRadiusKm);
    await _syncToNative();
  }

  Future<void> _saveUsername(String val) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('username', val);
    _myUsername = val;
    await _syncToNative();
  }

  Future<void> _saveManualContact() async {
    if (_nameController.text.isNotEmpty && _phoneController.text.isNotEmpty) {
      String contactInfo = "${_nameController.text}: ${_phoneController.text}";
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        if (!_savedContacts.contains(contactInfo)) {
          _savedContacts.add(contactInfo);
        }
        _nameController.clear();
        _phoneController.clear();
      });
      await prefs.setStringList('savedContacts', _savedContacts);
      await _syncToNative();
      if (mounted) FocusScope.of(context).unfocus(); // hide keyboard
    }
  }

  Future<void> _pickContact() async {
    if (await Permission.contacts.request().isGranted) {
      List<Contact> contacts = await FlutterContacts.getAll(
        properties: {ContactProperty.name, ContactProperty.phone}
      );
      
      if (!mounted) return;

      showDialog(
        context: context,
        builder: (context) {
          String searchQuery = "";
          return StatefulBuilder(
            builder: (context, setDialogState) {
              List<Contact> filtered = contacts.where((c) {
                String name = c.displayName ?? "";
                return name.toLowerCase().contains(searchQuery.toLowerCase());
              }).toList();

              return AlertDialog(
                title: const Text("Select Contact"),
                content: SizedBox(
                  width: double.maxFinite,
                  height: 400,
                  child: Column(
                    children: [
                      TextField(
                        decoration: const InputDecoration(
                          hintText: "Search contacts...",
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: (val) {
                          setDialogState(() {
                            searchQuery = val;
                          });
                        },
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            Contact c = filtered[index];
                            String contactName = c.displayName ?? "Unknown Contact";
                            if (contactName.isEmpty) contactName = "Unknown Contact";
                            return ListTile(
                              title: Text(contactName),
                              subtitle: Text(c.phones.isNotEmpty ? c.phones.first.number : "No number"),
                              onTap: () async {
                                if (c.phones.isNotEmpty) {
                                  String contactInfo = "$contactName: ${c.phones.first.number}";
                                  final prefs = await SharedPreferences.getInstance();
                                  setState(() {
                                    if (!_savedContacts.contains(contactInfo)) {
                                      _savedContacts.add(contactInfo);
                                    }
                                  });
                                  await prefs.setStringList('savedContacts', _savedContacts);
                                  await _syncToNative();
                                }
                                if (context.mounted) Navigator.pop(context);
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }
          );
        }
      );
    }
  }

  Future<void> _removeContact(int index) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _savedContacts.removeAt(index);
    });
    await prefs.setStringList('savedContacts', _savedContacts);
    await _syncToNative();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nameController.dispose();
    _phoneController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5), // Light background
      appBar: AppBar(
        title: const Text('Emergency Settings', style: TextStyle(color: Colors.black87)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black87),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("My Profile", style: TextStyle(color: Colors.redAccent, fontSize: 18, fontWeight: FontWeight.bold)),
            TextField(
              decoration: const InputDecoration(labelText: 'My Name (For SMS Alerts)', isDense: true),
              style: const TextStyle(color: Colors.black87),
              controller: _usernameController,
              onChanged: _saveUsername,
            ),
            const SizedBox(height: 25),
            
            const Text("Emergency Contacts", style: TextStyle(color: Colors.redAccent, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            
            // Manual Input Fields
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(labelText: 'Name', isDense: true),
                    style: const TextStyle(color: Colors.black87),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Phone', isDense: true),
                    style: const TextStyle(color: Colors.black87),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle, color: Colors.green, size: 30),
                  onPressed: _saveManualContact,
                )
              ],
            ),
            const SizedBox(height: 10),

            // List of chosen contacts
            _savedContacts.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12.0),
                    child: Center(child: Text("No contacts selected yet.", style: TextStyle(color: Colors.black54))),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _savedContacts.length,
                    itemBuilder: (context, index) {
                      return Card(
                        color: Colors.white,
                        elevation: 2,
                        child: ListTile(
                          leading: const Icon(Icons.person, color: Colors.blueAccent),
                          title: Text(_savedContacts[index], style: const TextStyle(color: Colors.black87)),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete, color: Colors.redAccent),
                            onPressed: () => _removeContact(index),
                          ),
                        ),
                      );
                    },
                  ),
            
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _pickContact,
                icon: const Icon(Icons.contacts, color: Colors.white),
                label: const Text("Select from Address Book", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
              ),
            ),
            
            const SizedBox(height: 25),
            const Text("Preferences", style: TextStyle(color: Colors.redAccent, fontSize: 18, fontWeight: FontWeight.bold)),
            
            SwitchListTile(
              title: const Text('Enable Shake to SOS', style: TextStyle(color: Colors.black87)),
              subtitle: const Text('Automatically trigger SOS when phone is shaken hard', style: TextStyle(color: Colors.black54)),
              value: _shakeEnabled,
              activeThumbColor: Colors.redAccent,
              onChanged: (bool value) {
                setState(() => _shakeEnabled = value);
                _saveToggleSettings();
              },
            ),
            SwitchListTile(
              title: const Text('Enable Volume Button SOS', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.w600)),
              subtitle: const Text('Discreetly trigger emergency by clicking phone volume button', style: TextStyle(color: Colors.black54)),
              value: _volumeTriggerEnabled,
              activeThumbColor: Colors.redAccent,
              onChanged: (bool value) {
                setState(() => _volumeTriggerEnabled = value);
                _saveToggleSettings();
              },
            ),
            if (_volumeTriggerEnabled) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Which volume button to press?", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black87)),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: ChoiceChip(
                            label: const Center(child: Text("Volume Down")),
                            selected: _volumeButtonType == "down",
                            selectedColor: Colors.redAccent.withValues(alpha: 0.2),
                            onSelected: (selected) {
                              if (selected) {
                                setState(() => _volumeButtonType = "down");
                                _saveToggleSettings();
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ChoiceChip(
                            label: const Center(child: Text("Volume Up")),
                            selected: _volumeButtonType == "up",
                            selectedColor: Colors.redAccent.withValues(alpha: 0.2),
                            onSelected: (selected) {
                              if (selected) {
                                setState(() => _volumeButtonType = "up");
                                _saveToggleSettings();
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("Required Rapid Clicks:", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black87)),
                        DropdownButton<int>(
                          value: _volumeClickCount,
                          underline: Container(),
                          items: [2, 3, 4, 5].map((count) {
                            return DropdownMenuItem<int>(
                              value: count,
                              child: Text("$count clicks", style: const TextStyle(fontWeight: FontWeight.bold)),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setState(() => _volumeClickCount = val);
                              _saveToggleSettings();
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    // Background Pocket Mode Accessibility Card
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _accessibilityServiceActive ? Colors.green.shade50 : Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: _accessibilityServiceActive ? Colors.green.shade300 : Colors.amber.shade400,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                _accessibilityServiceActive ? Icons.check_circle : Icons.offline_bolt_outlined,
                                color: _accessibilityServiceActive ? Colors.green : Colors.amber.shade900,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _accessibilityServiceActive
                                      ? "Background Pocket SOS: Active"
                                      : "App Closed & Locked Trigger Setup",
                                  style: TextStyle(
                                    color: _accessibilityServiceActive ? Colors.green.shade900 : Colors.amber.shade900,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _accessibilityServiceActive
                                ? "SafeCommute is actively monitoring your ${_volumeButtonType.toUpperCase()} volume button. You can trigger SOS even when this app is closed or your phone is locked."
                                : "To trigger SOS when this app is NOT open or when your phone is locked in your pocket, tap below and toggle SafeCommute ON in Accessibility.",
                            style: TextStyle(
                              color: _accessibilityServiceActive ? Colors.green.shade800 : Colors.black87,
                              fontSize: 12,
                            ),
                          ),
                          if (!_accessibilityServiceActive) ...[
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.amber.shade100.withValues(alpha: 0.6),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.amber.shade300),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(Icons.info_outline, size: 16, color: Colors.amber.shade900),
                                      const SizedBox(width: 6),
                                      Text(
                                        "Fix 'Restricted setting' in 2 Steps:",
                                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.amber.shade900),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  const Text(
                                    "Android 13+ protects sideloaded APKs by default. Tap Step 1 below, tap the 3 dots (⋮) in the top-right corner, and select 'Allow restricted settings'. Then tap Step 2 to turn SafeCommute ON.",
                                    style: TextStyle(fontSize: 11, color: Colors.black87),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.blueGrey.shade800,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                ),
                                icon: const Icon(Icons.settings_applications, size: 18),
                                label: const Text(
                                  "Step 1: Open App Info (Tap ⋮ -> Allow)",
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                ),
                                onPressed: () async {
                                  try {
                                    await _volumeChannel.invokeMethod('openAppSettings');
                                  } catch (_) {}
                                },
                              ),
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.amber.shade900,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                ),
                                icon: const Icon(Icons.settings_accessibility, size: 18),
                                label: const Text(
                                  "Step 2: Turn ON in Accessibility",
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                ),
                                onPressed: () async {
                                  try {
                                    await _volumeChannel.invokeMethod('openAccessibilitySettings');
                                  } catch (_) {}
                                },
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(),
            ],
            SwitchListTile(
              title: const Text('Enable Loud Siren Alarm', style: TextStyle(color: Colors.black87)),
              subtitle: const Text('Plays maximum volume siren on SOS', style: TextStyle(color: Colors.black54)),
              value: _sirenEnabled,
              activeThumbColor: Colors.redAccent,
              onChanged: (bool value) {
                setState(() => _sirenEnabled = value);
                _saveToggleSettings();
              },
            ),
            
            const SizedBox(height: 12),
            // Smart Proximity Notification Filter
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.radar, color: Colors.blueAccent, size: 20),
                      SizedBox(width: 8),
                      Text("Responder Alert Proximity Radius", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.black87)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    "Only nearest responders will receive full siren alerts. Responders outside this radius will not be disturbed or stressed.",
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text("2 km (Local)"),
                        selected: _alertRadiusKm == 2.0,
                        selectedColor: Colors.blueAccent.withValues(alpha: 0.2),
                        onSelected: (selected) {
                          if (selected) {
                            setState(() => _alertRadiusKm = 2.0);
                            _saveToggleSettings();
                          }
                        },
                      ),
                      ChoiceChip(
                        label: const Text("5 km (Standard)"),
                        selected: _alertRadiusKm == 5.0,
                        selectedColor: Colors.blueAccent.withValues(alpha: 0.2),
                        onSelected: (selected) {
                          if (selected) {
                            setState(() => _alertRadiusKm = 5.0);
                            _saveToggleSettings();
                          }
                        },
                      ),
                      ChoiceChip(
                        label: const Text("10 km (City)"),
                        selected: _alertRadiusKm == 10.0,
                        selectedColor: Colors.blueAccent.withValues(alpha: 0.2),
                        onSelected: (selected) {
                          if (selected) {
                            setState(() => _alertRadiusKm = 10.0);
                            _saveToggleSettings();
                          }
                        },
                      ),
                      ChoiceChip(
                        label: const Text("All (No Filter)"),
                        selected: _alertRadiusKm == 0.0,
                        selectedColor: Colors.blueAccent.withValues(alpha: 0.2),
                        onSelected: (selected) {
                          if (selected) {
                            setState(() => _alertRadiusKm = 0.0);
                            _saveToggleSettings();
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),


            
            const SizedBox(height: 25),
            const Text("Hardware Wearable (Bluetooth)", style: TextStyle(color: Colors.redAccent, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Card(
              color: Colors.white,
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.bluetooth, color: Colors.blueAccent, size: 28),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            "Emergency Panic Button (BLE)",
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.black87),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            "Prototype Pending",
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black54),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      "Pairs with your physical ESP32 wearable button. When pressed, hardware automatically triggers instant silent SOS, live GPS tracking, and SMS.",
                      style: TextStyle(color: Colors.black54, fontSize: 13),
                    ),
                    const Divider(height: 24),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text("Enable Hardware Auto-Pairing", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.black87)),
                      subtitle: const Text("Continuously scan for SafeCommute BLE device", style: TextStyle(fontSize: 12, color: Colors.black54)),
                      value: _bleEnabled,
                      activeThumbColor: Colors.blueAccent,
                      onChanged: (val) {
                        setState(() => _bleEnabled = val);
                        _saveToggleSettings();
                      },
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 25),
          ],
        ),
      ),
    );
  }
}
