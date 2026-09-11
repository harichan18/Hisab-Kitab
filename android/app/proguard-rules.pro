# ProGuard / R8 Rules for Hisab Kitab

# 1. Google ML Kit Text Recognition:
# Suppress missing optional language packages (Chinese, Japanese, Korean)
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# Keep ML Kit Text Recognition classes
-keep class com.google.mlkit.vision.** { *; }
-keep interface com.google.mlkit.vision.** { *; }
-keep class com.google_mlkit_text_recognition.** { *; }

# 2. Firebase & Google Play Services
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod

-dontwarn com.google.firebase.**
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }

# 3. Flutter Image Compression & Native Plugins
-keep class com.flutterimagecompress.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class com.tekartik.sqflite.** { *; }

# 4. In-app update / Dio / HTTP
-dontwarn okhttp3.**
-dontwarn okio.**
