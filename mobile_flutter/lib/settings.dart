import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _sirenEnabled = true;
  bool _shakeEnabled = true;
  List<String> _savedContacts = [];
  String _myUsername = "";

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController(); // Fixed controller!

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _sirenEnabled = prefs.getBool('sirenEnabled') ?? true;
      _shakeEnabled = prefs.getBool('shakeEnabled') ?? true;
      _savedContacts = prefs.getStringList('savedContacts') ?? [];
      _myUsername = prefs.getString('username') ?? "";
      _usernameController.text = _myUsername; // Set initial value here
    });
  }

  Future<void> _saveToggleSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sirenEnabled', _sirenEnabled);
    await prefs.setBool('shakeEnabled', _shakeEnabled);
  }

  Future<void> _saveUsername(String val) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('username', val);
    _myUsername = val; // No setState needed here since the controller maintains its own state and cursor position
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
                            return ListTile(
                              title: Text(c.displayName ?? "Unknown Contact"),
                              subtitle: Text(c.phones.isNotEmpty ? c.phones.first.number ?? "No number" : "No number"),
                              onTap: () async {
                                if (c.phones.isNotEmpty) {
                                  String contactInfo = "${c.displayName ?? "Unknown"}: ${c.phones.first.number ?? ""}";
                                  final prefs = await SharedPreferences.getInstance();
                                  setState(() {
                                    if (!_savedContacts.contains(contactInfo)) {
                                      _savedContacts.add(contactInfo);
                                    }
                                  });
                                  await prefs.setStringList('savedContacts', _savedContacts);
                                }
                                Navigator.pop(context);
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
  }

  @override
  void dispose() {
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
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("My Profile", style: TextStyle(color: Colors.redAccent, fontSize: 18, fontWeight: FontWeight.bold)),
            TextField(
              decoration: const InputDecoration(labelText: 'My Name (For SMS Alerts)', isDense: true),
              style: const TextStyle(color: Colors.black87),
              controller: _usernameController, // Using the persistent controller now!
              onChanged: _saveUsername,
            ),
            const SizedBox(height: 20),
            
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
            Expanded(
              flex: 1,
              child: _savedContacts.isEmpty
                ? const Center(child: Text("No contacts selected yet.", style: TextStyle(color: Colors.black54)))
                : ListView.builder(
                    itemCount: _savedContacts.length,
                    itemBuilder: (context, index) {
                      return Card(
                        color: Colors.white, // Light mode card
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
            ),
            
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
            
            const SizedBox(height: 20),
            const Text("Preferences", style: TextStyle(color: Colors.redAccent, fontSize: 18, fontWeight: FontWeight.bold)),
            
            SwitchListTile(
              title: const Text('Enable Shake to SOS', style: TextStyle(color: Colors.black87)),
              subtitle: const Text('Automatically trigger SOS when phone is shaken hard', style: TextStyle(color: Colors.black54)),
              value: _shakeEnabled,
              activeColor: Colors.redAccent,
              onChanged: (bool value) {
                setState(() => _shakeEnabled = value);
                _saveToggleSettings();
              },
            ),
            SwitchListTile(
              title: const Text('Enable Loud Siren Alarm', style: TextStyle(color: Colors.black87)),
              subtitle: const Text('Plays maximum volume siren on SOS', style: TextStyle(color: Colors.black54)),
              value: _sirenEnabled,
              activeColor: Colors.redAccent,
              onChanged: (bool value) {
                setState(() => _sirenEnabled = value);
                _saveToggleSettings();
              },
            ),
          ],
        ),
      ),
    );
  }
}
