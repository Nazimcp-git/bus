import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:buspulse_driver/models/journey_log.dart';
import 'package:buspulse_driver/services/auth_service.dart';
import 'package:buspulse_driver/services/location_service.dart';
import 'package:buspulse_driver/theme/app_theme.dart';
import 'package:buspulse_driver/pages/login_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  bool _isStreaming = false;
  bool _isConnected = true;
  
  double? _lat;
  double? _lng;
  int? _speed;
  int? _heading;
  double? _accuracy;
  bool _isEstimatedHeading = false;

  final List<JourneyLog> _logs = [];
  
  late AnimationController _pulseController;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  final List<StreamSubscription> _serviceSubscriptions = [];

  @override
  void initState() {
    super.initState();
    
    // Pulsing animation for active stream indicator
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);

    _checkServiceStatus();
    _setupConnectivityListener();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _connectivitySubscription?.cancel();
    _clearServiceSubscriptions();
    super.dispose();
  }

  void _clearServiceSubscriptions() {
    for (var sub in _serviceSubscriptions) {
      sub.cancel();
    }
    _serviceSubscriptions.clear();
  }

  // Check if background service is already running on view load
  Future<void> _checkServiceStatus() async {
    final service = FlutterBackgroundService();
    final running = await service.isRunning();
    
    setState(() {
      _isStreaming = running;
    });

    if (running) {
      _subscribeToServiceEvents();
    }
  }

  // Monitor internet connection changes at app UI level
  void _setupConnectivityListener() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> results) {
      final connected = results.isNotEmpty && results.first != ConnectivityResult.none;
      setState(() {
        _isConnected = connected;
      });
    });
  }

  // Subscribe to background service broadcast port events
  void _subscribeToServiceEvents() {
    _clearServiceSubscriptions();
    final service = FlutterBackgroundService();

    // 1. Listen to location updates
    _serviceSubscriptions.add(service.on('updateLocation').listen((event) {
      if (event != null && mounted) {
        setState(() {
          _lat = event['lat'] as double?;
          _lng = event['lng'] as double?;
          _speed = event['speed'] as int?;
          _heading = event['heading'] as int?;
          _accuracy = event['accuracy'] as double?;
          _isEstimatedHeading = event['isEstimatedHeading'] as bool? ?? false;
        });
      }
    }));

    // 2. Listen to journey log additions
    _serviceSubscriptions.add(service.on('addLog').listen((event) {
      if (event != null && mounted) {
        final severityStr = event['severity'] as String? ?? 'info';
        LogSeverity severity = LogSeverity.info;
        if (severityStr == 'success') severity = LogSeverity.success;
        if (severityStr == 'warning') severity = LogSeverity.warning;
        if (severityStr == 'error') severity = LogSeverity.error;

        final logTime = event['timestamp'] != null 
            ? DateTime.parse(event['timestamp'] as String) 
            : DateTime.now();

        setState(() {
          _logs.insert(
            0,
            JourneyLog(
              timestamp: logTime,
              message: event['message'] as String? ?? '',
              severity: severity,
            ),
          );
          if (_logs.length > 20) {
            _logs.removeLast();
          }
        });
      }
    }));

    // 3. Listen to connection state updates from the service
    _serviceSubscriptions.add(service.on('updateStatus').listen((event) {
      if (event != null && mounted) {
        setState(() {
          if (event.containsKey('isConnected')) {
            _isConnected = event['isConnected'] as bool;
          }
        });
      }
    }));
  }

  // Start the GPS streaming process
  Future<void> _startStreaming() async {
    final permitted = await LocationService.requestPermissions();
    if (!permitted) {
      _showWarningSnackBar("Permission Denied: Location permissions are required to run tracking.");
      return;
    }

    final service = FlutterBackgroundService();
    final started = await service.startService();
    
    if (started) {
      setState(() {
        _isStreaming = true;
        _logs.clear();
        _logs.insert(
          0,
          JourneyLog(
            timestamp: DateTime.now(),
            message: "Location stream command issued.",
            severity: LogSeverity.info,
          ),
        );
      });
      _subscribeToServiceEvents();
    } else {
      _showWarningSnackBar("Failed to start tracking service.");
    }
  }

  // Stop the GPS streaming process
  void _stopStreaming() {
    final service = FlutterBackgroundService();
    service.invoke('stopService');
    
    setState(() {
      _isStreaming = false;
      _lat = null;
      _lng = null;
      _speed = null;
      _heading = null;
      _accuracy = null;
      _isEstimatedHeading = false;
    });
    
    _clearServiceSubscriptions();
  }

  void _showWarningSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppTheme.statusYellow,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _handleSignOut(AuthProvider auth) async {
    if (_isStreaming) {
      _stopStreaming();
    }
    await auth.signOut();
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const LoginPage()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);
    final schoolName = auth.schoolName ?? "Loading School...";
    final busId = auth.busId ?? "N/A";
    final routeName = auth.routeName ?? "No route assigned";

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Bus Pulse',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w900,
            color: AppTheme.primaryCyan,
            letterSpacing: 0.5,
          ),
        ),
        actions: [
          // Connection Status Indicator
          Center(
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: _isConnected ? AppTheme.statusGreen : AppTheme.statusRed,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: (_isConnected ? AppTheme.statusGreen : AppTheme.statusRed).withValues(alpha: 0.4),
                    blurRadius: 4,
                    spreadRadius: 2,
                  )
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            icon: const Icon(Icons.logout_rounded, color: AppTheme.statusRed),
            onPressed: () => _handleSignOut(auth),
            tooltip: 'Sign Out',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // Sliding Offline Banner
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            height: _isConnected ? 0 : 40,
            width: double.infinity,
            color: AppTheme.statusRed,
            alignment: Alignment.center,
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.wifi_off_rounded, size: 16, color: AppTheme.textPrimary),
                SizedBox(width: 8),
                Text(
                  'No Internet Connection - GPS writes paused',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Welcoming Header Greeting
                  Padding(
                    padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          auth.name != null ? 'Hello, ${auth.name} 👋' : 'Hello Driver 👋',
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Welcome to your tracking console.',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Database Connection Error Banner
                  if (auth.errorMessage != null)
                    Container(
                      margin: const EdgeInsets.all(16),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.statusRed.withValues(alpha: 0.15),
                        border: Border.all(color: AppTheme.statusRed),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.cloud_off_rounded, color: AppTheme.statusRed, size: 28),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Connection / Profile Error',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                        color: AppTheme.textPrimary,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      auth.errorMessage!,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: AppTheme.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            ],
                          ),
                          const SizedBox(height: 12),
                          ElevatedButton.icon(
                            onPressed: auth.isLoading
                                ? null
                                : () => auth.retryLoadingProfile(),
                            icon: auth.isLoading
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      color: AppTheme.textPrimary,
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.refresh_rounded),
                            label: Text(
                              auth.isLoading ? 'RETRYING...' : 'RETRY CONNECTION',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.statusRed,
                              foregroundColor: AppTheme.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),

                  // Guardrail Warning Banner
                  if (auth.hasMissingAssignments && auth.errorMessage == null)
                    Container(
                      margin: const EdgeInsets.all(16),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.statusRed.withValues(alpha: 0.15),
                        border: Border.all(color: AppTheme.statusRed),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.error_outline_rounded, color: AppTheme.statusRed, size: 28),
                          SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Missing Assignments',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    color: AppTheme.textPrimary,
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'No bus or school assigned. Contact Admin.',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          )
                        ],
                      ),
                    ),

                  // Driver Details Header Card (Whitespace and clean design)
                  if (!auth.hasMissingAssignments)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceSlate.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppTheme.borderSlate.withValues(alpha: 0.5)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppTheme.primaryCyan.withValues(alpha: 0.1),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.directions_bus_rounded,
                                color: AppTheme.primaryCyan,
                                size: 24,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    schoolName.toUpperCase(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                      color: AppTheme.primaryCyan,
                                      letterSpacing: 1.5,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        'Bus $busId',
                                        style: const TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: AppTheme.textPrimary,
                                        ),
                                      ),
                                      if (auth.name != null)
                                        Text(
                                          auth.name!,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold,
                                            color: AppTheme.primaryCyan,
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    routeName.isNotEmpty ? routeName : 'No Route Assigned',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // Console Status Card
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Console status',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: AppTheme.textSecondary,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        // Pulsing status dot
                                        AnimatedBuilder(
                                          animation: _pulseController,
                                          builder: (context, child) {
                                            return Container(
                                              width: 10,
                                              height: 10,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: _isStreaming ? AppTheme.statusGreen : AppTheme.statusGrey,
                                                boxShadow: _isStreaming
                                                    ? [
                                                        BoxShadow(
                                                          color: AppTheme.statusGreen.withValues(alpha: 0.6 * _pulseController.value),
                                                          blurRadius: 8,
                                                          spreadRadius: 4 * _pulseController.value,
                                                        )
                                                      ]
                                                    : [],
                                              ),
                                            );
                                          },
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            _isStreaming ? 'Streaming Live' : 'Tracking Stopped',
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                              color: _isStreaming ? AppTheme.statusGreen : AppTheme.textSecondary,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              _buildAccuracyBadge(),
                            ],
                          ),
                          const SizedBox(height: 32),

                          // Large Circular Toggle Button
                          GestureDetector(
                            onTap: auth.hasMissingAssignments
                                ? () => _showWarningSnackBar("Cannot start stream: Assignment missing.")
                                : () {
                                    if (_isStreaming) {
                                      _stopStreaming();
                                    } else {
                                      _startStreaming();
                                    }
                                  },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 300),
                              width: 160,
                              height: 160,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _isStreaming ? AppTheme.statusRed : AppTheme.primaryCyan,
                                border: Border.all(
                                  color: (_isStreaming ? AppTheme.statusRed : AppTheme.primaryCyan).withValues(alpha: 0.3),
                                  width: 10,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: (_isStreaming ? AppTheme.statusRed : AppTheme.primaryCyan).withValues(alpha: 0.4),
                                    blurRadius: 24,
                                    spreadRadius: 4,
                                  )
                                ],
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    _isStreaming ? Icons.stop_rounded : Icons.sensors_rounded,
                                    size: 44,
                                    color: AppTheme.backgroundMidnight,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    _isStreaming ? 'STOP STREAM' : 'START STREAM',
                                    style: const TextStyle(
                                      color: AppTheme.backgroundMidnight,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                      ),
                    ),
                  ),

                  // Live Stats Grid
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(left: 4, bottom: 8),
                          child: Text(
                            'LIVE STATS',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.textSecondary,
                              letterSpacing: 1.0,
                            ),
                          ),
                        ),
                        GridView.count(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          crossAxisCount: 2,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 1.6,
                          children: [
                            _buildStatCard('Latitude', _lat != null ? _lat!.toStringAsFixed(5) : '--.-----', Icons.my_location_rounded),
                            _buildStatCard('Longitude', _lng != null ? _lng!.toStringAsFixed(5) : '--.-----', Icons.my_location_rounded),
                            _buildStatCard('Speed', _speed != null ? '$_speed km/h' : '0 km/h', Icons.speed_rounded),
                            _buildStatCard(
                              'Heading',
                              _heading != null 
                                  ? '$_heading°${_isEstimatedHeading ? ' (Est)' : ''}'
                                  : '0°',
                              Icons.explore_outlined,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Journey Logs Widget
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                "Today's Journey Log",
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: AppTheme.textPrimary,
                                ),
                              ),
                              Text(
                                "${_logs.length} logged",
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                            ],
                          ),
                          const Divider(height: 24, color: AppTheme.borderSlate),
                          _logs.isEmpty
                              ? Container(
                                  padding: const EdgeInsets.symmetric(vertical: 32),
                                  alignment: Alignment.center,
                                  child: const Text(
                                    "No events logged yet.",
                                    style: TextStyle(
                                      color: AppTheme.textMuted,
                                      fontSize: 14,
                                    ),
                                  ),
                                )
                              : ListView.builder(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  itemCount: _logs.length,
                                  itemBuilder: (context, index) {
                                    final log = _logs[index];
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Container(
                                            margin: const EdgeInsets.only(top: 4),
                                            width: 8,
                                            height: 8,
                                            decoration: BoxDecoration(
                                              color: _getSeverityColor(log.severity),
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Text(
                                            log.formattedTime,
                                            style: const TextStyle(
                                              color: AppTheme.textMuted,
                                              fontSize: 12,
                                              fontFamily: 'monospace',
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              log.message,
                                              style: const TextStyle(
                                                color: AppTheme.textPrimary,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSlate,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderSlate, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w500),
              ),
              Icon(icon, size: 16, color: AppTheme.textMuted),
            ],
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccuracyBadge() {
    String label = 'No Signal';
    Color color = AppTheme.statusGrey;

    if (_accuracy != null) {
      if (_accuracy! <= 15.0) {
        label = 'Signal: Excellent';
        color = AppTheme.statusGreen;
      } else if (_accuracy! <= 40.0) {
        label = 'Signal: Good';
        color = AppTheme.statusGreen;
      } else if (_accuracy! <= 80.0) {
        label = 'Signal: Moderate';
        color = AppTheme.statusYellow;
      } else {
        label = 'Signal: Weak';
        color = AppTheme.statusRed;
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Color _getSeverityColor(LogSeverity severity) {
    switch (severity) {
      case LogSeverity.success:
        return AppTheme.statusGreen;
      case LogSeverity.info:
        return AppTheme.primaryCyan;
      case LogSeverity.warning:
        return AppTheme.statusYellow;
      case LogSeverity.error:
        return AppTheme.statusRed;
    }
  }
}
