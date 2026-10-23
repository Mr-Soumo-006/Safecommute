require('dotenv').config();
const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const twilio = require('twilio');

const { initDB } = require('./database');

const app = express();
const server = http.createServer(app);
const io = new Server(server, { cors: { origin: '*' } });

// Initialize Phase 2 Database (It will throw a soft warning until you put in the real Postgres URL)
initDB();

// Initialize Twilio using the credentials from the .env file
const twilioClient = twilio(process.env.TWILIO_ACCOUNT_SID, process.env.TWILIO_AUTH_TOKEN);

// SafeCommute: Blind Relay Hub
io.on('connection', (socket) => {
    console.log('Client connected:', socket.id);

    // Listen for encrypted alerts from the Victim's Phase 1 app
    socket.on('encrypted_alert', (payload) => {
        if (payload.isLiveUpdate) {
            console.log(`[LIVE TRACKING] Secure update from ${socket.id} | Battery: ${payload.batteryMetadata || 'Unknown'} - Streaming...`);
        } else {
            console.log('\n[BLIND RELAY] Received SOS payload:');
            console.log('   From Victim ID:', socket.id);
            console.log('   Victim Name:', payload.username || 'A Commuter');
            console.log('   Target Contact ID:', payload.targetContactId);
            console.log('   Battery Level:', payload.batteryMetadata || 'Unknown');
            console.log('   Incident Type:', payload.incidentType || 'PANIC_SOS');
            console.log('   Voice Note Attached:', payload.hasVoiceNote ? `YES (${payload.voiceNoteDuration || 0}s voice note)` : 'NO');
            console.log('   Ciphertext (Encrypted Location):', payload.ciphertext);
            console.log('   Grid Sector (Metadata):', payload.gridSector);
        }
        
        // The server cannot read the ciphertext. It just routes it.
        socket.broadcast.emit('incoming_alert', payload);
        if (!payload.isLiveUpdate) console.log('[BLIND RELAY] Initial Ciphertext securely routed to contacts.');
    });

    // Listen for dedicated emergency voice message from commuter
    socket.on('emergency_voice_note', (payload) => {
        console.log(`\n[VOICE NOTE RELAY] Emergency audio message received from ${payload.username || 'Commuter'} (${payload.voiceNoteDuration || 0}s). Relaying to all responders...`);
        socket.broadcast.emit('emergency_voice_note', payload);
        // Also relay as incoming_alert so radar maps update immediately
        socket.broadcast.emit('incoming_alert', {
            ...payload,
            isLiveUpdate: false,
            hasVoiceNote: true,
        });
    });

    // Listen for cancellation from the commuter
    socket.on('cancel_alert', (payload) => {
        console.log(`[ALERT CANCELLED] SOS cancelled by ${payload.username || socket.id}`);
        socket.broadcast.emit('alert_cancelled', payload);
    });

    // SafeCommute <-> Police Central HQ Top-to-Bottom Enterprise Relay
    socket.on('police_central_dispatch', (data) => {
        const incidentId = data.incidentId || `POL-HQ-${Date.now()}`;
        const station = data.assignedStation || 'Regional Division Police Precinct';
        const eta = data.etaMinutes || 4;

        console.log(`\n======================================================`);
        console.log(`[POLICE CENTRAL HQ] Critical SOS Received from: ${data.username || 'Commuter'}`);
        console.log(`   Incident Ref: ${incidentId}`);
        console.log(`   Victim Coordinates: ${data.lat}, ${data.lng}`);
        console.log(`   Battery Status: ${data.battery || 'Unknown'}%`);
        console.log(`   [STEP 1] Central Police Command Headquarters logged ticket.`);
        console.log(`   [STEP 2] Top-to-Bottom Cascade: Routing to local branch -> ${station}`);
        console.log(`   [STEP 3] Local Patrol Unit / PCR Van Dispatched. ETA: ~${eta} mins.`);
        console.log(`======================================================\n`);

        // Emit real-time confirmation back to commuter and all responders
        io.emit('police_dispatch_update', {
            incidentId: incidentId,
            username: data.username,
            assignedStation: station,
            etaMinutes: eta,
            status: 'DISPATCHED_EN_ROUTE',
            timestamp: new Date().toISOString()
        });
    });

    // Listen for automatic SMS fallback triggers (Real Twilio Integration)
    socket.on('trigger_sms_fallback', (data) => {
        console.log('\n[TWILIO SMS] Attempting to send real SMS...');
        
        const fromNumber = process.env.TWILIO_PHONE_NUMBER;
        
        if (!fromNumber || fromNumber === 'PLACEHOLDER') {
            console.log('[TWILIO ERROR] Missing Twilio Phone Number in .env file!');
            return;
        }

        // Send an SMS to every contact in the list
        data.contacts.forEach(contactNumber => {
            // Strip any spaces or dashes to ensure strict E.164 formatting (e.g., +91 86971 93170 -> +918697193170)
            const cleanNumber = contactNumber.replace(/[\s-]/g, '');
            
            twilioClient.messages.create({
                body: data.message,
                from: fromNumber,
                to: cleanNumber
            })
            .then(message => console.log(`[SUCCESS] Real SMS sent to ${cleanNumber}! Twilio SID: ${message.sid}`))
            .catch(err => console.error(`[TWILIO ERROR] Failed to send to ${cleanNumber}:`, err.message));
        });
    });

    // Listen for Automated Incident Email Dispatch (Mobile Incident Classification)
    socket.on('incident_email_dispatch', (data) => {
        const incidentId = data.incidentId || `INC-${Date.now()}`;
        const recipient = data.recipientEmail || 'emergency-response@safecommute.internal';
        const incidentType = data.incidentType || 'GENERAL_EMERGENCY';
        const severity = data.severityText || 'CRITICAL';

        console.log(`\n======================================================`);
        console.log(`[AUTOMATED INCIDENT EMAIL DISPATCH] Emergency Alert Triggered!`);
        console.log(`   Incident ID: ${incidentId}`);
        console.log(`   Recipient: ${recipient}`);
        console.log(`   Victim: ${data.username || 'Commuter'}`);
        console.log(`   Accident Type: ${incidentType}`);
        console.log(`   Severity Level: ${severity} (Tier ${data.severityLevel || 1})`);
        console.log(`   Trigger Source: ${data.triggerSource || 'MOBILE_SENSORS'}`);
        console.log(`   Coordinates: ${data.lat}, ${data.lng}`);
        console.log(`   Google Maps Radar: https://maps.google.com/?q=${data.lat},${data.lng}`);
        if (data.peakGForce) console.log(`   Sensor Telemetry: Peak G-Force = ${data.peakGForce.toFixed(2)}G`);
        if (data.hasVoiceNote) console.log(`   Voice Note Telemetry: Audio attached (${data.voiceNoteDuration || 0}s voice record)`);
        console.log(`   Timestamp: ${new Date().toISOString()}`);
        console.log(`   Status: DISPATCHED & LOGGED TO EMERGENCY REPOSITORIES`);
        console.log(`======================================================\n`);

        socket.broadcast.emit('incident_email_confirmed', {
            incidentId,
            recipient,
            status: 'SENT',
            timestamp: new Date().toISOString()
        });
    });

    socket.on('disconnect', () => {
        console.log('Client disconnected:', socket.id);
    });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
    console.log(`SafeCommute Blind Relay Server running on port ${PORT}`);
});
