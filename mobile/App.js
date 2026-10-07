import 'react-native-get-random-values';
import React, { useState, useEffect } from 'react';
import { StyleSheet, Text, View, Switch, Alert, Vibration, TouchableOpacity, ActivityIndicator, ScrollView, TextInput, KeyboardAvoidingView, Platform, PermissionsAndroid } from 'react-native';
import { Accelerometer } from 'expo-sensors';
import * as Location from 'expo-location';
import * as Battery from 'expo-battery';
import { useAudioPlayer } from 'expo-audio';
import * as Contacts from 'expo-contacts/legacy';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { Ionicons } from '@expo/vector-icons';
import { io } from 'socket.io-client';
import nacl from 'tweetnacl';
import util from 'tweetnacl-util';
import * as DirectSms from './modules/direct-sms';

// Updated to your actual Wi-Fi IP
const SERVER_URL = 'http://192.168.29.90:3000'; 

export default function App() {
  const [isReady, setIsReady] = useState(false);
  const [showSettings, setShowSettings] = useState(false);
  
  // User Identity
  const [username, setUsername] = useState('');

  // Triggers & State
  const [isShakeEnabled, setIsShakeEnabled] = useState(false);
  const [sosActive, setSosActive] = useState(false);
  
  // Siren State & Player
  const [isSirenEnabled, setIsSirenEnabled] = useState(false);
  const sirenPlayer = useAudioPlayer(require('./assets/siren.ogg'));
  
  // Timer State
  const [isTimerActive, setIsTimerActive] = useState(false);
  const [timeRemaining, setTimeRemaining] = useState(0);

  // Contacts State (Array of Objects: { id, name, number })
  const [contacts, setContacts] = useState([]);
  const [manualName, setManualName] = useState('');
  const [manualNumber, setManualNumber] = useState('');

  // Networking & Crypto
  const [socket, setSocket] = useState(null);
  const [keys, setKeys] = useState(null);

  const SHAKE_THRESHOLD = 3.0;

  useEffect(() => {
    // 1. Initialize System & Load Saved Data
    const initSystem = async () => {
      try {
        const savedUsername = await AsyncStorage.getItem('@username');
        if (savedUsername) setUsername(savedUsername);

        const savedSiren = await AsyncStorage.getItem('@siren');
        if (savedSiren !== null) setIsSirenEnabled(JSON.parse(savedSiren));

        const savedContacts = await AsyncStorage.getItem('@contacts');
        if (savedContacts) {
          let parsed = JSON.parse(savedContacts);
          parsed = parsed.map((c, i) => {
            if (typeof c === 'string') return { id: Date.now().toString() + i, name: 'Legacy Contact', number: c };
            return c;
          });
          setContacts(parsed);
        }
      } catch (err) {
        console.warn("Failed to load local storage data", err);
      }

      if (Platform.OS === 'android') {
        try {
          await PermissionsAndroid.request(
            PermissionsAndroid.PERMISSIONS.SEND_SMS,
            {
              title: "SafeCommute SMS Permission",
              message: "We need access to send SOS text messages in the background directly from your SIM card.",
              buttonNeutral: "Ask Me Later",
              buttonNegative: "Cancel",
              buttonPositive: "OK"
            }
          );
        } catch (err) {
          console.warn(err);
        }
      }

      const keyPair = nacl.box.keyPair();
      setKeys(keyPair);

      const newSocket = io(SERVER_URL);
      setSocket(newSocket);
      
      setIsReady(true);
    };
    initSystem();
    return () => { if (socket) socket.disconnect(); };
  }, []);

  // 2. Accelerometer / Shake Logic
  useEffect(() => {
    let subscription;
    if (isShakeEnabled) {
      Accelerometer.setUpdateInterval(100);
      subscription = Accelerometer.addListener(data => {
        const totalForce = Math.sqrt(data.x * data.x + data.y * data.y + data.z * data.z);
        if (totalForce > SHAKE_THRESHOLD) {
          triggerSOS('Shake Gesture');
        }
      });
    } else {
      if (subscription) subscription.remove();
    }
    return () => { if (subscription) subscription.remove(); };
  }, [isShakeEnabled]);

  // 3. Dead-man's Timer Logic
  useEffect(() => {
    let interval = null;
    if (isTimerActive && timeRemaining > 0) {
      interval = setInterval(() => {
        setTimeRemaining(time => time - 1);
      }, 1000);
    } else if (isTimerActive && timeRemaining <= 0) {
      setIsTimerActive(false);
      clearInterval(interval);
      triggerSOS('Dead-man Commute Timer');
    }
    return () => clearInterval(interval);
  }, [isTimerActive, timeRemaining]);

  // --- SAVE FUNCTIONS ---
  const saveUsername = async (text) => {
    setUsername(text);
    await AsyncStorage.setItem('@username', text);
  };

  const saveContactsData = async (newContactsArray) => {
    setContacts(newContactsArray);
    await AsyncStorage.setItem('@contacts', JSON.stringify(newContactsArray));
  };

  // --- CONTACT MANAGEMENT ---
  const pickContactFromPhonebook = async () => {
    const { status } = await Contacts.requestPermissionsAsync();
    if (status === 'granted') {
      try {
        const contact = await Contacts.presentContactPickerAsync();
        if (contact && contact.phoneNumbers && contact.phoneNumbers.length > 0) {
          const num = contact.phoneNumbers[0].number;
          if (contacts.some(c => c.number === num)) {
            Alert.alert("Already Added", "This contact is already in your emergency list.");
            return;
          }
          const newContact = {
            id: Date.now().toString(),
            name: contact.name || 'Unknown',
            number: num
          };
          saveContactsData([...contacts, newContact]);
        } else if (contact) {
          Alert.alert("No Phone Number", "This contact does not have a phone number saved.");
        }
      } catch (err) {
        console.warn("Picker failed:", err);
      }
    } else {
      Alert.alert("Permission Denied", "We need contacts permission to pick a contact.");
    }
  };

  const addManualContact = () => {
    if (manualNumber.trim() === '') {
      Alert.alert("Missing Information", "Please enter a phone number.");
      return;
    }
    if (manualName.trim() === '') {
      Alert.alert("Missing Information", "Please enter a name for this contact.");
      return;
    }
    const newContact = {
      id: Date.now().toString(),
      name: manualName.trim(),
      number: manualNumber.trim()
    };
    saveContactsData([...contacts, newContact]);
    setManualName('');
    setManualNumber('');
  };

  const removeContact = (idToRemove) => {
    const updated = contacts.filter(c => c.id !== idToRemove);
    saveContactsData(updated);
  };

  // Live Location Tracker State
  const [locationWatcher, setLocationWatcher] = useState(null);

  const cancelSOS = async () => {
    setSosActive(false);
    
    // Stop GPS tracking
    if (locationWatcher) {
      locationWatcher.remove();
      setLocationWatcher(null);
      console.log("Live tracking stopped.");
    }
    
    // Stop Siren
    if (sirenPlayer) {
      sirenPlayer.pause();
      console.log("Siren disabled.");
    }
  };

  // 4. The Core SOS Action
  const triggerSOS = async (source) => {
    if (sosActive) return;
    setSosActive(true);
    setIsShakeEnabled(false); 
    setIsTimerActive(false); 
    setShowSettings(false); 
    Vibration.vibrate(1500);

    let location = null;
    let lat = 'Unknown';
    let lng = 'Unknown';
    let batteryLevel = 'Unknown';

    // 🚀 NEW FEATURE: Audio Alarm / Siren
    if (isSirenEnabled && sirenPlayer) {
      try {
        sirenPlayer.loop = true;
        sirenPlayer.play();
      } catch(err) { console.log("Siren playback failed:", err) }
    }

    // 🚀 NEW FEATURE: Battery Telemetry Data
    try {
      const level = await Battery.getBatteryLevelAsync();
      if (level > 0) batteryLevel = Math.round(level * 100) + '%';
    } catch(e) { console.log("Could not fetch battery level"); }

    try {
      let { status } = await Location.requestForegroundPermissionsAsync();
      if (status !== 'granted') {
        console.log("Location permission denied by user.");
      } else {
        const servicesEnabled = await Location.hasServicesEnabledAsync();
        if (servicesEnabled) {
          location = await Location.getLastKnownPositionAsync({ maxAge: 60000 });
          if (!location) {
            console.log("No instant location, trying fresh GPS...");
            const fetchPromise = Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced });
            const timeoutPromise = new Promise((_, reject) => setTimeout(() => reject(new Error("GPS Timeout")), 5000));
            location = await Promise.race([fetchPromise, timeoutPromise]);
          }
        }
      }
    } catch (error) {
      console.log("GPS fetch timed out or failed. Proceeding with unknown location.");
    }

    if (location) {
      lat = location.coords.latitude;
      lng = location.coords.longitude;
    }

    const mockFamilyKeys = nacl.box.keyPair(); 
    
    // --- 1. SEND INITIAL ONE-TIME ALERTS ---
    const initialGpsData = JSON.stringify({
      lat: lat,
      lng: lng,
      battery: batteryLevel, // Inserted Battery Data
      timestamp: Date.now(),
      triggerSource: source,
      warning: location ? null : 'GPS Signal Lost'
    });

    const nonce = nacl.randomBytes(nacl.box.nonceLength);
    const messageUint8 = util.decodeUTF8(initialGpsData);
    const ciphertext = nacl.box(messageUint8, nonce, mockFamilyKeys.publicKey, keys.secretKey);

    // Send encrypted data to Blind Relay via Socket.io
    if (socket) {
      socket.emit('encrypted_alert', {
        targetContactId: 'family_123',
        gridSector: 'Sector_42B',
        batteryMetadata: batteryLevel, // Unencrypted so server can see it!
        ciphertext: util.encodeBase64(ciphertext),
        nonce: util.encodeBase64(nonce)
      });
    }

    // Send DIRECT SMS via Native SIM Card (Custom Expo Module) - Only done once!
    if (contacts.length > 0) {
      const senderName = username.trim() !== '' ? username.trim() : 'A SafeCommute User';
      const smsMessage = `${senderName} sent an SOS! I need help. Location: https://maps.google.com/?q=${lat},${lng}`;
      try {
        contacts.forEach(contactObj => {
           const cleanNumber = contactObj.number.replace(/[\s-()]/g, '');
           DirectSms.sendSms(cleanNumber, smsMessage);
        });
        console.log("Direct SMS block completed!");
      } catch (err) {
        console.log("[NATIVE SMS ERROR] Failed to run native module:", err);
      }
    }

    // --- 2. START CONTINUOUS LIVE TRACKING ---
    try {
      const watcher = await Location.watchPositionAsync(
        {
          accuracy: Location.Accuracy.High,
          timeInterval: 5000, 
          distanceInterval: 5,
        },
        (newLocation) => {
          const liveLat = newLocation.coords.latitude;
          const liveLng = newLocation.coords.longitude;
          
          const liveGpsData = JSON.stringify({
            lat: liveLat,
            lng: liveLng,
            battery: batteryLevel, // Inside encrypted payload too
            timestamp: Date.now(),
            triggerSource: 'Live Tracking Update',
            isLive: true
          });

          const liveNonce = nacl.randomBytes(nacl.box.nonceLength);
          const liveMessageUint8 = util.decodeUTF8(liveGpsData);
          const liveCiphertext = nacl.box(liveMessageUint8, liveNonce, mockFamilyKeys.publicKey, keys.secretKey);

          if (socket) {
            socket.emit('encrypted_alert', {
              targetContactId: 'family_123',
              gridSector: 'Sector_42B',
              batteryMetadata: batteryLevel, // Unencrypted so server can see it!
              ciphertext: util.encodeBase64(liveCiphertext),
              nonce: util.encodeBase64(liveNonce),
              isLiveUpdate: true
            });
            console.log("Live location update sent to server!");
          }
        }
      );
      setLocationWatcher(watcher);
    } catch (err) {
      console.log("Could not start live tracking", err);
    }

    Alert.alert(
      "🚨 SOS SENT! 🚨",
      `Your encrypted live location is now streaming to the server. Direct SMS fallbacks were dispatched.`,
      [{ text: "I'm Safe (Cancel)", onPress: cancelSOS, style: "cancel" }]
    );
  };

  if (!isReady) {
    return (
      <View style={styles.centerContainer}>
        <ActivityIndicator size="large" color="#f44336" />
        <Text style={{marginTop: 10, color: '#555', fontWeight: '500'}}>Initializing Security Engine...</Text>
      </View>
    );
  }

  // --- SETTINGS VIEW ---
  if (showSettings) {
    return (
      <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : 'height'} style={styles.settingsContainer}>
        <View style={styles.headerRow}>
          <TouchableOpacity onPress={() => setShowSettings(false)} style={styles.iconButton}>
            <Ionicons name="arrow-back" size={28} color="#333" />
          </TouchableOpacity>
          <Text style={styles.header}>Settings</Text>
          <View style={{ width: 28 }} /> 
        </View>

        <ScrollView showsVerticalScrollIndicator={false} keyboardShouldPersistTaps="handled">
          
          {/* PROFILE CARD */}
          <View style={styles.card}>
            <Text style={styles.title}>Profile Information</Text>
            <Text style={styles.description}>Your name will be included in the emergency SMS so your contacts know it's you.</Text>
            <View style={styles.inputGroup}>
              <Ionicons name="person-outline" size={20} color="#7f8c8d" style={styles.inputIcon} />
              <TextInput 
                style={styles.textInput} 
                placeholder="Enter your full name" 
                value={username}
                onChangeText={saveUsername}
              />
            </View>
          </View>

          {/* EMERGENCY CONTACTS CARD */}
          <View style={styles.card}>
            <Text style={styles.title}>Emergency Contacts</Text>
            <Text style={styles.description}>These people will receive your SOS text message via your physical SIM card.</Text>
            
            <TouchableOpacity style={styles.phonebookBtn} onPress={pickContactFromPhonebook}>
              <Ionicons name="journal-outline" size={20} color="#fff" />
              <Text style={styles.phonebookBtnText}>Select from Phonebook</Text>
            </TouchableOpacity>

            <View style={styles.divider} />

            {contacts.map((contact) => (
              <View key={contact.id} style={styles.contactRow}>
                <View style={styles.contactDetails}>
                  <Text style={styles.contactName}>{contact.name}</Text>
                  <Text style={styles.contactNumber}>{contact.number}</Text>
                </View>
                <TouchableOpacity style={styles.deleteContactBtn} onPress={() => removeContact(contact.id)}>
                  <Ionicons name="close-circle" size={24} color="#f44336" />
                </TouchableOpacity>
              </View>
            ))}

            {contacts.length === 0 && (
              <Text style={styles.emptyContactsText}>No contacts added yet.</Text>
            )}

            <View style={styles.divider} />
            <Text style={styles.subTitle}>Or Add Manually:</Text>
            <View style={styles.manualAddRow}>
              <View style={styles.manualInputCol}>
                <TextInput 
                  style={[styles.input, {marginBottom: 8}]} 
                  placeholder="Name (e.g. Mom)" 
                  value={manualName}
                  onChangeText={setManualName}
                />
                <TextInput 
                  style={styles.input} 
                  placeholder="Phone (e.g. +91 9876543210)" 
                  keyboardType="phone-pad"
                  value={manualNumber}
                  onChangeText={setManualNumber}
                />
              </View>
              <TouchableOpacity style={styles.addButton} onPress={addManualContact}>
                <Ionicons name="add" size={24} color="#fff" />
              </TouchableOpacity>
            </View>
          </View>

          {/* TIMER CARD */}
          <View style={styles.card}>
            <Text style={styles.title}>Commute Timer (Dead-man)</Text>
            <Text style={styles.description}>Start a countdown that triggers SOS automatically if you don't cancel it in time.</Text>
            <TouchableOpacity style={styles.startTimerBtn} onPress={() => { setTimeRemaining(15); setIsTimerActive(true); setShowSettings(false); }}>
              <Ionicons name="timer-outline" size={20} color="#fff" style={{marginRight: 8}} />
              <Text style={styles.startTimerText}>Start 15s Test Timer</Text>
            </TouchableOpacity>
          </View>

          {/* HARDWARE TRIGGERS CARD */}
          <View style={styles.card}>
            <Text style={styles.title}>Hardware Triggers & Safety</Text>

            {/* SIREN TOGGLE */}
            <View style={[styles.switchContainer, { marginBottom: 15 }]}>
              <View>
                <Text style={styles.switchLabel}>Loud Siren Alarm</Text>
                <Text style={styles.switchSubLabel}>{isSirenEnabled ? "Will sound on SOS" : "Silent Mode"}</Text>
              </View>
              <Switch
                trackColor={{ false: "#767577", true: "#f44336" }}
                thumbColor={isSirenEnabled ? "#fff" : "#f4f3f4"}
                onValueChange={(val) => {
                  setIsSirenEnabled(val);
                  AsyncStorage.setItem('@siren', JSON.stringify(val));
                }}
                value={isSirenEnabled}
              />
            </View>

            {/* SHAKE TOGGLE */}
            <View style={styles.switchContainer}>
              <View>
                <Text style={styles.switchLabel}>Shake-to-Alert</Text>
                <Text style={styles.switchSubLabel}>{isShakeEnabled ? "Armed & Active" : "Safe Mode"}</Text>
              </View>
              <Switch
                trackColor={{ false: "#767577", true: "#f44336" }}
                thumbColor={isShakeEnabled ? "#fff" : "#f4f3f4"}
                onValueChange={() => setIsShakeEnabled(prev => !prev)}
                value={isShakeEnabled}
              />
            </View>
          </View>
          <View style={{height: 40}}/>
        </ScrollView>
      </KeyboardAvoidingView>
    );
  }

  // --- HOME VIEW ---
  return (
    <View style={styles.container}>
      
      <View style={styles.homeHeaderRow}>
        <View>
          <Text style={styles.logoText}>SafeCommute</Text>
          {username ? <Text style={styles.welcomeText}>Hello, {username}</Text> : null}
        </View>
        <TouchableOpacity style={styles.settingsBtn} onPress={() => setShowSettings(true)}>
          <Ionicons name="settings-sharp" size={24} color="#fff" />
        </TouchableOpacity>
      </View>
      
      {isTimerActive && (
        <View style={styles.timerActiveContainer}>
          <Text style={styles.timerTitle}>Commute Timer Active</Text>
          <Text style={styles.timerText}>
            00:{timeRemaining < 10 ? `0${timeRemaining}` : timeRemaining}
          </Text>
          <TouchableOpacity style={styles.cancelTimerBtn} onPress={() => setIsTimerActive(false)}>
            <Text style={styles.cancelTimerText}>I'm Safe (Cancel)</Text>
          </TouchableOpacity>
        </View>
      )}

      <View style={styles.sosContainer}>
        <TouchableOpacity 
          style={[styles.mainSosButton, sosActive && styles.mainSosButtonActive]} 
          onPress={() => triggerSOS('Manual Button')}
          activeOpacity={0.8}
        >
          <Text style={styles.mainSosButtonText}>{sosActive ? "SENT!" : "SOS"}</Text>
        </TouchableOpacity>
        <Text style={styles.sosHint}>Tap instantly to broadcast emergency</Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  centerContainer: { flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: '#F4F7FC' },
  container: { flex: 1, backgroundColor: '#F4F7FC', paddingTop: 60 },
  homeHeaderRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', paddingHorizontal: 25, marginBottom: 20 },
  logoText: { fontSize: 28, fontWeight: '900', color: '#1A2530', letterSpacing: -0.5 },
  welcomeText: { fontSize: 14, color: '#7F8FA4', marginTop: 2, fontWeight: '500' },
  settingsBtn: { backgroundColor: '#1A2530', padding: 12, borderRadius: 30, shadowColor: '#000', shadowOffset: { width: 0, height: 4 }, shadowOpacity: 0.15, shadowRadius: 6, elevation: 5 },
  sosContainer: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  mainSosButton: { width: 240, height: 240, backgroundColor: '#FF3B30', borderRadius: 120, alignItems: 'center', justifyContent: 'center', shadowColor: '#FF3B30', shadowOffset: { width: 0, height: 15 }, shadowOpacity: 0.4, shadowRadius: 20, elevation: 15, borderWidth: 6, borderColor: '#FFD7D5' },
  mainSosButtonActive: { backgroundColor: '#D32F2F', borderColor: '#FFCDD2', transform: [{ scale: 0.95 }] },
  mainSosButtonText: { color: 'white', fontSize: 60, fontWeight: '900', letterSpacing: 2 },
  sosHint: { marginTop: 30, color: '#7F8FA4', fontSize: 14, fontWeight: '600', textTransform: 'uppercase', letterSpacing: 1 },
  timerActiveContainer: { alignItems: 'center', backgroundColor: '#FFF8E1', padding: 25, marginHorizontal: 25, borderRadius: 20, borderWidth: 2, borderColor: '#FFB300', marginTop: 10, shadowColor: '#FFB300', shadowOffset: { width: 0, height: 5 }, shadowOpacity: 0.2, shadowRadius: 8, elevation: 5 },
  timerTitle: { fontSize: 14, color: '#FF8F00', fontWeight: '800', textTransform: 'uppercase', letterSpacing: 1 },
  timerText: { fontSize: 60, fontWeight: '900', color: '#FFB300', marginVertical: 10 },
  cancelTimerBtn: { backgroundColor: '#34C759', paddingVertical: 16, paddingHorizontal: 40, borderRadius: 30, shadowColor: '#34C759', shadowOffset: { width: 0, height: 4 }, shadowOpacity: 0.3, shadowRadius: 5, elevation: 4 },
  cancelTimerText: { color: 'white', fontWeight: '800', fontSize: 16, textTransform: 'uppercase' },
  settingsContainer: { flex: 1, backgroundColor: '#F4F7FC', paddingTop: 60, paddingHorizontal: 20 },
  headerRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 20 },
  header: { fontSize: 22, fontWeight: '800', color: '#1A2530' },
  iconButton: { padding: 5, backgroundColor: '#fff', borderRadius: 20, shadowColor: '#000', shadowOffset: { width: 0, height: 2 }, shadowOpacity: 0.05, shadowRadius: 3, elevation: 2 },
  card: { backgroundColor: 'white', padding: 22, borderRadius: 20, shadowColor: '#000', shadowOffset: { width: 0, height: 5 }, shadowOpacity: 0.05, shadowRadius: 10, elevation: 3, marginBottom: 20 },
  title: { fontSize: 18, fontWeight: '800', marginBottom: 6, color: '#1A2530' },
  subTitle: { fontSize: 14, fontWeight: '700', color: '#1A2530', marginBottom: 10 },
  description: { fontSize: 13, color: '#7F8FA4', marginBottom: 18, lineHeight: 18 },
  inputGroup: { flexDirection: 'row', alignItems: 'center', backgroundColor: '#F8FAFC', borderWidth: 1, borderColor: '#E2E8F0', borderRadius: 12, paddingHorizontal: 15, height: 50 },
  inputIcon: { marginRight: 10 },
  textInput: { flex: 1, fontSize: 16, color: '#1A2530', fontWeight: '500' },
  phonebookBtn: { flexDirection: 'row', backgroundColor: '#007AFF', padding: 14, borderRadius: 12, alignItems: 'center', justifyContent: 'center', marginBottom: 15 },
  phonebookBtnText: { color: 'white', fontSize: 16, fontWeight: '700', marginLeft: 8 },
  divider: { height: 1, backgroundColor: '#E2E8F0', marginVertical: 15 },
  contactRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', backgroundColor: '#F8FAFC', borderWidth: 1, borderColor: '#E2E8F0', padding: 12, borderRadius: 12, marginBottom: 10 },
  contactDetails: { flex: 1 },
  contactName: { fontSize: 15, fontWeight: '700', color: '#1A2530' },
  contactNumber: { fontSize: 13, color: '#7F8FA4', marginTop: 2, fontWeight: '500' },
  deleteContactBtn: { padding: 5 },
  emptyContactsText: { textAlign: 'center', color: '#A0AABF', fontStyle: 'italic', marginBottom: 10 },
  manualAddRow: { flexDirection: 'row', alignItems: 'stretch' },
  manualInputCol: { flex: 1, marginRight: 10 },
  input: { backgroundColor: '#F8FAFC', borderWidth: 1, borderColor: '#E2E8F0', borderRadius: 8, paddingHorizontal: 12, height: 40, fontSize: 14, color: '#1A2530' },
  addButton: { backgroundColor: '#34C759', width: 50, borderRadius: 12, alignItems: 'center', justifyContent: 'center', shadowColor: '#34C759', shadowOffset: { width: 0, height: 3 }, shadowOpacity: 0.3, shadowRadius: 4, elevation: 3 },
  switchContainer: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', backgroundColor: '#F8FAFC', borderWidth: 1, borderColor: '#E2E8F0', padding: 15, borderRadius: 12 },
  switchLabel: { fontSize: 16, fontWeight: '700', color: '#1A2530' },
  switchSubLabel: { fontSize: 12, color: '#7F8FA4', marginTop: 2, fontWeight: '600' },
  startTimerBtn: { flexDirection: 'row', backgroundColor: '#FF9500', padding: 15, borderRadius: 12, alignItems: 'center', justifyContent: 'center', shadowColor: '#FF9500', shadowOffset: { width: 0, height: 4 }, shadowOpacity: 0.3, shadowRadius: 6, elevation: 4 },
  startTimerText: { color: 'white', fontWeight: '700', fontSize: 16 }
});
