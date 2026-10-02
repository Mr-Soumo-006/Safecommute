# SafeCommute 🛡️

An AI-Powered, Community-Driven Safety and Active Defense Platform.

**Current Status:** 🚧 **Phase 1 (In Progress)**

## Structural Overview
SafeCommute is built in four phases on one shared backend. Every alert is end-to-end encrypted, so the server only relays ciphertext and cannot read alert contents (Zero-Knowledge Architecture).

## 🔒 Security Core (Zero-Knowledge & E2EE)
Each phone creates its own key pair (private key stays on the device), encrypts the GPS location for each contact, and sends it through a blind relay. The exact location is revealed only when a verified responder or contact accepts the alert and decrypts it locally.

---

## 🚀 Project Phases & Roadmap

### ✅ Phase 1 — Personal Alert (Currently Building)
**Goal:** Prove the core concept by allowing users to trigger alerts without opening the app, reliably tracking them in the background, and instantly notifying contacts.
* **Features Built:** 
  * Manual SOS Button
  * Hardware Shake-to-Alert (Accelerometer)
  * Commute Timer (Dead-man's switch)
  * Zero-Knowledge E2EE Encryption
  * Twilio SMS Fallback Integration
* **Tech Stack:** React Native, Expo, TweetNaCl (Pure JS Crypto), Node.js, Socket.io, Twilio.

### ⏳ Phase 2 — Police & Responder Network
**Goal:** Route Phase 1 alerts beyond family members—sending them instantly to local authorities and verified civilian responders nearby using grid-based geospatial matching.
* **Tech Stack:** PostgreSQL + PostGIS, React.js Web Dashboard, Socket.io.

### ⏳ Phase 3 — The Active Defense Wearable (Hardware)
**Goal:** Introduce a hands-free companion device that detects an attack using physical sensors and provides an active deterrent.
* **Features:** IMU + Mic + mmWave Radar for struggle signatures. Siren/Strobe deterrent. Bluetooth link to the Phase 1 mobile app.
* **Tech Stack:** ESP32, MPU6050, mmWave module, BLE, C++/Arduino.

### ⏳ Phase 4 — AI Predictive Layer & Community
**Goal:** Move from reactive safety to proactive prevention using machine learning on historical and environmental data.
* **Features:** Route Risk Scoring, Community Safe Points, Gamified Bystander mobilization.
* **Tech Stack:** Python, FastAPI, TensorFlow/Scikit-learn.

---

## 🛠️ Getting Started (Running Phase 1)

This repository currently contains the Phase 1 source code.

### 1. The Blind Relay (Backend)
```bash
cd backend
npm install
# Add your Twilio credentials to backend/.env
npm start
```

### 2. The Mobile App (Frontend)
```bash
cd mobile
npm install
npx expo start
```
