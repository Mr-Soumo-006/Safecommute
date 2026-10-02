const sodium = require('libsodium-wrappers');

async function runDemo() {
    // Wait for libsodium to initialize
    await sodium.ready;

    console.log("--- SAFECOMMUTE STAGE 0: E2EE DEMO ---\n");
    
    // 1. Key Generation (Happens on the users' phones)
    console.log("1. Generating Keys (On-Device)...");
    const victimKeys = sodium.crypto_box_keypair();
    const familyKeys = sodium.crypto_box_keypair();
    console.log("   -> Victim Public/Private Keypair generated.");
    console.log("   -> Family Public/Private Keypair generated.");

    // 2. The GPS Location (Plaintext on Victim's phone)
    const gpsData = JSON.stringify({ lat: 22.5726, lng: 88.3639, timestamp: Date.now() });
    console.log("\n2. Victim captures GPS Location (Plaintext on device):");
    console.log("   Data:", gpsData);

    // 3. Encrypting the payload for the Family member
    // The victim encrypts the message using THEIR private key and the FAMILY'S public key
    const nonce = sodium.randombytes_buf(sodium.crypto_box_NONCEBYTES);
    const ciphertext = sodium.crypto_box_easy(gpsData, nonce, familyKeys.publicKey, victimKeys.privateKey);
    
    console.log("\n3. Victim encrypts data and sends to Node.js Backend:");
    console.log("   Nonce (Hex):", sodium.to_hex(nonce));
    console.log("   Ciphertext (Hex):", sodium.to_hex(ciphertext).substring(0, 50) + "...");

    // 4. Server processing (The Blind Relay)
    console.log("\n4. Node.js Backend receives payload...");
    console.log("   [SERVER LOG]: I have received a payload, but I only see ciphertext. I cannot read the GPS coordinates.");
    console.log("   [SERVER LOG]: Routing ciphertext to Family App...");

    // 5. Family App decrypts the payload
    // The family app decrypts using THEIR private key and the VICTIM'S public key
    try {
        const decryptedMsg = sodium.crypto_box_open_easy(ciphertext, nonce, victimKeys.publicKey, familyKeys.privateKey);
        console.log("\n5. Family App receives and decrypts payload:");
        console.log("   Success! Decrypted GPS:", sodium.to_string(decryptedMsg));
    } catch (error) {
        console.error("   Decryption failed!");
    }
}

runDemo();
