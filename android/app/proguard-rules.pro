# Flutter WebRTC & Native JNI
-keep class com.cloudwebrtc.webrtc.** { *; }
-keep class org.webrtc.** { *; }
-keep class org.jni_zero.** { *; }
-dontwarn org.jni_zero.JniZeroJni

# Twilio AudioSwitch (used by flutter_webrtc on Android)
-keep class com.twilio.audioswitch.** { *; }

# Ligament native Android call manager, service and broadcast receiver
-keep class com.ligament.twofa.authenticator.** { *; }
