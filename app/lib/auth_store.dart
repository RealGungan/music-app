import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Session state for multi-user login. Mirrors the ThemeStore/UiStore
/// shape: a ChangeNotifier singleton the MaterialApp listens to for the
/// login gate. The session token lives in SharedPreferences, so the
/// device remembers the login until an explicit logout — credentials are
/// entered once per device, never stored on it.
class AuthStore extends ChangeNotifier {
  AuthStore._();
  static final AuthStore instance = AuthStore._();

  static const _tokKey = 'auth.session_token';
  static const _userKey = 'auth.username';
  static const _devKey = 'auth.device_id';

  String? token;
  String? username;
  String deviceId = '';

  bool get loggedIn => token != null && token!.isNotEmpty;

  /// Developer/owner: internal tools (integrity checker, diagnostics,
  /// check-song, replace) show only for this login. Case-insensitive —
  /// the server treats Bob == bob everywhere.
  bool get isOwner => (username ?? '').toLowerCase() == 'realgungan';

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final t = prefs.getString(_tokKey);
    token = (t != null && t.isNotEmpty) ? t : null;
    final u = prefs.getString(_userKey);
    username = (u != null && u.isNotEmpty) ? u : null;
    if (token == null) username = null;
    deviceId = prefs.getString(_devKey) ?? '';
    if (deviceId.isEmpty) {
      final r = Random.secure();
      deviceId = List.generate(16, (_) => r.nextInt(256))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      await prefs.setString(_devKey, deviceId);
    }
  }

  /// Human-readable device label sent on login/register (server records
  /// it per session so the user can tell devices apart).
  String get deviceName {
    try {
      return Platform.operatingSystem;
    } catch (_) {
      return 'app';
    }
  }

  Future<void> saveSession(String tok, String user) async {
    final prefs = await SharedPreferences.getInstance();
    token = tok;
    username = user;
    await prefs.setString(_tokKey, tok);
    await prefs.setString(_userKey, user);
    notifyListeners();
  }

  /// Drop the local session (idempotent — only notifies on actual change,
  /// so 401 storms can't loop the login gate).
  Future<void> expire() async {
    if (!loggedIn) return;
    final prefs = await SharedPreferences.getInstance();
    token = null;
    username = null;
    await prefs.remove(_tokKey);
    await prefs.remove(_userKey);
    notifyListeners();
  }
}
