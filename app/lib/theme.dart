import 'package:flutter/material.dart';

/// Dark spot-themed palette used across the app.
class Spots {
  static const Color green = Color(0xFF1DB954);
  static const Color base = Color(0xFF0E0E13);
  static const Color elevated = Color(0xFF1A1A22);
  static const Color subtle = Color(0xFF26262F);

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: green,
      brightness: Brightness.dark,
      surface: base,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme.copyWith(
        primary: green,
        surface: base,
        onSurface: Colors.white.withValues(alpha: .92),
      ),
      scaffoldBackgroundColor: base,
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: elevated,
        height: 62,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: base,
        elevation: 0,
        centerTitle: false,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: elevated,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: elevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: elevated,
      ),
    );
  }

  static LinearGradient coverGradient(String seed) {
    const palette = <List<Color>>[
      [Color(0xFF1B4965), Color(0xFF15202B)],
      [Color(0xFF2E6E4E), Color(0xFF14261C)],
      [Color(0xFF6E3A2E), Color(0xFF241512)],
      [Color(0xFF5A3A6E), Color(0xFF1C1524)],
      [Color(0xFF6E5A2E), Color(0xFF221C12)],
      [Color(0xFF1E5A6E), Color(0xFF102027)],
    ];
    final colors = palette[seed.hashCode.abs() % palette.length];
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: colors,
    );
  }
}
