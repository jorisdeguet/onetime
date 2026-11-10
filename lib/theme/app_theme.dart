import 'package:flutter/material.dart';

/// Black and white look: black on white in light mode, white on black in dark
/// mode, dark greys for status indicators. Red is kept for errors only.
class AppTheme {
  static ThemeData light() => _build(const ColorScheme(
        brightness: Brightness.light,
        primary: Color(0xFF000000),
        onPrimary: Color(0xFFFFFFFF),
        primaryContainer: Color(0xFFE6E6E6),
        onPrimaryContainer: Color(0xFF000000),
        secondary: Color(0xFF3D3D3D),
        onSecondary: Color(0xFFFFFFFF),
        secondaryContainer: Color(0xFFEDEDED),
        onSecondaryContainer: Color(0xFF1A1A1A),
        tertiary: Color(0xFF5C5C5C),
        onTertiary: Color(0xFFFFFFFF),
        error: Color(0xFFB3261E),
        onError: Color(0xFFFFFFFF),
        surface: Color(0xFFFFFFFF),
        onSurface: Color(0xFF000000),
        onSurfaceVariant: Color(0xFF4A4A4A),
        surfaceContainerLowest: Color(0xFFFFFFFF),
        surfaceContainerLow: Color(0xFFF7F7F7),
        surfaceContainer: Color(0xFFF2F2F2),
        surfaceContainerHigh: Color(0xFFECECEC),
        surfaceContainerHighest: Color(0xFFE4E4E4),
        outline: Color(0xFF8A8A8A),
        outlineVariant: Color(0xFFD0D0D0),
        inverseSurface: Color(0xFF1A1A1A),
        onInverseSurface: Color(0xFFF2F2F2),
        shadow: Color(0xFF000000),
      ));

  static ThemeData dark() => _build(const ColorScheme(
        brightness: Brightness.dark,
        primary: Color(0xFFFFFFFF),
        onPrimary: Color(0xFF000000),
        primaryContainer: Color(0xFF2E2E2E),
        onPrimaryContainer: Color(0xFFFFFFFF),
        secondary: Color(0xFFC9C9C9),
        onSecondary: Color(0xFF000000),
        secondaryContainer: Color(0xFF262626),
        onSecondaryContainer: Color(0xFFEDEDED),
        tertiary: Color(0xFFA6A6A6),
        onTertiary: Color(0xFF000000),
        error: Color(0xFFF2B8B5),
        onError: Color(0xFF601410),
        surface: Color(0xFF000000),
        onSurface: Color(0xFFFFFFFF),
        onSurfaceVariant: Color(0xFFBDBDBD),
        surfaceContainerLowest: Color(0xFF000000),
        surfaceContainerLow: Color(0xFF0D0D0D),
        surfaceContainer: Color(0xFF141414),
        surfaceContainerHigh: Color(0xFF1C1C1C),
        surfaceContainerHighest: Color(0xFF262626),
        outline: Color(0xFF7A7A7A),
        outlineVariant: Color(0xFF3A3A3A),
        inverseSurface: Color(0xFFEDEDED),
        onInverseSurface: Color(0xFF1A1A1A),
        shadow: Color(0xFF000000),
      ));

  static ThemeData _build(ColorScheme scheme) {
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
      ),
    );
  }
}

/// Status colours: shades of grey from the theme, red only for errors.
extension StatusColors on ColorScheme {
  /// Done / received / ready.
  Color get statusOk => onSurface;

  /// In progress / waiting.
  Color get statusPending => onSurfaceVariant;

  /// Not started / inactive.
  Color get statusIdle => outline;
}
