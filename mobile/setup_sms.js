const fs = require('fs');

// 1. Update app.json permissions
const appJsonPath = './app.json';
const appJson = JSON.parse(fs.readFileSync(appJsonPath, 'utf8'));
appJson.expo.android = appJson.expo.android || {};
appJson.expo.android.permissions = appJson.expo.android.permissions || [];
['SEND_SMS', 'ACCESS_FINE_LOCATION', 'ACCESS_COARSE_LOCATION'].forEach(p => {
  if (!appJson.expo.android.permissions.includes(p)) appJson.expo.android.permissions.push(p);
});
fs.writeFileSync(appJsonPath, JSON.stringify(appJson, null, 2));

// 2. Write Kotlin Code
const ktPath = './modules/direct-sms/android/src/main/java/expo/modules/directsms/DirectSmsModule.kt';
const ktCode = `package expo.modules.directsms

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import android.telephony.SmsManager

class DirectSmsModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("DirectSms")

    Function("sendSms") { phoneNumber: String, message: String ->
      try {
        val smsManager = SmsManager.getDefault()
        smsManager.sendTextMessage(phoneNumber, null, message, null, null)
        "success"
      } catch (e: Exception) {
        "error: " + e.message
      }
    }
  }
}
`;
fs.writeFileSync(ktPath, ktCode);

// 3. Write TypeScript Wrapper
const tsPath = './modules/direct-sms/index.ts';
const tsCode = `import { requireNativeModule } from 'expo-modules-core';
const DirectSms = requireNativeModule('DirectSms');

export function sendSms(phoneNumber: string, message: string): string {
  return DirectSms.sendSms(phoneNumber, message);
}
`;
fs.writeFileSync(tsPath, tsCode);

console.log("Native setup complete!");
