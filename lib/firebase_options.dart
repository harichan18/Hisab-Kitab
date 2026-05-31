// Generated from android/app/google-services.json.
// Re-run FlutterFire configuration if you add iOS, web, macOS, Windows, or Linux Firebase apps.

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError(
        'Firebase options have not been configured for web.',
      );
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        throw UnsupportedError(
          'Firebase options have not been configured for this platform.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAM7ED4Syf8SqpV9jvTZwmreBd-KhiwHD0',
    appId: '1:614565157950:android:1e8e13619b798e182ac56f',
    messagingSenderId: '614565157950',
    projectId: 'hisab-kitabb',
    storageBucket: 'hisab-kitabb.firebasestorage.app',
  );
}
