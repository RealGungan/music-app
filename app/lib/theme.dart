import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One named theme preset. The palette lives here so the whole app can be
/// re-skinned at runtime (Spots getters read the active preset).
class AppTheme {
  const AppTheme({
    required this.id,
    required this.name,
    required this.accent,
    required this.base,
    required this.elevated,
    required this.subtle,
  });

  final String id;
  final String name;
  final Color accent;
  final Color base;
  final Color elevated;
  final Color subtle;

  ThemeData build() {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
      surface: base,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme.copyWith(
        primary: accent,
        surface: base,
        onSurface: Colors.white.withValues(alpha: .92),
      ),
      scaffoldBackgroundColor: base,
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        height: 62,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: base,
        elevation: 0,
        centerTitle: false,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: subtle,
        contentTextStyle: const TextStyle(color: Colors.white),
        actionTextColor: Spots.green,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: elevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Colors.white24),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: elevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Colors.white24),
        ),
        textStyle: TextStyle(color: Colors.white.withValues(alpha: .92)),
      ),
      bottomSheetTheme: BottomSheetThemeData(backgroundColor: elevated),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: accent,
          selectedForegroundColor: Colors.black,
          backgroundColor: elevated,
          foregroundColor: Colors.white,
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(accent),
        trackVisibility: const WidgetStatePropertyAll(false),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}

/// The built-in theme presets, in display order.
///
/// [base], [elevated] and [subtle] carry a hue hint of the [accent] so the
/// whole shell (backgrounds, bars, cards) visibly re-skins when the theme
/// changes — not just the handful of accent-highlighted widgets.
class AppThemes {
  static const List<AppTheme> all = [
    AppTheme(
      id: 'spotify',
      name: 'Spotify',
      accent: Color(0xFF1DB954),
      base: Color(0xFF0C1512),
      elevated: Color(0xFF17322A),
      subtle: Color(0xFF244A3D),
    ),
    AppTheme(
      id: 'neon',
      name: 'Neon',
      accent: Color(0xFF00F0FF),
      base: Color(0xFF06121C),
      elevated: Color(0xFF0E2739),
      subtle: Color(0xFF17425E),
    ),
    AppTheme(
      id: 'purple',
      name: 'Purple',
      accent: Color(0xFF9B6BFF),
      base: Color(0xFF120C26),
      elevated: Color(0xFF241648),
      subtle: Color(0xFF3A2374),
    ),
    AppTheme(
      id: 'pink',
      name: 'Pink',
      accent: Color(0xFFFF6B9C),
      base: Color(0xFF1D0F1B),
      elevated: Color(0xFF3A1A30),
      subtle: Color(0xFF572847),
    ),
    AppTheme(
      id: 'fullblack',
      name: 'Full Black',
      accent: Color(0xFFF5F5F5),
      base: Color(0xFF000000),
      elevated: Color(0xFF121212),
      subtle: Color(0xFF222222),
    ),
    AppTheme(
      id: 'youtube',
      name: 'YouTube',
      accent: Color(0xFFFF0033),
      base: Color(0xFF17090F),
      elevated: Color(0xFF2B121C),
      subtle: Color(0xFF3F1B28),
    ),
    AppTheme(
      id: 'cyberpunk',
      name: 'Cyberpunk',
      accent: Color(0xFFFF2ED2),
      base: Color(0xFF0D0A24),
      elevated: Color(0xFF241A52),
      subtle: Color(0xFF3A2B87),
    ),
  ];

  static AppTheme byId(String id) =>
      all.firstWhere((t) => t.id == id, orElse: () => all.first);
}

/// Active theme + persistence (SharedPreferences key `theme.current`).
class ThemeStore extends ChangeNotifier {
  ThemeStore._();
  static final ThemeStore instance = ThemeStore._();

  static const _prefsKey = 'theme.current';

  AppTheme _current = AppThemes.all.first;
  AppTheme get current => _current;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _current = AppThemes.byId(prefs.getString(_prefsKey) ?? '');
    notifyListeners();
  }

  Future<void> set(String id) async {
    _current = AppThemes.byId(id);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, id);
  }
}

/// Small option descriptions for the config UI (nav bar + player looks).
class UiOption {
  const UiOption(this.id, this.name, this.icon);
  final String id;
  final String name;
  final IconData icon;
}

/// Nav-bar look (solid / pill / glass).
const kNavStyleOptions = [
  UiOption('solid', 'Solid', Icons.rectangle_outlined),
  UiOption('pill', 'Pill', Icons.rounded_corner),
  UiOption('glass', 'Glass', Icons.blur_on),
];

/// Full-player title look: centered title with side buttons (classic) or
/// title left + like/playlist right (row), with a scrolling title when long.
const kPlayerTitleOptions = [
  UiOption('classic', 'Centered title', Icons.title),
  UiOption('row', 'Title left', Icons.format_align_left),
];

/// Full-player progress bar look: classic slider or SoundCloud-style waves.
const kPlayerProgressOptions = [
  UiOption('slider', 'Slider', Icons.tune),
  UiOption('waves', 'Waves', Icons.graphic_eq),
];

/// Shared Hero tag pairing the mini-player thumbnail with the full-player
/// artwork, so the album art "grows" from the mini player into the player
/// (YouTube-Music-style expansion) when the Now Playing route opens/closes.
const kPlayerArtHeroTag = 'now-playing-art';

/// Shared tag for the album-art Hero flight between the mini-player thumbnail
/// and the full-screen player artwork (YouTube-Music-style grow-in).
const kNowPlayingArtHero = 'now-playing-art';

