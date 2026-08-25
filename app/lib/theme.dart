import 'package:flutter/material.dart';

/// Spotify-flavoured design tokens.
class Spots {
  static const green = Color(0xFF1DB954);
  static const greenDark = Color(0xFF169C46);
  static const base = Color(0xFF121212);
  static const elevated = Color(0xFF1F1F1F);
  static const subtle = Color(0xFF2A2A2A);

  static ThemeData dark() {
    final cs = ColorScheme.fromSeed(
      seedColor: green,
      brightness: Brightness.dark,
      surface: base,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      scaffoldBackgroundColor: base,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: elevated,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: cs.onSurface.withOpacity(.87),
        minLeadingWidth: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: base,
        indicatorColor: Colors.transparent,
        height: 64,
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
              size: 26,
              color: states.contains(WidgetState.selected)
                  ? Colors.white
                  : Colors.white54,
            )),
        labelTextStyle: WidgetStateProperty.resolveWith((states) =>
            TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: states.contains(WidgetState.selected)
                    ? Colors.white
                    : Colors.white54)),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      dividerTheme: DividerThemeData(color: Colors.white12),
      sliderTheme: SliderThemeData(
        activeTrackColor: green,
        thumbColor: Colors.white,
        inactiveTrackColor: subtle,
        trackHeight: 3,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: green,
          foregroundColor: Colors.black,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  /// Deterministic gradient cover for a given name.
  static LinearGradient coverGradient(String seed) {
    final hues = [
      [const Color(0xFF1f4037), const Color(0xFF99f2c8)],
      [const Color(0xFF41295a), const Color(0xFF2F0743)],
      [const Color(0xFF373B44), const Color(0xFF4286f4)],
      [const Color(0xFF603813), const Color(0xFFb29f94)],
      [const Color(0xFF16222A), const Color(0xFF3A6073)],
      [const Color(0xFF5f2c82), const Color(0xFF49a09d)],
    ];
    var h = 0;
    for (final c in seed.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    final pair = hues[h % hues.length];
    return LinearGradient(
        colors: pair, begin: Alignment.topLeft, end: Alignment.bottomRight);
  }
}
