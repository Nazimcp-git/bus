import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cache/flutter_map_cache.dart';
import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';
import 'package:dio_cache_interceptor_file_store/dio_cache_interceptor_file_store.dart';
import 'package:path_provider/path_provider.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:buspulse_driver/theme/app_theme.dart';
import 'package:buspulse_driver/services/auth_service.dart';
import 'package:buspulse_driver/models/parent_models.dart';
import 'package:buspulse_driver/widgets/app_splash_screen.dart';

class ParentDashboardPage extends StatefulWidget {
  const ParentDashboardPage({super.key});

  @override
  State<ParentDashboardPage> createState() => _ParentDashboardPageState();
}

class _ParentDashboardPageState extends State<ParentDashboardPage> {
  final FirebaseDatabase _db = FirebaseDatabase.instance;
  final MapController _mapController = MapController();
  final FlutterLocalNotificationsPlugin _localNotificationsPlugin =
      FlutterLocalNotificationsPlugin();
  CacheStore? _cacheStore;

  // Subscriptions & State
  StreamSubscription? _busSubscription;
  StreamSubscription? _alertsSubscription;
  StreamSubscription? _connectedSubscription;

  bool _isDbLoading = true;
  bool _isConnected = false;
  String _busStatus = 'idle'; // 'active', 'stopped', 'idle'
  DateTime? _lastUpdated;
  double _currentSpeed = 0.0;
  double _heading = 0.0;

  // Locations
  LatLng? _busLocation;
  LatLng? _homeLocation;
  LatLng? _schoolLocation;

  // Account details
  String _schoolId = '';
  String _busId = '';
  String _routeName = 'Loading Route...';
  String _schoolName = 'Loading School...';
  String _parentName = 'Parent';
  String _userId = '';

  // Proximity Alert Settings
  bool _alert2km = true;
  bool _alert500m = true;
  bool _alert100m = true;

  // Local Fired alert keys to prevent duplicate fires
  final Set<String> _firedAlerts = {};

  // Alert Event Logs list
  final List<JourneyAlert> _alertLogs = [];

  // Speed History for rolling avg
  final List<double> _speedHistory = [];
  static const int _speedWindowSize = 5;

  // Journey timeline state & metrics
  JourneyState _journeyState = JourneyState.idle;
  double _calculatedDistanceKm = 0.0;
  int? _calculatedEtaMin;
  List<LatLng>? _routeCoordinates;
  double? _totalSchoolToHomeDistanceKm;
  int _progressPercent = 0;

  // Trail of bus path (breadcrumb)
  final List<LatLng> _trailPoints = [];
  static const int _maxTrailPoints = 20;

  // Map settings state
  bool _isSelectingStop = false;
  LatLng? _temporarySelectedStop;

  // Weather state variables
  double? _weatherTempC;
  String? _weatherLabel;
  String? _weatherIcon;
  double? _weatherWindSpeed;
  DateTime? _lastWeatherFetch;
  LatLng? _lastWeatherLocation;

  // Timer for time tickers
  Timer? _tickerTimer;

  // Stop Debounce Timer
  Timer? _stoppedTimer;
  bool _isStopped = false;
  DateTime? _lastSpeedWarningTime;

  @override
  void initState() {
    super.initState();
    _initLocalNotifications();
    _initMapCache();
    _loadPersistedSettings();
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _connectedSubscription?.cancel();
    _busSubscription?.cancel();
    _alertsSubscription?.cancel();
    _tickerTimer?.cancel();
    _stoppedTimer?.cancel();
    super.dispose();
  }

  // ----------------------------------------------------
  // Init, DB and Listeners
  // ----------------------------------------------------

