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

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();

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
    });
  }

  Future<void> _saveToggleSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sirenEnabled', _sirenEnabled);
    await prefs.setBool('shakeEnabled', _shakeEnabled);
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

      // Show a list of contacts to pick from
      showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text("Select Contact"),
            content: SizedBox(
              width: double.maxFinite,
              height: 300,
              child: ListView.builder(
                itemCount: contacts.length,
                itemBuilder: (context, index) {
                  Contact c = contacts[index];
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Emergency Settings'),
        backgroundColor: Colors.transparent,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Emergency Contacts", style: TextStyle(color: Colors.redAccent, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            
            // Manual Input Fields
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(labelText: 'Name', isDense: true),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Phone', isDense: true),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle, color: Colors.greenAccent, size: 30),
                  onPressed: _saveManualContact,
                )
              ],
            ),
            const SizedBox(height: 10),

            // List of chosen contacts
            Expanded(
              flex: 1,
              child: _savedContacts.isEmpty
                ? const Center(child: Text("No contacts selected yet.", style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    itemCount: _savedContacts.length,
                    itemBuilder: (context, index) {
                      return Card(
                        color: Colors.black45,
                        child: ListTile(
                          leading: const Icon(Icons.person, color: Colors.blueAccent),
                          title: Text(_savedContacts[index]),
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
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
                onPressed: _pickContact,
                icon: const Icon(Icons.contacts),
                label: const Text("Select from Address Book", style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            
            const SizedBox(height: 20),
            const Text("Preferences", style: TextStyle(color: Colors.redAccent, fontSize: 18, fontWeight: FontWeight.bold)),
            
            SwitchListTile(
              title: const Text('Enable Shake to SOS'),
              subtitle: const Text('Automatically trigger SOS when phone is shaken hard'),
              value: _shakeEnabled,
              activeColor: Colors.redAccent,
              onChanged: (bool value) {
                setState(() => _shakeEnabled = value);
                _saveToggleSettings();
              },
            ),
            SwitchListTile(
              title: const Text('Enable Loud Siren Alarm'),
              subtitle: const Text('Plays maximum volume siren on SOS'),
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