/// Full-player control buttons, in the order the user arranged them
/// (reorderable in the Look & feel screen, persisted in UiStore).
/// Icons match the widgets in `now_playing.dart`; `setPlayerOrder` normalizes
/// any list back onto this catalog (drops unknown ids, appends any missing).
class PlayerButtons {
  static const catalog = [
    UiOption('queue', 'Queue', Icons.queue_music),
    UiOption('shuffle', 'Shuffle', Icons.shuffle),
    UiOption('repeat', 'Repeat', Icons.repeat),
    UiOption('autoplay', 'Autoplay', Icons.all_inclusive),
    UiOption('lyrics', 'Lyrics', Icons.lyrics_outlined),
    UiOption('share', 'Share', Icons.share_outlined),
  ];

  static const defaultOrder = [
    'queue',
    'share',
    'shuffle',
    'repeat',
    'autoplay',
    'lyrics',
  ];

  static List<String> normalize(List<String>? order) {
    final result = <String>[];
    if (order != null) {
      for (final id in order) {
        if (catalog.any((b) => b.id == id) && !result.contains(id)) {
          result.add(id);
        }
      }
    }
    for (final id in defaultOrder) {
      if (!result.contains(id)) result.add(id);
    }
    return result;
  }
}

/// UI look preferences (theme-independent): nav-bar style + full-player button
/// order, persisted under `ui.navbar` / `ui.player`.
class UiStore extends ChangeNotifier {
  UiStore._();
  static final UiStore instance = UiStore._();

  static const _navKey = 'ui.navbar';
  // Deliberately NOT 'ui.player' — an older build stored that key via setString
  // ('classic'...), and getStringList() would throw casting a String to a List,
  // taking down the whole app at boot. New key therefore never collides.
  static const _playerKey = 'ui.player.buttons';
  static const _flankLeftKey = 'ui.player.flank-left';
  static const _flankRightKey = 'ui.player.flank-right';
  static const _titleStyleKey = 'ui.player.title-style';
  static const _progressKey = 'ui.player.progress';

  String _navStyle = 'solid';
  String get navStyle => _navStyle;

  String _titleStyle = 'classic';
  String get titleStyle => _titleStyle;

  String _progressStyle = 'slider';
  String get progressStyle => _progressStyle;

  List<String> _playerOrder = List.of(PlayerButtons.defaultOrder);

  /// Button ids in the user's chosen order, guaranteed to cover the catalog.
  List<String> get playerOrder => _playerOrder;

  /// Transport flank slots (left of previous / right of next), any catalog
  /// id. These buttons leave the bottom row while slotted.
  String _transportLeft = 'shuffle';
  String _transportRight = 'repeat';
  String get transportLeft => _transportLeft;
  String get transportRight => _transportRight;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _navStyle = prefs.getString(_navKey) ?? 'solid';
    _titleStyle =
        kPlayerTitleOptions.any((o) => o.id == prefs.getString(_titleStyleKey))
        ? prefs.getString(_titleStyleKey)!
        : 'classic';
    _progressStyle =
        kPlayerProgressOptions.any((o) => o.id == prefs.getString(_progressKey))
        ? prefs.getString(_progressKey)!
        : 'slider';
    try {
      _playerOrder = PlayerButtons.normalize(prefs.getStringList(_playerKey));
    } catch (_) {
      // A legacy/corrupt value under the old key must never take the app
      // down at boot — fall back to the default button order.
      _playerOrder = PlayerButtons.normalize(null);
    }
    String flank(String? v, String fallback) =>
        PlayerButtons.catalog.any((b) => b.id == v) ? v! : fallback;
    _transportLeft = flank(prefs.getString(_flankLeftKey), 'shuffle');
    _transportRight = flank(prefs.getString(_flankRightKey), 'repeat');
    notifyListeners();
  }

  Future<void> setNavStyle(String v) async {
    _navStyle = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_navKey, v);
  }

  Future<void> setTitleStyle(String v) async {
    if (!kPlayerTitleOptions.any((o) => o.id == v)) return;
    _titleStyle = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_titleStyleKey, v);
  }

  Future<void> setProgressStyle(String v) async {
    if (!kPlayerProgressOptions.any((o) => o.id == v)) return;
    _progressStyle = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_progressKey, v);
  }

  Future<void> setPlayerOrder(List<String> order) async {
    _playerOrder = PlayerButtons.normalize(order);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_playerKey, _playerOrder);
  }

  /// Set a transport flank slot. Picking the id already in the other slot
  /// swaps them so the two slots never hold the same button.
  Future<void> setTransportSlot(bool left, String id) async {
    if (!PlayerButtons.catalog.any((b) => b.id == id)) return;
    if (left) {
      if (id == _transportRight) _transportRight = _transportLeft;
      _transportLeft = id;
    } else {
      if (id == _transportLeft) _transportLeft = _transportRight;
      _transportRight = id;
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_flankLeftKey, _transportLeft);
    await prefs.setString(_flankRightKey, _transportRight);
  }

  /// Factory defaults for buttons + flank slots.
  Future<void> resetPlayerLayout() async {
    _playerOrder = List.of(PlayerButtons.defaultOrder);
    _transportLeft = 'shuffle';
    _transportRight = 'repeat';
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_playerKey, _playerOrder);
    await prefs.setString(_flankLeftKey, _transportLeft);
    await prefs.setString(_flankRightKey, _transportRight);
  }
}

/// Dynamic palette bridge — reads the active theme, so existing `Spots.*`
/// call sites re-color at runtime when the user switches themes.
class Spots {
  static Color get green => ThemeStore.instance.current.accent;
  static Color get base => ThemeStore.instance.current.base;
  static Color get elevated => ThemeStore.instance.current.elevated;
  static Color get subtle => ThemeStore.instance.current.subtle;

  static ThemeData dark() => ThemeStore.instance.current.build();

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