  Future<void> _initLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const initSettings = InitializationSettings(android: androidSettings);
    await _localNotificationsPlugin.initialize(settings: initSettings);
  }

  Future<void> _initMapCache() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final cachePath = '${dir.path}${Platform.pathSeparator}MapTiles';
      setState(() {
        _cacheStore = FileCacheStore(cachePath);
      });
    } catch (e) {
      debugPrint("Failed to initialize map cache: $e");
    }
  }

  Future<void> _showLocalNotification(String title, String body, int id) async {
    const androidDetails = AndroidNotificationDetails(
      'buspulse_proximity_channel',
      'Proximity Alerts',
      channelDescription: 'Alerts triggered by bus proximity to home stop',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
    );
    const details = NotificationDetails(android: androidDetails);
    await _localNotificationsPlugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }

  Future<void> _loadPersistedSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final authProvider = Provider.of<AuthProvider>(context, listen: false);

    _userId = prefs.getString('uid') ?? authProvider.currentUser?.uid ?? '';
    _schoolId = prefs.getString('schoolId') ?? authProvider.schoolId ?? '';
    _busId = prefs.getString('busId') ?? authProvider.busId ?? '';
    _routeName =
        prefs.getString('routeName') ??
        authProvider.routeName ??
        'No Route Assigned';
    _schoolName = authProvider.schoolName ?? 'BusPulse School';

    // Retrieve notification settings locally
    _alert2km = prefs.getBool('alert_2km_enabled') ?? true;
    _alert500m = prefs.getBool('alert_500m_enabled') ?? true;
    _alert100m = prefs.getBool('alert_100m_enabled') ?? true;

    if (_userId.isNotEmpty) {
      // Fetch details from Firebase database
      final userSnap = await _db.ref('users/$_userId').get();
      if (userSnap.exists && userSnap.value != null) {
        final userData = Map<String, dynamic>.from(userSnap.value as Map);
        _parentName = userData['name']?.toString() ?? 'Parent';
        if (userData['homeStop'] != null) {
          final homeStopData = Map<String, dynamic>.from(
            userData['homeStop'] as Map,
          );
          final lat = (homeStopData['lat'] as num).toDouble();
          final lng = (homeStopData['lng'] as num).toDouble();
          _homeLocation = LatLng(lat, lng);
        }
        if (userData['alertSettings'] != null) {
          final alertData = Map<String, dynamic>.from(
            userData['alertSettings'] as Map,
          );
          _alert2km = alertData['alert2km'] ?? true;
          _alert500m = alertData['alert500m'] ?? true;
          _alert100m = alertData['alert100m'] ?? true;
        }
      }
    }

    _startFirebaseListeners();
  }

  void _startFirebaseListeners() {
    if (_schoolId.isEmpty || _busId.isEmpty) {
      setState(() {
        _isDbLoading = false;
      });
      return;
    }

    // Monitor Firebase Connection Dot State
    _connectedSubscription = _db.ref('.info/connected').onValue.listen((event) {
      final val = event.snapshot.value == true;
      if (mounted) {
        setState(() {
          _isConnected = val;
        });
      }
    });

    // Monitor Bus Updates
    _busSubscription = _db
        .ref('schools/$_schoolId/buses/$_busId')
        .onValue
        .listen((event) async {
          final snap = event.snapshot;
          if (!snap.exists || snap.value == null) {
            if (mounted) {
              setState(() {
                _busStatus = 'idle';
                _isDbLoading = false;
              });
            }
            return;
          }

          final data = Map<String, dynamic>.from(snap.value as Map);
          await _handleBusUpdate(data);
        });

    // Monitor Admin Alerts / Broadcasts
    _alertsSubscription = _db
        .ref('schools/$_schoolId/alerts')
        .orderByChild('timestamp')
        .limitToLast(5)
        .onChildAdded
        .listen((event) {
          final snap = event.snapshot;
          if (!snap.exists || snap.value == null) return;
          final data = Map<String, dynamic>.from(snap.value as Map);

          final id = snap.key ?? '';
          final alert = JourneyAlert.fromMap(id, data);

          // Ignore alerts older than 10 minutes from loaded history
          final ageMs =
              DateTime.now().millisecondsSinceEpoch -
              alert.timestamp.millisecondsSinceEpoch;
          if (ageMs > 10 * 60 * 1000) return;

          // Filter target
          final target = data['targetBusId']?.toString() ?? 'all';
          if (target == 'all' || target == _busId) {
            _logAlertEvent(alert.message, alert.type, time: alert.timestamp);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('📣 Broadcast: ${alert.message}'),
                backgroundColor: alert.indicatorColor,
                duration: const Duration(seconds: 6),
              ),
            );
          }
        });
  }

  // ----------------------------------------------------
  // Update Mechanics
  // ----------------------------------------------------

  Future<void> _handleBusUpdate(Map<String, dynamic> data) async {
    _busStatus = data['status']?.toString() ?? 'idle';
    if (data['routeName'] != null) {
      _routeName = data['routeName'].toString();
    }

    final double? lat = (data['lat'] as num?)?.toDouble();
    final double? lng = (data['lng'] as num?)?.toDouble();
    final double speed = (data['speed'] as num?)?.toDouble() ?? 0.0;
    _heading = (data['heading'] as num?)?.toDouble() ?? 0.0;
    _currentSpeed = speed;

    final rawLastUpdated = data['lastUpdated'] as int?;
    _lastUpdated = rawLastUpdated != null
        ? DateTime.fromMillisecondsSinceEpoch(rawLastUpdated)
        : DateTime.now();

    if (lat != null && lng != null) {
      final newLoc = LatLng(lat, lng);
      _busLocation = newLoc;

      // Add to breadcrumb path layer
      _addTrailPoint(newLoc);

      // Retrieve school coordinate if present
      if (data['schoolStop'] != null) {
        final schoolData = Map<String, dynamic>.from(data['schoolStop'] as Map);
        final sLat = (schoolData['lat'] as num).toDouble();
        final sLng = (schoolData['lng'] as num).toDouble();
        _schoolLocation = LatLng(sLat, sLng);
      }

      // Check speed history for avg
      _addSpeedReading(speed);

      // Blended calculations if Home Stop is configured
      if (_homeLocation != null) {
        final double distanceToHomeM = _haversineDistanceM(
          newLoc,
          _homeLocation!,
        );
        final double distToHomeKm = distanceToHomeM / 1000;

        final avgSpeed = _getRollingAvgSpeed();
        final effectiveSpeed = avgSpeed > 2.0
            ? avgSpeed
            : (speed > 2.0 ? speed : 20.0);

        final routeInfo = await _fetchBlendedETA(
          newLoc,
          _homeLocation!,
          effectiveSpeed,
        );

        _calculatedDistanceKm = routeInfo.distanceKm;
        _calculatedEtaMin = routeInfo.etaMinutes;
        _routeCoordinates = routeInfo.coordinates;

        // Perform OSRM baseline estimation once
        if (_totalSchoolToHomeDistanceKm == null && _schoolLocation != null) {
          _totalSchoolToHomeDistanceKm = await _fetchOSRMBaselineDistance(
            _schoolLocation!,
            _homeLocation!,
          );
        }

        // timeline completion percentage
        if (_totalSchoolToHomeDistanceKm != null &&
            _totalSchoolToHomeDistanceKm! > 0) {
          _progressPercent =
              (math.max(
                        0.0,
                        math.min(
                          1.0,
                          1.0 -
                              (_calculatedDistanceKm /
                                  _totalSchoolToHomeDistanceKm!),
                        ),
                      ) *
                      100)
                  .round();
        }

        // Determine geofence state progression
        _journeyState = _calculateJourneyState(
          newLoc,
          _schoolLocation,
          _homeLocation!,
          distanceToHomeM,
        );

        // Check proximity threshold updates
        _checkProximityAlerts(distanceToHomeM);

        // Countdown alert warnings
        _checkOverspeeding(speed);
      }

      // Fetch Weather info (max once per 5 minutes or if distance changed significantly)
      _fetchWeatherInfo(newLoc);

      // Debounced stop log tracking
      _checkStopLogs(speed);
    }

    if (mounted) {
      setState(() {
        _isDbLoading = false;
      });
    }
  }

  // ----------------------------------------------------
  // Math & API Helpers
  // ----------------------------------------------------

  double _haversineDistanceM(LatLng p1, LatLng p2) {
    const double R = 6371000.0; // Earth radius in meters
    final double dLat = _degToRad(p2.latitude - p1.latitude);
    final double dLng = _degToRad(p2.longitude - p1.longitude);
    final double a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(p1.latitude)) *
            math.cos(_degToRad(p2.latitude)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final double c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return R * c;
  }

  double _degToRad(double deg) => deg * (math.pi / 180.0);

  void _addSpeedReading(double val) {
    _speedHistory.add(val);
    if (_speedHistory.length > _speedWindowSize) {
      _speedHistory.removeAt(0);
    }
  }

  double _getRollingAvgSpeed() {
    if (_speedHistory.isEmpty) return 0.0;
    return _speedHistory.reduce((a, b) => a + b) / _speedHistory.length;
  }

  void _addTrailPoint(LatLng point) {
    _trailPoints.add(point);
    if (_trailPoints.length > _maxTrailPoints) {
      _trailPoints.removeAt(0);
    }
  }

  // Blend OSRM geometry path details
  Future<_RouteBlendedInfo> _fetchBlendedETA(
    LatLng bus,
    LatLng home,
    double avgSpeed,
  ) async {
    try {
      final url = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/${bus.longitude},${bus.latitude};${home.longitude},${home.latitude}?overview=full&geometries=geojson',
      );
      final res = await http.get(url).timeout(const Duration(seconds: 5));

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data['code'] == 'Ok' &&
            data['routes'] != null &&
            (data['routes'] as List).isNotEmpty) {
          final route = data['routes'][0];
          final double distanceM = (route['distance'] as num).toDouble();
          final double durationSec = (route['duration'] as num).toDouble();

          final double roadKm = distanceM / 1000.0;
          final double osrmEtaMin = durationSec / 60.0;

          final double speedEtaMin = (roadKm / effectiveSpeed(avgSpeed)) * 60.0;

          // Blending Weight calculation based on average velocity
          final double clampedSpeed = math.max(0.0, math.min(avgSpeed, 40.0));
          final double weight = 0.5 - (clampedSpeed / 40.0) * 0.4;

          final int blendedEta =
              (weight * speedEtaMin + (1 - weight) * osrmEtaMin).round();

          // Decode Polyline Points
          List<LatLng> coords = [];
          if (route['geometry'] != null &&
              route['geometry']['coordinates'] != null) {
            final list = route['geometry']['coordinates'] as List;
            for (var pt in list) {
              coords.add(
                LatLng((pt[1] as num).toDouble(), (pt[0] as num).toDouble()),
              );
            }
          }

          return _RouteBlendedInfo(
            distanceKm: roadKm,
            etaMinutes: blendedEta,
            coordinates: coords,
          );
        }
      }
    } catch (e) {
      debugPrint("OSRM fetch error (falling back to Haversine): $e");
    }

    // Haversine fallback calculation
    final double straightKm = _haversineDistanceM(bus, home) / 1000.0;
    final double roadKm = straightKm * 1.3;
    final double durationMin = (roadKm / effectiveSpeed(avgSpeed)) * 60.0;

    return _RouteBlendedInfo(
      distanceKm: roadKm,
      etaMinutes: durationMin.round(),
      coordinates: null,
    );
  }

  double effectiveSpeed(double speed) => speed > 2.0 ? speed : 2.0;

  Future<double> _fetchOSRMBaselineDistance(LatLng school, LatLng home) async {
    try {
      final url = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/${school.longitude},${school.latitude};${home.longitude},${home.latitude}?overview=false',
      );
      final res = await http.get(url).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data['code'] == 'Ok' &&
            data['routes'] != null &&
            (data['routes'] as List).isNotEmpty) {
          final double distanceM = (data['routes'][0]['distance'] as num)
              .toDouble();
          return distanceM / 1000.0;
        }
      }
    } catch (e) {
      debugPrint("OSRM baseline fetch failed: $e");
    }
    // Haversine fallback
    return (_haversineDistanceM(school, home) / 1000.0) * 1.3;
  }

  JourneyState _calculateJourneyState(
    LatLng bus,
    LatLng? school,
    LatLng home,
    double distanceToHomeM,
  ) {
    if (_busStatus == 'idle') return JourneyState.idle;

    if (school != null) {
      final distToSchoolM = _haversineDistanceM(bus, school);
      if (distToSchoolM < 150) return JourneyState.atSchool;
    }

    if (distanceToHomeM < 50) return JourneyState.arrived;
    if (distanceToHomeM < 500) return JourneyState.approaching;

    return JourneyState.enRoute;
  }

  // ----------------------------------------------------
  // Alerts & Notifications
  // ----------------------------------------------------

  void _checkProximityAlerts(double distanceM) {
    final thresholds = [
      {
        'meters': 2000.0,
        'key': 'alert_2km',
        'msg': '🚌 Bus is 2 km away — heads up!',
      },
      {
        'meters': 500.0,
        'key': 'alert_500m',
        'msg': '🚌 Bus is 500 m away — head to your stop!',
      },
      {
        'meters': 100.0,
        'key': 'alert_100m',
        'msg': '🚨 Bus is arriving! Go now!',
      },
    ];

    for (var th in thresholds) {
      final double meters = th['meters'] as double;
      final String key = th['key'] as String;
      final String msg = th['msg'] as String;

      // Check if threshold is crossed
      if (distanceM <= meters && !_firedAlerts.contains(key)) {
        _firedAlerts.add(key);

        // Check if settings allow it
        bool isEnabled = true;
        if (key == 'alert_2km') isEnabled = _alert2km;
        if (key == 'alert_500m') isEnabled = _alert500m;
        if (key == 'alert_100m') isEnabled = _alert100m;

        if (isEnabled) {
          _logAlertEvent(msg, 'proximity');
          _showLocalNotification('BusPulse Tracker', msg, key.hashCode);
        }
      }
    }

    // Reset loop checks if bus has moved away (indicates new run session)
    if (distanceM > 2500) {
      _firedAlerts.clear();
    }
  }

  void _checkOverspeeding(double speed) {
    if (speed > 60.0) {
      final now = DateTime.now();
      if (_lastSpeedWarningTime == null ||
          now.difference(_lastSpeedWarningTime!) > const Duration(minutes: 2)) {
        _lastSpeedWarningTime = now;
        _logAlertEvent(
          '⚠️ High speed warning detected on school bus.',
          'warning',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⚠️ Speed Alert: Bus is overspeeding!'),
            backgroundColor: Color(0xFFEF4444),
          ),
        );
      }
    }
  }

  void _checkStopLogs(double speed) {
    if (speed < 2.0) {
      if (_stoppedTimer == null && !_isStopped) {
        _stoppedTimer = Timer(const Duration(seconds: 10), () {
          _isStopped = true;
          _logAlertEvent('🚌 Bus has stopped moving.', 'warning');
        });
      }
    } else {
      _stoppedTimer?.cancel();
      _stoppedTimer = null;
      if (_isStopped) {
        _isStopped = false;
        _logAlertEvent('🚌 Bus has resumed journey.', 'info');
      }
    }
  }

  void _logAlertEvent(String message, String type, {DateTime? time}) {
    final alert = JourneyAlert(
      id: UniqueKey().toString(),
      message: message,
      type: type,
      timestamp: time ?? DateTime.now(),
    );
    if (mounted) {
      setState(() {
        _alertLogs.insert(0, alert);
        if (_alertLogs.length > 30) _alertLogs.removeLast();
      });
    }
  }

  // ----------------------------------------------------
  // Weather
  // ----------------------------------------------------

  Future<void> _fetchWeatherInfo(LatLng loc) async {
    final now = DateTime.now();
    final tooSoon =
        _lastWeatherFetch != null &&
        now.difference(_lastWeatherFetch!) < const Duration(minutes: 5);
    final sameLocation =
        _lastWeatherLocation != null &&
        (loc.latitude - _lastWeatherLocation!.latitude).abs() < 0.01 &&
        (loc.longitude - _lastWeatherLocation!.longitude).abs() < 0.01;

    if (tooSoon && sameLocation) return;

    _lastWeatherFetch = now;
    _lastWeatherLocation = loc;

    try {
      final url = Uri.parse(
        'https://api.open-meteo.com/v1/forecast?latitude=${loc.latitude.toStringAsFixed(4)}&longitude=${loc.longitude.toStringAsFixed(4)}&current_weather=true&forecast_days=1',
      );
      final res = await http.get(url).timeout(const Duration(seconds: 5));

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final cw = data['current_weather'];
        final int code = (cw['weathercode'] as num).toInt();
        final double temp = (cw['temperature'] as num).toDouble();
        final double wind = (cw['windspeed'] as num).toDouble();

        final interpretation = _interpretWMOCode(code);
        if (mounted) {
          setState(() {
            _weatherTempC = temp;
            _weatherWindSpeed = wind;
            _weatherLabel = interpretation.label;
            _weatherIcon = interpretation.icon;
          });
        }
      }
    } catch (e) {
      debugPrint("Weather update error: $e");
    }
  }

  _WmoWeather _interpretWMOCode(int code) {
    switch (code) {
      case 0:
        return _WmoWeather('Clear sky', '☀️');
      case 1:
        return _WmoWeather('Mainly clear', '🌤️');
      case 2:
        return _WmoWeather('Partly cloudy', '⛅');
      case 3:
        return _WmoWeather('Overcast', '☁️');
      case 45:
      case 48:
        return _WmoWeather('Fog', '🌫️');
      case 51:
      case 53:
        return _WmoWeather('Light drizzle', '🌦️');
      case 55:
        return _WmoWeather('Dense drizzle', '🌧️');
      case 61:
        return _WmoWeather('Light rain', '🌧️');
      case 63:
      case 65:
        return _WmoWeather('Rain', '🌧️');
      case 71:
      case 73:
        return _WmoWeather('Snow', '🌨️');
      case 75:
        return _WmoWeather('Heavy snow', '❄️');
      case 80:
      case 81:
        return _WmoWeather('Rain showers', '🌧️');
      case 82:
        return _WmoWeather('Heavy showers', '⛈️');
      case 95:
      case 96:
      case 99:
        return _WmoWeather('Thunderstorm', '⛈️');
      default:
        return _WmoWeather('Unknown', '❓');
    }
  }

  // ----------------------------------------------------
  // Save drawer / issue triggers
  // ----------------------------------------------------

  Future<void> _saveDrawerSettings() async {
    final prefs = await SharedPreferences.getInstance();

    if (_temporarySelectedStop != null) {
      _homeLocation = _temporarySelectedStop;
      _totalSchoolToHomeDistanceKm = null; // force recalculate baseline
    }

    // Save locally
    await prefs.setBool('alert_2km_enabled', _alert2km);
    await prefs.setBool('alert_500m_enabled', _alert500m);
    await prefs.setBool('alert_100m_enabled', _alert100m);

    // Save to Firebase Database under users node
    try {
      final Map<String, dynamic> updates = {};
      if (_homeLocation != null) {
        updates['users/$_userId/homeStop'] = {
          'lat': _homeLocation!.latitude,
          'lng': _homeLocation!.longitude,
        };
      }
      updates['users/$_userId/alertSettings'] = {
        'alert2km': _alert2km,
        'alert500m': _alert500m,
        'alert100m': _alert100m,
      };

      await _db.ref().update(updates);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Settings successfully updated!'),
          backgroundColor: AppTheme.statusGreen,
        ),
      );

      setState(() {
        _isSelectingStop = false;
        _temporarySelectedStop = null;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to save settings: $e'),
          backgroundColor: AppTheme.statusRed,
        ),
      );
    }
  }

  Future<void> _submitIssueReport(String message) async {
    if (message.trim().isEmpty) return;

    try {
      final reportRef = _db.ref('schools/$_schoolId/reports').push();
      await reportRef.set({
        'id': reportRef.key,
        'userId': _userId,
        'parentName': _parentName,
        'busId': _busId,
        'message': message,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'resolved': false,
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Your issue report has been submitted to administrators.',
          ),
          backgroundColor: AppTheme.statusGreen,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Report submission failed: $e'),
          backgroundColor: AppTheme.statusRed,
        ),
      );
    }
  }

  void _showReportIssueDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppTheme.surfaceSlate,
          title: const Text('Report Route / Stop Issue'),
          content: TextField(
            controller: controller,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText:
                  'Explain the issue (e.g. Bus passed stop early, delay, etc.)',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('CANCEL'),
            ),
            ElevatedButton(
              onPressed: () {
                _submitIssueReport(controller.text);
                Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.statusRed,
              ),
              child: const Text('SUBMIT'),
            ),
          ],
        );
      },
    );
  }

  void _showSettingsDrawer() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surfaceSlate,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(context).viewInsets.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Alert & Stop Settings',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.close,
                          color: AppTheme.textSecondary,
                        ),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Set Your Home Stop Location',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Choose a stop location on map to set your child\'s pick-up point. ETA alerts will compute relative to it.',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      setState(() {
                        _isSelectingStop = true;
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Tap anywhere on the live map to choose your stop location.',
                          ),
                          duration: Duration(seconds: 4),
                        ),
                      );
                    },
                    icon: const Icon(Icons.pin_drop),
                    label: const Text('Choose Stop on Map'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _temporarySelectedStop != null
                        ? 'Selected Stop: ${_temporarySelectedStop!.latitude.toStringAsFixed(5)}, ${_temporarySelectedStop!.longitude.toStringAsFixed(5)}'
                        : (_homeLocation != null
                              ? 'Stop Location: ${_homeLocation!.latitude.toStringAsFixed(5)}, ${_homeLocation!.longitude.toStringAsFixed(5)}'
                              : 'Stop Location: Not set'),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const Divider(color: AppTheme.borderSlate, height: 24),
                  const Text(
                    'Proximity Notifications',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    title: const Text('Bus is 2 km away (Heads up)'),
                    value: _alert2km,
                    onChanged: (val) {
                      setModalState(() => _alert2km = val);
                      setState(() => _alert2km = val);
                    },
                  ),
                  SwitchListTile(
                    title: const Text('Bus is 500 m away (Prepare to leave)'),
                    value: _alert500m,
                    onChanged: (val) {
                      setModalState(() => _alert500m = val);
                      setState(() => _alert500m = val);
                    },
                  ),
                  SwitchListTile(
                    title: const Text('Bus is 100 m away (Arrived/Go now)'),
                    value: _alert100m,
                    onChanged: (val) {
                      setModalState(() => _alert100m = val);
                      setState(() => _alert100m = val);
                    },
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () {
                      _saveDrawerSettings();
                      Navigator.pop(context);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryCyan,
                    ),
                    child: const Text('SAVE SETTINGS'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _shareTrackingLink() {
    Clipboard.setData(
      ClipboardData(text: 'https://buspulse.school/track/parent?busId=$_busId'),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Tracking dashboard link copied to clipboard!'),
        backgroundColor: AppTheme.statusGreen,
      ),
    );
  }

  Future<void> _handleSignOut() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surfaceSlate,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.borderSlate),
        ),
        title: const Text(
          'Sign Out',
          style: TextStyle(color: AppTheme.textPrimary),
        ),
        content: const Text(
          'Are you sure you want to sign out?',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.statusRed,
              foregroundColor: AppTheme.textPrimary,
            ),
            child: const Text('SIGN OUT'),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      await authProvider.signOut();
    }
  }

  // ----------------------------------------------------
  // Render Helpers
  // ----------------------------------------------------

  String _formatTimeAgo(DateTime? dt) {
    if (dt == null) return '—';
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 10) return 'Just now';
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }

  String _formatDistance(double km) {
    if (km < 0.01) return '< 10 m';
    if (km < 1.0) return '${(km * 1000).round()} m';
    return '${km.toStringAsFixed(1)} km';
  }

  String _formatEta(int? minutes) {
    if (minutes == null) return '—';
    if (minutes < 1) return 'Arriving';
    if (minutes == 1) return '~1 min';
    return '~$minutes min';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundMidnight,
      body: _isDbLoading
          ? const AppSplashScreen(
              message: 'Connecting to live tracker...',
            )
          : Stack(
              children: [
                // 1. Full-screen Map View
                Positioned.fill(child: _buildMap()),

                // 2. Floating App Header
                Positioned(
                  top: MediaQuery.of(context).padding.top + 16,
                  left: 16,
                  right: 16,
                  child: _buildFloatingHeader(),
                ),

                // 3. Sliding Bottom Details Panel
                _buildBottomDetailsPanel(),
              ],
            ),
    );
  }

  Widget _buildFloatingHeader() {
    final hasStaleWarning =
        _lastUpdated != null &&
        DateTime.now().difference(_lastUpdated!).inSeconds > 30;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.backgroundMidnight.withOpacity(0.85),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.borderSlate.withOpacity(0.4)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          // Bus icon banner
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppTheme.primaryCyan, AppTheme.accentIndigo],
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Center(
              child: Text('🚌', style: TextStyle(fontSize: 20)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _busId.isNotEmpty ? 'Bus $_busId' : 'Tracking Bus',
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '$_routeName • $_schoolName',
                  style: const TextStyle(
                    color: AppTheme.primaryCyan,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // Stale warning indicator
          if (hasStaleWarning)
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.statusYellow.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppTheme.statusYellow.withOpacity(0.4),
                ),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('⚠️ ', style: TextStyle(fontSize: 10)),
                  Text(
                    'Stale',
                    style: TextStyle(
                      fontSize: 10,
                      color: AppTheme.statusYellow,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          // Connection state dot
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: _isConnected ? AppTheme.statusGreen : AppTheme.statusRed,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color:
                      (_isConnected ? AppTheme.statusGreen : AppTheme.statusRed)
                          .withOpacity(0.4),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Live status badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _busStatus == 'active'
                  ? AppTheme.statusGreen.withOpacity(0.15)
                  : AppTheme.textMuted.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _busStatus == 'active'
                    ? AppTheme.statusGreen.withOpacity(0.3)
                    : AppTheme.textMuted.withOpacity(0.3),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_busStatus == 'active')
                  Container(
                    width: 4,
                    height: 4,
                    margin: const EdgeInsets.only(right: 4),
                    decoration: const BoxDecoration(
                      color: AppTheme.statusGreen,
                      shape: BoxShape.circle,
                    ),
                  ),
                Text(
                  _busStatus == 'active' ? 'LIVE' : 'IDLE',
                  style: TextStyle(
                    fontSize: 9,
                    color: _busStatus == 'active'
                        ? AppTheme.statusGreen
                        : AppTheme.textSecondary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(
              Icons.logout_rounded,
              color: AppTheme.statusRed,
              size: 20,
            ),
            onPressed: _handleSignOut,
            tooltip: 'Sign Out',
          ),
        ],
      ),
    );
  }

  Widget _buildMap() {
    final center = _busLocation ?? _homeLocation ?? LatLng(20.5937, 78.9629);

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: center,
            initialZoom: 14.0,
            onTap: (tapPosition, point) {
              if (_isSelectingStop) {
                setState(() {
                  _temporarySelectedStop = point;
                });
                _saveDrawerSettings();
              }
            },
          ),
          children: [
            TileLayer(
              urlTemplate:
                  'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}@2x.png',
              subdomains: const ['a', 'b', 'c', 'd'],
              userAgentPackageName: 'com.buspulse.driver',
              tileProvider: _cacheStore != null
                  ? CachedTileProvider(store: _cacheStore!)
                  : NetworkTileProvider(),
            ),
            // Planned OSRM route path
            if (_routeCoordinates != null)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: _routeCoordinates!,
                    color: const Color(0xFF8B5CF6),
                    strokeWidth: 4.0,
                    isDotted: true,
                  ),
                ],
              ),
            // Breadcrumb path layer
            if (_trailPoints.isNotEmpty)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: _trailPoints,
                    color: const Color(0xFF3B82F6),
                    strokeWidth: 2.0,
                  ),
                ],
              ),
            MarkerLayer(
              markers: [
                if (_schoolLocation != null)
                  Marker(
                    point: _schoolLocation!,
                    width: 36,
                    height: 36,
                    child: _buildPinIcon('🏫', Colors.green),
                  ),
                if (_homeLocation != null)
                  Marker(
                    point: _homeLocation!,
                    width: 36,
                    height: 36,
                    child: _buildPinIcon('🏡', Colors.blue),
                  ),
                if (_temporarySelectedStop != null)
                  Marker(
                    point: _temporarySelectedStop!,
                    width: 36,
                    height: 36,
                    child: _buildPinIcon('🏡', Colors.orange),
                  ),
                if (_busLocation != null)
                  Marker(
                    point: _busLocation!,
                    width: 44,
                    height: 44,
                    child: _buildBusIcon(),
                  ),
              ],
            ),
          ],
        ),
        // Floating Location FAB
        Positioned(
          bottom:
              MediaQuery.of(context).size.height * 0.35 +
              24, // position above the collapsed bottom sheet
          right: 16,
          child: FloatingActionButton(
            mini: true,
            backgroundColor: AppTheme.surfaceSlate,
            foregroundColor: AppTheme.textPrimary,
            child: const Icon(Icons.my_location),
            onPressed: () {
              if (_busLocation != null) {
                _mapController.move(_busLocation!, 16);
              } else if (_homeLocation != null) {
                _mapController.move(_homeLocation!, 15);
              }
            },
          ),
        ),
        // Floating center ETA label
        if (_busStatus == 'active' && _calculatedEtaMin != null)
          Positioned(
            top:
                MediaQuery.of(context).padding.top +
                84, // position below the floating header
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.backgroundMidnight.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppTheme.borderSlate),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.4),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: Text(
                  'ETA: ${_formatEta(_calculatedEtaMin)}',
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPinIcon(String emoji, Color color) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withOpacity(0.3), width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Center(child: Text(emoji, style: const TextStyle(fontSize: 16))),
    );
  }

  Widget _buildBusIcon() {
    final color = _busStatus == 'active'
        ? AppTheme.statusGreen
        : (_busStatus == 'stopped' ? AppTheme.statusRed : AppTheme.statusGrey);

    return Transform.rotate(
      angle: _heading * (math.pi / 180.0),
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (_busStatus == 'active') _RotatingPulseRing(color: color),
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 6),
              ],
            ),
            child: const Center(
              child: Text('🚌', style: TextStyle(fontSize: 13)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomDetailsPanel() {
    final hasHomeSet = _homeLocation != null;
    final distMeters = _busLocation != null && _homeLocation != null
        ? _haversineDistanceM(_busLocation!, _homeLocation!)
        : 9999.0;
    final showArrivalBanner =
        hasHomeSet && _busStatus == 'active' && distMeters <= 200.0;
    final showArrivedAlert = hasHomeSet && distMeters <= 50.0;

    return DraggableScrollableSheet(
      initialChildSize: 0.44,
      minChildSize: 0.35,
      maxChildSize: 0.85,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: AppTheme.backgroundMidnight.withOpacity(0.92),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.5),
                blurRadius: 24,
                spreadRadius: 4,
                offset: const Offset(0, -4),
              ),
            ],
            border: Border.all(
              color: AppTheme.borderSlate.withOpacity(0.3),
              width: 1.5,
            ),
          ),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
            child: SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Grab Handle
                  Center(
                    child: Container(
                      width: 48,
                      height: 5,
                      margin: const EdgeInsets.only(bottom: 20),
                      decoration: BoxDecoration(
                        color: AppTheme.textMuted.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(2.5),
                      ),
                    ),
                  ),

                  // Welcoming / Status
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Hi, $_parentName 👋',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      Text(
                        _busStatus == 'active'
                            ? 'Bus is en route'
                            : 'Bus is currently idle',
                        style: TextStyle(
                          fontSize: 12,
                          color: _busStatus == 'active'
                              ? AppTheme.statusGreen
                              : AppTheme.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // 1. Alert Banner Cards
                  if (showArrivalBanner)
                    _buildArrivalBanner(
                      'Bus is arriving!',
                      'It is currently ${_formatDistance(_calculatedDistanceKm)} away. Get to your stop!',
                    ),
                  if (showArrivedAlert)
                    _buildArrivalBanner(
                      'Bus has arrived!',
                      'The driver is at your stop now. Walk outside immediately.',
                    ),

                  // 2. Quick Stat Cards Row
                  Row(
                    children: [
                      Expanded(
                        child: _buildStatCard(
                          '⏱️',
                          _formatEta(_calculatedEtaMin),
                          'ETA',
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildStatCard(
                          '📍',
                          hasHomeSet
                              ? _formatDistance(_calculatedDistanceKm)
                              : 'Set Stop',
                          'DISTANCE',
                          onTap: hasHomeSet ? null : _showSettingsDrawer,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildStatCard(
                          '🔄',
                          _formatTimeAgo(_lastUpdated),
                          'UPDATED',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // 3. Custom Speedometer Gauge Card
                  _buildSpeedometerCard(),
                  const SizedBox(height: 20),

                  // 4. Journey progression
                  _buildJourneyTimeline(),
                  const SizedBox(height: 20),

                  // 5. Weather strip
                  if (_weatherTempC != null) _buildWeatherStrip(),
                  if (_weatherTempC != null) const SizedBox(height: 20),

                  // 6. Action buttons
                  _buildActionsRow(),
                  const SizedBox(height: 20),

                  // 7. Alert logs card
                  _buildAlertLogsCard(),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildArrivalBanner(String title, String subtitle) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppTheme.statusGreen.withOpacity(0.25),
            AppTheme.statusGreen.withOpacity(0.08),
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.statusGreen.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          const Text('🎉', style: TextStyle(fontSize: 24)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppTheme.statusGreen,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(
    String emoji,
    String val,
    String label, {
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        decoration: BoxDecoration(
          color: AppTheme.surfaceSlate.withOpacity(0.4),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: AppTheme.borderSlate.withOpacity(0.3),
            width: 1,
          ),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppTheme.primaryCyan.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Text(emoji, style: const TextStyle(fontSize: 20)),
            ),
            const SizedBox(height: 10),
            Text(
              val,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppTheme.textPrimary,
                letterSpacing: 0.5,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              label.toUpperCase(),
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: AppTheme.textSecondary,
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpeedometerCard() {
    final parsedSpeed = _currentSpeed.round();
    Color speedColor = AppTheme.textSecondary;
    String speedLabel = 'Stationary';

    if (parsedSpeed > 0 && parsedSpeed <= 40) {
      speedColor = AppTheme.statusGreen;
      speedLabel = 'Safe Driving Speed';
    } else if (parsedSpeed > 40 && parsedSpeed <= 60) {
      speedColor = AppTheme.statusYellow;
      speedLabel = 'Caution: High Speed';
    } else if (parsedSpeed > 60) {
      speedColor = AppTheme.statusRed;
      speedLabel = 'Warning: Speeding!';
    }

    String motionText = 'Parked / Stop';
    if (parsedSpeed > 0) {
      motionText = parsedSpeed > 50 ? 'Cruising Fast' : 'Moving';
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSlate.withOpacity(0.4),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppTheme.borderSlate.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          // Canvas speedometer gauge
          SizedBox(
            width: 100,
            height: 75,
            child: CustomPaint(
              painter: _SpeedometerPainter(speed: _currentSpeed),
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '$parsedSpeed',
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      'km/h',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  speedLabel,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: speedColor,
                  ),
                ),
                Text(
                  motionText,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.textMuted,
                  ),
                ),
                const SizedBox(height: 12),
                // Zone scale line
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: AppTheme.statusGreen,
                          borderRadius: const BorderRadius.horizontal(
                            left: Radius.circular(2),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Expanded(
                      flex: 1,
                      child: Container(height: 4, color: AppTheme.statusYellow),
                    ),
                    const SizedBox(width: 2),
                    Expanded(
                      flex: 1,
                      child: Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: AppTheme.statusRed,
                          borderRadius: const BorderRadius.horizontal(
                            right: Radius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '0-40 (Safe)',
                      style: TextStyle(fontSize: 9, color: AppTheme.textMuted),
                    ),
                    Text(
                      '40-60 (High)',
                      style: TextStyle(fontSize: 9, color: AppTheme.textMuted),
                    ),
                    Text(
                      '60+ (Alert)',
                      style: TextStyle(fontSize: 9, color: AppTheme.textMuted),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildJourneyTimeline() {
    String stateLabel = 'Idle';
    Color badgeColor = AppTheme.textMuted;

    switch (_journeyState) {
      case JourneyState.atSchool:
        stateLabel = 'At School';
        badgeColor = AppTheme.primaryCyan;
        break;
      case JourneyState.enRoute:
        stateLabel = 'En Route';
        badgeColor = AppTheme.accentIndigo;
        break;
      case JourneyState.approaching:
        stateLabel = 'Approaching Stop';
        badgeColor = AppTheme.statusYellow;
        break;
      case JourneyState.arrived:
        stateLabel = 'Arrived';
        badgeColor = AppTheme.statusGreen;
        break;
      case JourneyState.idle:
      default:
        stateLabel = 'Idle';
        badgeColor = AppTheme.textMuted;
    }

    final String lastUpdatedStr = _lastUpdated != null
        ? DateTime.now().difference(_lastUpdated!).inSeconds < 10
              ? 'Now'
              : '${_lastUpdated!.hour.toString().padLeft(2, '0')}:${_lastUpdated!.minute.toString().padLeft(2, '0')}'
        : '—';

    final isSchoolActive = _journeyState == JourneyState.atSchool;
    final isTransitActive =
        _journeyState == JourneyState.enRoute ||
        _journeyState == JourneyState.approaching;
    final isHomeActive = _journeyState == JourneyState.arrived;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSlate.withOpacity(0.4),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppTheme.borderSlate.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Journey Progress',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: AppTheme.textPrimary,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: badgeColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: badgeColor.withOpacity(0.4)),
                ),
                child: Text(
                  stateLabel,
                  style: TextStyle(
                    fontSize: 9,
                    color: badgeColor,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          // Horizontal progress track
          Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                top: 15,
                left: 24,
                right: 24,
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.borderSlate.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Positioned(
                top: 15,
                left: 24,
                right: 24,
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: _progressPercent / 100.0,
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppTheme.primaryCyan,
                      borderRadius: BorderRadius.circular(2),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.primaryCyan.withOpacity(0.5),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildTimelineNode(
                    '🏫',
                    'School',
                    isSchoolActive ? lastUpdatedStr : '—',
                    isSchoolActive,
                  ),
                  _buildTimelineNode(
                    '🛣️',
                    'Transit',
                    isTransitActive ? lastUpdatedStr : '—',
                    isTransitActive,
                  ),
                  _buildTimelineNode(
                    '🏡',
                    'Your Stop',
                    isHomeActive ? lastUpdatedStr : '—',
                    isHomeActive,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineNode(
    String emoji,
    String title,
    String timeStr,
    bool isActive,
  ) {
    return Column(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: isActive
                ? AppTheme.primaryCyan.withOpacity(0.15)
                : AppTheme.surfaceSlate,
            shape: BoxShape.circle,
            border: Border.all(
              color: isActive
                  ? AppTheme.primaryCyan
                  : AppTheme.borderSlate.withOpacity(0.6),
              width: isActive ? 2.5 : 1.5,
            ),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: AppTheme.primaryCyan.withOpacity(0.3),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : [],
          ),
          child: Center(
            child: Text(emoji, style: const TextStyle(fontSize: 16)),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 10,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            color: isActive ? AppTheme.textPrimary : AppTheme.textSecondary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          timeStr,
          style: const TextStyle(fontSize: 9, color: AppTheme.textMuted),
        ),
      ],
    );
  }

  Widget _buildWeatherStrip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSlate.withOpacity(0.4),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppTheme.borderSlate.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Text(_weatherIcon ?? '☀️', style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 12),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textSecondary,
                ),
                children: [
                  const TextSpan(text: 'At bus: '),
                  TextSpan(
                    text: '${_weatherTempC!.round()}°C',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  TextSpan(text: ', $_weatherLabel'),
                ],
              ),
            ),
          ),
          Text(
            '💨 ${_weatherWindSpeed!.round()} km/h',
            style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildActionsRow() {
    return Row(
      children: [
        Expanded(
          child: _buildActionBtn(
            Icons.share_outlined,
            'Share Track',
            _shareTrackingLink,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildActionBtn(
            Icons.settings_outlined,
            'Alert Settings',
            _showSettingsDrawer,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildActionBtn(
            Icons.warning_amber_outlined,
            'Report Issue',
            _showReportIssueDialog,
            isDanger: true,
          ),
        ),
      ],
    );
  }

  Widget _buildActionBtn(
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool isDanger = false,
  }) {
    return AspectRatio(
      aspectRatio: 1.0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          decoration: BoxDecoration(
            color: AppTheme.surfaceSlate.withOpacity(0.4),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isDanger
                  ? AppTheme.statusRed.withOpacity(0.3)
                  : AppTheme.borderSlate.withOpacity(0.3),
              width: 1,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isDanger
                      ? AppTheme.statusRed.withOpacity(0.1)
                      : AppTheme.primaryCyan.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  color: isDanger ? AppTheme.statusRed : AppTheme.primaryCyan,
                  size: 20,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: isDanger ? AppTheme.statusRed : AppTheme.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAlertLogsCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSlate.withOpacity(0.4),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppTheme.borderSlate.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Today\'s Alerts & Events',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 16),
          if (_alertLogs.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Text(
                'No alerts logged for this journey.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
              ),
            )
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _alertLogs.length,
              itemBuilder: (context, idx) {
                final item = _alertLogs[idx];
                final String timeStr =
                    '${item.timestamp.hour.toString().padLeft(2, '0')}:${item.timestamp.minute.toString().padLeft(2, '0')}:${item.timestamp.second.toString().padLeft(2, '0')}';

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceSlate.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: item.indicatorColor,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: item.indicatorColor.withOpacity(0.4),
                              blurRadius: 4,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          item.message,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        timeStr,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.textMuted,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------
// Custom Canvas Speedometer Painter
// ----------------------------------------------------

class _SpeedometerPainter extends CustomPainter {
  final double speed;

  _SpeedometerPainter({required this.speed});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 5, size.width, size.height * 2 - 10);
    const startAngle = math.pi; // left side
    const sweepAngle = math.pi; // sweep to right side

    // Background track paint
    final bgPaint = Paint()
      ..color = Colors.white.withOpacity(0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8.0
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, startAngle, sweepAngle, false, bgPaint);

    // Speed indicator paint with gradient shader
    final speedPercent = math.max(0.0, math.min(speed / 80.0, 1.0));
    if (speedPercent > 0.0) {
      final gradient = SweepGradient(
        colors: const [
          Color(0xFF22C55E), // green
          Color(0xFFF59E0B), // yellow/amber
          Color(0xFFEF4444), // red
        ],
        stops: const [0.0, 0.6, 1.0],
        startAngle: startAngle,
        endAngle: startAngle + sweepAngle,
      );

      final progressPaint = Paint()
        ..shader = gradient.createShader(rect)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8.0
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        rect,
        startAngle,
        sweepAngle * speedPercent,
        false,
        progressPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SpeedometerPainter oldDelegate) {
    return oldDelegate.speed != speed;
  }
}

// ----------------------------------------------------
// Pulse effect child widget
// ----------------------------------------------------

class _RotatingPulseRing extends StatefulWidget {
  final Color color;
  const _RotatingPulseRing({required this.color});

  @override
  State<_RotatingPulseRing> createState() => _RotatingPulseRingState();
}

class _RotatingPulseRingState extends State<_RotatingPulseRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final double scale = 1.0 + (_controller.value * 0.5);
        final double opacity = 0.18 * (1.0 - _controller.value);
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: widget.color.withOpacity(opacity),
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }
}

// Data holder helper classes
class _RouteBlendedInfo {
  final double distanceKm;
  final int etaMinutes;
  final List<LatLng>? coordinates;

  _RouteBlendedInfo({
    required this.distanceKm,
    required this.etaMinutes,
    this.coordinates,
  });
}

class _WmoWeather {
  final String label;
  final String icon;

  _WmoWeather(this.label, this.icon);
}
