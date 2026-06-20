import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: "AIzaSyBXJ_RnfjUDi7qPDATWVnS5lSFw6jVRYgo",
  authDomain: "shopping-e284c.firebaseapp.com",
  databaseURL: "https://shopping-e284c-default-rtdb.firebaseio.com",
  projectId: "shopping-e284c",
  storageBucket: "shopping-e284c.appspot.com",
  messagingSenderId: "248274428739",
  appId: "1:248274428739:web:fc30dd9eb1ef83f610c5f6",
  measurementId: "G-ZXZCK9BW7T"
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: "AIzaSyBXJ_RnfjUDi7qPDATWVnS5lSFw6jVRYgo",
    appId: "1:248274428739:web:fc30dd9eb1ef83f610c5f6",
    messagingSenderId: "248274428739",
    projectId: "shopping-e284c",
    databaseURL: "https://shopping-e284c-default-rtdb.firebaseio.com",
    storageBucket: "shopping-e284c.appspot.com",
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: "placeholder-api-key",
    appId: "1:1234567890:ios:1234567890abcdef",
    messagingSenderId: "1234567890",
    projectId: "placeholder-project-id",
    databaseURL: "https://placeholder-db-url.firebaseio.com",
    storageBucket: "placeholder-storage-bucket.appspot.com",
    androidClientId: "placeholder-android-client-id",
    iosClientId: "placeholder-ios-client-id",
    iosBundleId: "com.buspulse.buspulseDriver",
  );
}
