import 'package:flutter/material.dart';
import 'package:buspulse_driver/theme/app_theme.dart';

class AppSplashScreen extends StatelessWidget {
  final String message;
  const AppSplashScreen({super.key, this.message = 'Loading...'});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundMidnight,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Glowing Logo Badge
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppTheme.primaryCyan.withOpacity(0.1),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.primaryCyan.withOpacity(0.15),
                    blurRadius: 32,
                    spreadRadius: 2,
                  )
                ],
              ),
              child: const Icon(
                Icons.directions_bus_rounded,
                size: 64,
                color: AppTheme.primaryCyan,
              ),
            ),
            const SizedBox(height: 24),
            
            // App Name
            const Text(
              'BusPulse',
              style: TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.w900,
                color: AppTheme.textPrimary,
                letterSpacing: 2.0,
              ),
            ),
            const SizedBox(height: 8),
            
            // Status Message
            Text(
              message,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 48),
            
            // Sleek linear progress bar
            SizedBox(
              width: 140,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: const LinearProgressIndicator(
                  backgroundColor: AppTheme.borderSlate,
                  valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primaryCyan),
                  minHeight: 3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
