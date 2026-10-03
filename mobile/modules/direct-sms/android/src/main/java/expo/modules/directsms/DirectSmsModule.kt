package expo.modules.directsms

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
