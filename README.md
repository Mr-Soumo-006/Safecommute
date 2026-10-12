# SafeCommute 🛡️

**An AI-Powered, Community-Driven Safety and Active Defense Platform.**

[![Flutter](https://img.shields.io/badge/Flutter-3.47.7-blue.svg)](https://flutter.dev/)
[![Kotlin](https://img.shields.io/badge/Kotlin-Native_Android-purple.svg)](https://kotlinlang.org/)
[![Node.js](https://img.shields.io/badge/Node.js-Backend-green.svg)](https://nodejs.org/)
[![Socket.io](https://img.shields.io/badge/Socket.io-WebSockets-black.svg)](https://socket.io/)
[![Cloud Hosted](https://img.shields.io/badge/Render-Live_Production-46E3B7.svg)](https://safecommute-uvn5.onrender.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## 📌 Overview

**SafeCommute** is an emergency response and personal security ecosystem designed to provide commuters with instant, stealthy, and automated protection during high-risk travel. 

Built with a high-performance **Flutter** mobile client, low-level **Kotlin** Android hardware hooks, and a 24/7 **Node.js** cloud relay, SafeCommute bridges the gap between victims in distress, their loved ones, and nearby community responders.

---

## 🚀 Key Features

### 1. 🔘 Stealth Pocket Triggers (Hardware Interception)
* **Customizable Volume Key Trigger:** Intercepts physical phone volume buttons using native Kotlin key event listeners (`dispatchKeyEvent`). Commuters can discreetly trigger the SOS while keeping their phone concealed in a pocket or jacket.
* **Configurable Settings:** Users can choose between **Volume Down** or **Volume Up** and set required rapid clicks (**2, 3, 4, or 5 clicks** within a 2-second window).
* **Silent Haptic Confirmation:** Emits a distinct double haptic pulse to reassure the commuter that the SOS has dispatched without alerting bystanders or attackers.
* **G-Force Shake Detection:** Built-in accelerometer listener automatically triggers the alarm if physical struggle or violent movement is detected.

### 2. 📩 Native Background SMS Engine (Physical SIM Fallback)
* **Zero User Intervention:** Uses low-level Android `SmsManager` via Flutter `MethodChannel` to silently send text messages directly across cellular networks without opening the default Messages app.
* **Dynamic Location Links:** Each SMS includes the commuter's name and an instant clickable Google Maps link containing their exact live coordinates:
  > *"Soumo's EMERGENCY! I need help. Track my live location: https://maps.google.com/?q=22.5726,88.3639"*
* **Address Book Picker & Live Search:** Select contacts directly from the device's address book with a real-time instant search bar or enter numbers manually.

### 3. 🗺️ Responder Live Navigation & Blue Dot Dashboard
* **Dual GPS Tracking:**
  * 🔵 **Blue Pulsing Dot:** Tracks the **Responder's** own live position.
  * 🔴 **Red Pin Beacon:** Tracks the **Victim's** moving coordinates in real-time.
* **Dynamic Proximity Counter:** Displays live distance to the victim (e.g. *"380 meters away"* or *"1.4 km away"*).
* **One-Tap Google Maps Navigation:** A dedicated **"Navigate (Google Maps)"** button launches the phone's native Google Maps app with turn-by-turn voice driving or walking directions.
* **Multi-Victim Emergency Feed:** Simultaneously tracks multiple active emergencies across the city with individual battery telemetry and auto-camera focusing.
* **Strict Privacy & SOS Cancellation:** The commuter's GPS is strictly private when idle. The moment an emergency is cancelled, an `alert_cancelled` packet cleanses the victim's pin from all responder maps.

### 4. ⌚ Hardware Wearable (Bluetooth BLE) Ready
* Includes dedicated in-app pairing controls for physical **ESP32** wearable panic buttons, smart rings, and keychain triggers.
* Provides a seamless bridge for upcoming microcontroller hardware integration.

---

## 🏗️ Architecture & Data Flow

```mermaid
flowchart TD
    subgraph Commuter ["Commuter Device (Victim)"]
        H1["Physical Volume Button / Shake"] -->|Hardware Trigger| APP["SafeCommute App (Flutter)"]
        APP -->|MethodChannel| KOTLIN["Native Kotlin SmsManager"]
        APP -->|WebSocket Stream (5s)| CLOUD
    end

    subgraph Cellular ["Cellular Telecom"]
        KOTLIN -->|Silent SMS| CONTACTS["Emergency Contacts' Phones"]
    end

    subgraph Backend ["Cloud Infrastructure (Render)"]
        CLOUD["Node.js Socket.IO Relay Hub<br/>https://safecommute-uvn5.onrender.com"]
    end

    subgraph Responder ["Responder Device (Police / Civilian)"]
        CLOUD -->|incoming_alert broadcast| RES_APP["SafeCommute Responder Map"]
        RES_APP -->|Blue Dot| RES_GPS["Responder GPS"]
        RES_APP -->|Calculate Distance| DIST["Live Proximity (m/km)"]
        RES_APP -->|One-Tap Navigate| GMAPS["Google Maps Turn-by-Turn"]
    end
```

---

## 💻 Tech Stack

* **Mobile App (Frontend):** Flutter 3.47.7, Dart, `flutter_map` (OpenStreetMap), `latlong2`, `geolocator`, `sensors_plus`, `audioplayers`, `shared_preferences`.
* **Native Android Layer:** Kotlin, Android `SmsManager`, `dispatchKeyEvent` interception, `permission_handler`.
* **Backend Server:** Node.js, Express, Socket.IO, Twilio API integration.
* **Cloud Hosting:** Render (24/7 WebSocket Web Service).
* **Electronics / Wearable (Next Phase):** ESP32, Bluetooth Low Energy (BLE), Tactile Panic Switches.

---

## 🛠️ Project Structure

```text
SafeCommute/
├── backend/
│   ├── server.js              # Node.js Socket.IO relay hub & alert routing
│   ├── database.js            # Phase 2 database connection logic
│   └── package.json           # Backend dependencies
├── mobile_flutter/
│   ├── android/
│   │   └── app/src/main/
│   │       ├── AndroidManifest.xml   # Permissions & app label
│   │       └── kotlin/.../MainActivity.kt  # Native SMS & Volume key dispatcher
│   ├── assets/
│   │   └── icon/              # High-resolution app icon assets
│   ├── lib/
│   │   ├── main.dart          # Commuter dashboard, GPS streaming & SOS engine
│   │   ├── responder_map.dart # Responder OpenStreetMap, Blue Dot & navigation
│   │   ├── settings.dart      # Contact search, BLE pairing & volume triggers
│   │   └── role_screen.dart   # Role picker (Commuter vs Responder)
│   └── pubspec.yaml           # Flutter dependencies & launcher icon config
└── README.md
```

---

## ⚡ Getting Started

### 1. Running the Mobile App (Flutter)
```bash
# Navigate to the mobile project
cd mobile_flutter

# Install Flutter dependencies
flutter pub get

# Generate custom launcher icons
dart run flutter_launcher_icons

# Run on an Android device or emulator
flutter run

# Build the production debug APK
flutter build apk --debug
```
*The compiled APK will be output to `build/app/outputs/flutter-apk/app-debug.apk`.*

### 2. Running the Backend Locally
```bash
# Navigate to the backend folder
cd backend

# Install dependencies
npm install

# Start the blind relay hub
node server.js
```
*(By default, the Flutter app is configured to connect to the live cloud server at `https://safecommute-uvn5.onrender.com`).*

---

## 📅 Roadmap

- [x] **Phase 1: Personal Alert & Active Defense** (Complete)
  - Native Kotlin SMS, Shake trigger, Siren alarm, Contact address book with search.
- [x] **Phase 2: Police & Responder Network** (Complete)
  - Live Render cloud relay, Sticky role auto-login, Responder Blue Dot GPS, live distance counter, turn-by-turn Google Maps navigation, multi-victim tracking.
- [ ] **Phase 3: Hardware Wearable & Electronics** (Next Phase)
  - ESP32 BLE panic keychain/ring, pull-pin trigger mechanism, automatic peripheral pairing.
- [ ] **Phase 4: AI Predictive Safety Layer**
  - Machine learning route risk assessment, community safe zones, and automated incident heatmaps.

---

## 📄 License
This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
