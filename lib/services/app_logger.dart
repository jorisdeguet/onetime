import 'package:logger/logger.dart';
import 'package:onetime/config/app_config.dart';

/// Lightweight application logger wrapper around `logger` package.
/// This wrapper no longer implements tag-based filtering or custom level
/// handling: it simply forwards calls to the underlying `Logger` instance.
class AppLogger {
  static final AppLogger _instance = AppLogger._internal();
  factory AppLogger() => _instance;

  final Logger _logger;

  AppLogger._internal()
      : _logger = Logger(
          printer: PrettyPrinter(
            methodCount: 0,
            lineLength: 70,
            colors: true,
          ),
        ) {
    // Set global logger level from AppConfig once at startup (if desired)
    try {
      Logger.level = Level.debug;
    } catch (_) {
      // ignore and keep default
    }
  }

  /// Expose the underlying Logger for direct calls when needed.
  Logger get logger => _logger;


  // Convenience methods keep the previous signature: (tag, message)
  // They simply forward to the underlying logger with a tag prefix.
  void v(String tag, String message) { if (AppConfig.enabledLogTags.contains(tag) || AppConfig.enabledLogTags.contains('ALL')) _logger.v('[$tag] $message');}
  void d(String tag, String message) { if (AppConfig.enabledLogTags.contains(tag) || AppConfig.enabledLogTags.contains('ALL')) _logger.d('[$tag] $message');}
  void i(String tag, String message) { if (AppConfig.enabledLogTags.contains(tag) || AppConfig.enabledLogTags.contains('ALL')) _logger.i('[$tag] $message');}
  void w(String tag, String message) { if (AppConfig.enabledLogTags.contains(tag) || AppConfig.enabledLogTags.contains('ALL')) _logger.w('[$tag] $message');}
  void e(String tag, String message) { if (AppConfig.enabledLogTags.contains(tag) || AppConfig.enabledLogTags.contains('ALL')) _logger.e('[$tag] $message');}
}
