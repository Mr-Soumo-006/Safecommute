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
            console.log(`[LIVE TRACKING] Secure location update received from ${socket.id} - Streaming to contacts...`);
        } else {
            console.log('\n[BLIND RELAY] Received SOS payload:');
            console.log('   From Victim ID:', socket.id);
            console.log('   Target Contact ID:', payload.targetContactId);
            console.log('   Ciphertext (Encrypted Location):', payload.ciphertext);
            console.log('   Grid Sector (Metadata):', payload.gridSector);
        }
        
        // The server cannot read the ciphertext. It just routes it.
        socket.broadcast.emit('incoming_alert', payload);
        if (!payload.isLiveUpdate) console.log('[BLIND RELAY] Initial Ciphertext securely routed to contacts.');
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

    socket.on('disconnect', () => {
        console.log('Client disconnected:', socket.id);
    });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
    console.log(`SafeCommute Blind Relay Server running on port ${PORT}`);
});
