import { requireNativeModule } from 'expo-modules-core';
const DirectSms = requireNativeModule('DirectSms');

export function sendSms(phoneNumber: string, message: string): string {
  return DirectSms.sendSms(phoneNumber, message);
}
