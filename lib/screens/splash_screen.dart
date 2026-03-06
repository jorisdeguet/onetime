import 'package:flutter/material.dart';

import '../services/startup_health_check_service.dart';

/// Splash screen shown during startup while health checks run.
///
/// Displays a loading indicator and then transitions to [nextScreen]
/// once all checks have completed.
class SplashScreen extends StatefulWidget {
  /// Widget to show after startup checks complete.
  final Widget nextScreen;

  const SplashScreen({super.key, required this.nextScreen});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _runChecksAndNavigate();
  }

  Future<void> _runChecksAndNavigate() async {
    await StartupHealthCheckService().runAll();

    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => widget.nextScreen),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '1 time',
              style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 32),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
