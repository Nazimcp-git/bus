import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:buspulse_driver/firebase_options.dart';

class LocationService {
  static const String notificationChannelId = 'buspulse_location_channel';
  static const int notificationId = 888;

  // Initialize background service configurations
  static Future<void> initializeService() async {
    final service = FlutterBackgroundService();

    // Setup local notification channel for foreground service
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      notificationChannelId,
      'BusPulse Live Stream',
      description: 'Used for school bus GPS live tracking.',
      importance: Importance.low,
    );

    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
        FlutterLocalNotificationsPlugin();

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false, // Explicitly start/stop from the UI toggle
        isForegroundMode: true,
        notificationChannelId: notificationChannelId,
        initialNotificationTitle: 'BusPulse Active',
        initialNotificationContent: 'Initializing GPS location stream...',
        foregroundServiceNotificationId: notificationId,
        foregroundServiceTypes: [AndroidForegroundType.location],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onStart,
      ),
    );
  }

  // Request permissions flow
  static Future<bool> requestPermissions() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      await Geolocator.openLocationSettings();
      return false;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      await Geolocator.openAppSettings();
      return false;
    }

    // Request Notification permission for Android 13+
    final notificationsPlugin = FlutterLocalNotificationsPlugin();
    await notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    return true;
  }
}

