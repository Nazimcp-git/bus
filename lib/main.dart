import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:buspulse_driver/firebase_options.dart';
import 'package:buspulse_driver/services/auth_service.dart';
import 'package:buspulse_driver/services/location_service.dart';
import 'package:buspulse_driver/theme/app_theme.dart';
import 'package:buspulse_driver/pages/login_page.dart';
import 'package:buspulse_driver/pages/home_page.dart';
import 'package:buspulse_driver/pages/parent_dashboard_page.dart';
import 'package:buspulse_driver/widgets/app_splash_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Try to initialize Firebase safely
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint("Firebase initialization warning (credentials may be placeholder): $e");
  }

  // Initialize background service configurations
  try {
    await LocationService.initializeService();
  } catch (e) {
    debugPrint("Background location service initialization error: $e");
  }

  runApp(const BusPulseDriverApp());
}

class BusPulseDriverApp extends StatelessWidget {
  const BusPulseDriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
      ],
      child: MaterialApp(
        title: 'Bus Pulse',
        themeMode: ThemeMode.dark,
        darkTheme: AppTheme.darkTheme,
        debugShowCheckedModeBanner: false,
        home: const AuthStateWrapper(),
      ),
    );
  }
}

class AuthStateWrapper extends StatelessWidget {
  const AuthStateWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);

    // If still checking authentication profile state, show a progress screen
    if (authProvider.isLoading && authProvider.currentUser != null) {
      return const AppSplashScreen(
        message: 'Verifying profile assignments...',
      );
    }

    // Direct routing based on authentication state
    if (authProvider.currentUser != null) {
      if (authProvider.role == 'parent') {
        return const ParentDashboardPage();
      }
      return const HomePage();
    } else {
      return const LoginPage();
    }
  }
}
