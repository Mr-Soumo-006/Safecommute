import 'react-native-get-random-values';
import React, { useState, useEffect } from 'react';
import { StyleSheet, Text, View, Switch, Alert, Vibration, TouchableOpacity, ActivityIndicator, ScrollView, TextInput, KeyboardAvoidingView, Platform } from 'react-native';
import { Accelerometer } from 'expo-sensors';
import * as Location from 'expo-location';
import * as SMS from 'expo-sms';
import { Ionicons } from '@expo/vector-icons';
import { io } from 'socket.io-client';
import nacl from 'tweetnacl';
import util from 'tweetnacl-util';

// Updated to your actual Wi-Fi IP
const SERVER_URL = 'http://192.168.29.218:3000'; 

export default function App() {
  const [isReady, setIsReady] = useState(false);
  const [showSettings, setShowSettings] = useState(false);
  
  // Triggers & State
  const [isShakeEnabled, setIsShakeEnabled] = useState(false);
  const [sosActive, setSosActive] = useState(false);
  
  // Timer State
  const [isTimerActive, setIsTimerActive] = useState(false);
  const [timeRemaining, setTimeRemaining] = useState(0);

  // Contacts State
  const [contacts, setContacts] = useState([]);
  const [newContact, setNewContact] = useState('');

  // Networking & Crypto
  const [socket, setSocket] = useState(null);
  const [keys, setKeys] = useState(null);

  const SHAKE_THRESHOLD = 3.0;

  useEffect(() => {
    // 1. Initialize Cryptography & Socket Connection
    const initSystem = () => {
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

  const startCommuteTimer = () => {
    setTimeRemaining(15); 
    setIsTimerActive(true);
    setShowSettings(false); // Go back to home to see the timer
  };

  const addContact = () => {
    if (newContact.trim() === '') return;
    setContacts([...contacts, newContact.trim()]);
    setNewContact('');
  };

  const removeContact = (index) => {
    const updated = [...contacts];
    updated.splice(index, 1);
    setContacts(updated);
  };

  // 4. The Core SOS Action
  const triggerSOS = async (source) => {
    if (sosActive) return;
    setSosActive(true);
    setIsShakeEnabled(false); 
    setIsTimerActive(false); 
    setShowSettings(false); // Force back to home screen
    Vibration.vibrate(1500);

    // Fetch GPS with fallback logic
    let location = null;
    let lat = 'Unknown';
    let lng = 'Unknown';

    try {
      const servicesEnabled = await Location.hasServicesEnabledAsync();
      if (servicesEnabled) {
        location = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced });
      }
    } catch (error) {
      console.log("Fresh GPS failed, trying last known...");
      try {
        location = await Location.getLastKnownPositionAsync();
      } catch (fallbackError) {
        console.log("No location available.");
      }
    }

    if (location) {
      lat = location.coords.latitude;
      lng = location.coords.longitude;
    }

    const gpsData = JSON.stringify({
      lat: lat,
      lng: lng,
      timestamp: Date.now(),
      triggerSource: source,
      warning: location ? null : 'GPS Signal Lost'
    });

    // Encrypt payload (for Socket.io)
    const mockFamilyKeys = nacl.box.keyPair(); 
    const nonce = nacl.randomBytes(nacl.box.nonceLength);
    const messageUint8 = util.decodeUTF8(gpsData);
    const ciphertext = nacl.box(messageUint8, nonce, mockFamilyKeys.publicKey, keys.secretKey);

    // Send encrypted data to Blind Relay via Socket.io
    if (socket) {
      socket.emit('encrypted_alert', {
        targetContactId: 'family_123',
        gridSector: 'Sector_42B',
        ciphertext: util.encodeBase64(ciphertext),
        nonce: util.encodeBase64(nonce)
      });
    }

    // Send Fallback SMS to Emergency Contacts automatically via Backend (Twilio API)
    if (contacts.length > 0) {
      const smsMessage = `🚨 SAFE-COMMUTE SOS 🚨\nI need help! My last known location is: https://maps.google.com/?q=${lat},${lng}`;
      if (socket) {
        socket.emit('trigger_sms_fallback', {
          contacts: contacts,
          message: smsMessage
        });
      }
    }

    Alert.alert(
      "🚨 SOS SENT! 🚨",
      `Your encrypted location was sent to the server. SMS fallbacks have been generated.`,
      [{ text: "I'm Safe (Cancel)", onPress: () => setSosActive(false), style: "cancel" }]
    );
  };

  if (!isReady) {
    return (
      <View style={styles.centerContainer}>
        <ActivityIndicator size="large" color="#f44336" />
        <Text style={{marginTop: 10}}>Initializing Encrypted Security Engine...</Text>
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

        <ScrollView showsVerticalScrollIndicator={false}>
          {/* Contacts Section */}
          <View style={styles.card}>
            <Text style={styles.title}>Emergency Contacts</Text>
            <Text style={styles.description}>These numbers will receive an SMS fallback with your location if SOS is triggered.</Text>
            
            {contacts.map((contact, index) => (
              <View key={index} style={styles.contactRow}>
                <Text style={styles.contactText}>{contact}</Text>
                <TouchableOpacity onPress={() => removeContact(index)}>
                  <Ionicons name="trash-outline" size={24} color="#f44336" />
                </TouchableOpacity>
              </View>
            ))}

            <View style={styles.addContactRow}>
              <TextInput 
                style={styles.input} 
                placeholder="Phone Number (e.g. +91 9876543210)" 
                keyboardType="phone-pad"
                value={newContact}
                onChangeText={setNewContact}
              />
              <TouchableOpacity style={styles.addButton} onPress={addContact}>
                <Ionicons name="add" size={24} color="#fff" />
              </TouchableOpacity>
            </View>
          </View>

          {/* Commute Timer Section */}
          <View style={styles.card}>
            <Text style={styles.title}>Commute Timer (Dead-man)</Text>
            <Text style={styles.description}>Start a countdown that triggers SOS if you don't cancel it in time.</Text>
            <TouchableOpacity style={styles.startTimerBtn} onPress={startCommuteTimer}>
              <Text style={styles.startTimerText}>Start 15s Test Timer</Text>
            </TouchableOpacity>
          </View>

          {/* Hardware Triggers Section */}
          <View style={styles.card}>
            <Text style={styles.title}>Hardware Triggers</Text>
            <View style={styles.switchContainer}>
              <Text style={styles.switchLabel}>Shake-to-Alert {isShakeEnabled ? "(Armed)" : "(Safe)"}</Text>
              <Switch
                trackColor={{ false: "#767577", true: "#f44336" }}
                thumbColor={isShakeEnabled ? "#fff" : "#f4f3f4"}
                onValueChange={() => setIsShakeEnabled(prev => !prev)}
                value={isShakeEnabled}
              />
            </View>
          </View>
        </ScrollView>
      </KeyboardAvoidingView>
    );
  }

  // --- HOME VIEW ---
  return (
    <View style={styles.container}>
      
      <View style={styles.homeHeaderRow}>
        <TouchableOpacity style={styles.settingsBtn} onPress={() => setShowSettings(true)}>
          <Ionicons name="settings-sharp" size={24} color="#fff" />
        </TouchableOpacity>
        <Text style={styles.logoText}>SafeCommute</Text>
        <View style={{ width: 44 }} />
      </View>
      
      {/* Active Timer Overlay (Only shows if timer is ticking) */}
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

      {/* Main SOS Button */}
      <View style={styles.sosContainer}>
        <TouchableOpacity 
          style={[styles.mainSosButton, sosActive && styles.mainSosButtonActive]} 
          onPress={() => triggerSOS('Manual Button')}
          activeOpacity={0.8}
        >
          <Text style={styles.mainSosButtonText}>{sosActive ? "SOS SENT" : "SOS"}</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  centerContainer: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#f8f9fa',
  },
  // Home Styles
  container: {
    flex: 1,
    backgroundColor: '#f8f9fa',
    paddingTop: 50,
  },
  homeHeaderRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingHorizontal: 20,
    marginBottom: 20,
  },
  logoText: {
    fontSize: 24,
    fontWeight: 'bold',
    color: '#333',
  },
  settingsBtn: {
    backgroundColor: '#2196F3',
    padding: 10,
    borderRadius: 25,
  },
  sosContainer: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
  mainSosButton: {
    width: 250,
    height: 250,
    backgroundColor: '#f44336',
    borderRadius: 125,
    alignItems: 'center',
    justifyContent: 'center',
    shadowColor: '#f44336',
    shadowOffset: { width: 0, height: 10 },
    shadowOpacity: 0.4,
    shadowRadius: 15,
    elevation: 12,
  },
  mainSosButtonActive: {
    backgroundColor: '#d32f2f',
  },
  mainSosButtonText: {
    color: 'white',
    fontSize: 55,
    fontWeight: 'bold',
  },
  // Timer Overlay Styles
  timerActiveContainer: {
    alignItems: 'center',
    backgroundColor: '#fff3e0',
    padding: 20,
    marginHorizontal: 20,
    borderRadius: 15,
    borderWidth: 2,
    borderColor: '#ff9800',
    marginTop: 20,
  },
  timerTitle: {
    fontSize: 16,
    color: '#ff9800',
    fontWeight: '600',
  },
  timerText: {
    fontSize: 55,
    fontWeight: 'bold',
    color: '#ff9800',
    marginVertical: 10,
  },
  cancelTimerBtn: {
    backgroundColor: '#4CAF50',
    paddingVertical: 15,
    paddingHorizontal: 40,
    borderRadius: 10,
  },
  cancelTimerText: {
    color: 'white',
    fontWeight: 'bold',
    fontSize: 18,
  },
  // Settings Styles
  settingsContainer: {
    flex: 1,
    backgroundColor: '#f8f9fa',
    paddingTop: 50,
    paddingHorizontal: 20,
  },
  headerRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 25,
  },
  header: {
    fontSize: 24,
    fontWeight: 'bold',
    color: '#333',
  },
  iconButton: {
    padding: 5,
  },
  card: {
    backgroundColor: 'white',
    padding: 20,
    borderRadius: 15,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.1,
    shadowRadius: 8,
    elevation: 4,
    marginBottom: 20,
  },
  title: {
    fontSize: 18,
    fontWeight: 'bold',
    marginBottom: 8,
    color: '#2c3e50',
  },
  description: {
    fontSize: 13,
    color: '#7f8c8d',
    marginBottom: 15,
    lineHeight: 18,
  },
  // Contacts Styles
  contactRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    backgroundColor: '#f1f2f6',
    padding: 12,
    borderRadius: 8,
    marginBottom: 10,
  },
  contactText: {
    fontSize: 16,
    color: '#2f3542',
  },
  addContactRow: {
    flexDirection: 'row',
    marginTop: 10,
  },
  input: {
    flex: 1,
    backgroundColor: '#f1f2f6',
    borderRadius: 8,
    paddingHorizontal: 15,
    height: 45,
    marginRight: 10,
  },
  addButton: {
    backgroundColor: '#2196F3',
    width: 45,
    height: 45,
    borderRadius: 8,
    alignItems: 'center',
    justifyContent: 'center',
  },
  // Other Settings Elements
  switchContainer: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    backgroundColor: '#f1f2f6',
    padding: 15,
    borderRadius: 8,
  },
  switchLabel: {
    fontSize: 15,
    fontWeight: '600',
    color: '#333',
  },
  startTimerBtn: {
    backgroundColor: '#2196F3',
    padding: 15,
    borderRadius: 8,
    alignItems: 'center',
  },
  startTimerText: {
    color: 'white',
    fontWeight: 'bold',
    fontSize: 15,
  },
});