// Background Isolate Entry Point
@pragma('vm:entry-point')
Future<bool> onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();

  SharedPreferences prefs = await SharedPreferences.getInstance();
  final String schoolId = prefs.getString('schoolId') ?? '';
  final String busId = prefs.getString('busId') ?? '';

  // Return if configuration is missing
  if (schoolId.isEmpty || busId.isEmpty) {
    service.invoke('addLog', {
      'message': 'Error: Missing schoolId/busId in background config.',
      'severity': 'error'
    });
    service.stopSelf();
    return false;
  }

  // Initialize Firebase in this isolate
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    // Graceful error if credentials are placeholders
    service.invoke('addLog', {
      'message': 'Firebase initialization failed. Check your credentials.',
      'severity': 'error'
    });
    // Continue running so UI isn't broken, but log the error
  }

  FirebaseDatabase? database;
  DatabaseReference? busRef;
  OnDisconnect? disconnectHook;

  try {
    database = FirebaseDatabase.instance;
    busRef = database.ref('schools/$schoolId/buses/$busId');
    disconnectHook = busRef.onDisconnect();
    
    // Register standard disconnect hook in background without blocking initialization
    disconnectHook.update({
      'status': 'idle',
      'speed': 0,
      'lastUpdated': ServerValue.timestamp,
    }).catchError((err) {
      service.invoke('addLog', {
        'message': 'onDisconnect setup warning: ${err.toString()}',
        'severity': 'warning'
      });
    });
  } catch (e) {
    service.invoke('addLog', {
      'message': 'Firebase Database reference error: ${e.toString()}',
      'severity': 'error'
    });
  }

  // Variables for calculation
  Position? lastWrittenPosition;
  DateTime? lastWriteTime;
  bool isConnected = true;
  StreamSubscription<Position>? positionSubscription;
  StreamSubscription<List<ConnectivityResult>>? connectivitySubscription;

  // Logging utility inside background isolate
  void logEvent(String message, String severity) {
    service.invoke('addLog', {
      'message': message,
      'severity': severity,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  // Push notifications controller updates
  final FlutterLocalNotificationsPlugin localNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  // Initialize local notifications plugin in background isolate context
  await localNotificationsPlugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('ic_bg_service_small'),
    ),
  );

  void updateNotification(String title, String content) {
    localNotificationsPlugin.show(
      id: LocationService.notificationId,
      title: title,
      body: content,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          LocationService.notificationChannelId,
          'BusPulse Live Stream',
          importance: Importance.low,
          ongoing: true,
          showWhen: false,
          icon: 'ic_bg_service_small',
        ),
      ),
    );
  }

  logEvent("System background service initialized.", "info");

  // 1. Listen to connectivity state changes
  connectivitySubscription = Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> results) {
    final bool currentConnected = results.isNotEmpty && results.first != ConnectivityResult.none;
    if (currentConnected != isConnected) {
      isConnected = currentConnected;
      service.invoke('updateStatus', {'isConnected': isConnected});
      if (!isConnected) {
        logEvent("System connection dropped.", "error");
        updateNotification("BusPulse Offline", "Connection lost. Reconnecting...");
      } else {
        logEvent("System connection restored.", "success");
        updateNotification("BusPulse Streaming Active", "Streaming live location to parents...");
      }
    }
  });

  // 2. Listen to position changes
  LocationSettings locationSettings;
  if (defaultTargetPlatform == TargetPlatform.android) {
    locationSettings = AndroidSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0, // Update immediately on movement
      intervalDuration: const Duration(seconds: 1),
      forceLocationManager: true, // Force standard LocationManager to use hardware GPS directly for maximum accuracy
    );
  } else {
    locationSettings = const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );
  }

  // Fetch initial location immediately to display stats and signal instantly in the app
  Geolocator.getCurrentPosition(locationSettings: locationSettings).then((Position position) {
    if (position.accuracy > 100.0) return;
    final int speedKmh = (position.speed * 3.6).round();
    final now = DateTime.now();
    
    // Update UI immediately
    service.invoke('updateLocation', {
      'lat': position.latitude,
      'lng': position.longitude,
      'speed': speedKmh,
      'heading': position.heading.round(),
      'accuracy': position.accuracy,
      'isEstimatedHeading': false,
      'timestamp': now.toIso8601String(),
    });

    // Write initial state to Firebase Database
    if (isConnected && busRef != null) {
      busRef.update({
        'lat': position.latitude,
        'lng': position.longitude,
        'speed': speedKmh,
        'heading': position.heading.round(),
        'status': 'active',
        'lastUpdated': ServerValue.timestamp,
      }).catchError((e) {
        logEvent("Initial database write failed: ${e.toString()}", "error");
      });
      lastWrittenPosition = position;
      lastWriteTime = now;
      logEvent("Initial database update pushed.", "success");
    }
  }).catchError((e) {
    logEvent("Could not acquire initial position: ${e.toString()}", "warning");
  });

  positionSubscription = Geolocator.getPositionStream(
    locationSettings: locationSettings,
  ).listen((Position position) async {
    // Verify accuracy filter: Discard points with accuracy > 100 meters (prevents wild jumps while capturing indoor/weak signals)
    if (position.accuracy > 100.0) {
      logEvent(
        "Low accuracy GPS point discarded (${position.accuracy.toStringAsFixed(1)}m).",
        "warning",
      );
      return;
    }

    final now = DateTime.now();
    final int speedKmh = (position.speed * 3.6).round();

    // Calculate heading dynamically if native heading is unavailable (null, 0.0) and bus is moving
    double finalHeading = position.heading;
    bool isHeadingEstimated = false;

    if ((finalHeading == 0.0 || finalHeading.isNaN) && lastWrittenPosition != null) {
      final double latDiff = position.latitude - lastWrittenPosition!.latitude;
      final double lngDiff = position.longitude - lastWrittenPosition!.longitude;
      
      // Check if distance change is greater than 0.00001 (~1 meter) to avoid jitter calculation
      if (latDiff.abs() > 0.00001 || lngDiff.abs() > 0.00001) {
        final double angle = atan2(lngDiff, latDiff) * (180 / pi);
        finalHeading = (angle + 360) % 360;
        isHeadingEstimated = true;
      }
    }

    // ALWAYS invoke update back to UI thread immediately for instant stats and signal lock
    service.invoke('updateLocation', {
      'lat': position.latitude,
      'lng': position.longitude,
      'speed': speedKmh,
      'heading': finalHeading.round(),
      'accuracy': position.accuracy,
      'isEstimatedHeading': isHeadingEstimated,
      'timestamp': now.toIso8601String(),
    });

    // NOW throttle and filter specifically for Firebase database writes
    // Throttle writes: At most once every 2 seconds
    if (lastWriteTime != null && now.difference(lastWriteTime!).inMilliseconds < 2000) {
      return;
    }

    // Check if coordinates or speed has changed since last write
    bool hasMoved = true;
    if (lastWrittenPosition != null) {
      final double latDiff = (position.latitude - lastWrittenPosition!.latitude).abs();
      final double lngDiff = (position.longitude - lastWrittenPosition!.longitude).abs();
      // If coordinates haven't changed by 0.000001 degrees, and speed is still the same (e.g. still stationary), skip write
      if (latDiff < 0.000001 && lngDiff < 0.000001 && (position.speed == lastWrittenPosition!.speed)) {
        hasMoved = false;
      }
    }

    // Write to Firebase if online and coordinates changed
    if (isConnected && hasMoved) {
      try {
        if (busRef != null) {
          // MUST use update() to prevent wiping admin configuration metadata
          // Run update asynchronously without blocking the position isolate loop
          busRef.update({
            'lat': position.latitude,
            'lng': position.longitude,
            'speed': speedKmh,
            'heading': finalHeading.round(),
            'status': 'active',
            'lastUpdated': ServerValue.timestamp,
          }).catchError((e) {
            logEvent("Database update failed: ${e.toString()}", "error");
          });
          lastWrittenPosition = position;
          lastWriteTime = now;
        }
      } catch (e) {
        logEvent("Database update failed: ${e.toString()}", "error");
      }
    }
  }, onError: (e) {
    logEvent("GPS Sensor Error: ${e.toString()}", "error");
  });

  // 3. Listen to stop service commands from the UI
  service.on('stopService').listen((event) async {
    logEvent("Tracking stream stopped by driver.", "info");

    // Clean Session Exit
    try {
      if (busRef != null) {
        // Cancel the onDisconnect hook first
        if (disconnectHook != null) {
          await disconnectHook.cancel();
        }
        
        // Write final idle state
        await busRef.update({
          'status': 'idle',
          'speed': 0,
          'lastUpdated': ServerValue.timestamp,
        });
      }
    } catch (e) {
      // Ignored during shutdown
    }

    // Cancel streams
    await positionSubscription?.cancel();
    await connectivitySubscription?.cancel();
    
    service.stopSelf();
  });

  // Initial persistent notification
  updateNotification(
    "BusPulse Streaming Active",
    "Bus $busId is streaming live location to parents...",
  );

  return true;
}
