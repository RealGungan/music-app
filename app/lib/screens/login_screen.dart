import 'package:flutter/material.dart';

import '../api_client.dart';
import '../auth_store.dart';
import '../lang.dart';
import '../lang.dart';
import '../lang.dart';
import '../lang.dart';

/// Login / register gate (multi-user). Shown instead of the library tabs
/// whenever there is no valid session: first run, after logout, or when
/// the saved token is rejected (401). On success the session is persisted
/// (AuthStore) and the caller rebuilds into the main shell.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.api, required this.onDone});
  final ApiClient api;
  final VoidCallback onDone;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _verify = TextEditingController();
  final _invite = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  bool _registerMode = false;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _verify.dispose();
    _invite.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _user.text.trim();
    final password = _pass.text;
    if (username.isEmpty) {
      setState(() => _error = tr('Enter a username.'));
      return;
    }
    if (password.isEmpty) {
      setState(() => _error = tr('Enter your password.'));
      return;
    }
    if (_registerMode) {
      if (_verify.text != password) {
        setState(() => _error = tr('Passwords do not match.'));
        return;
      }
      if (password.length < 6) {
        setState(() => _error = tr('Password too short (min 6).'));
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final store = AuthStore.instance;
      final s = _registerMode
          ? await widget.api.register(username, password, _verify.text,
              deviceId: store.deviceId,
              deviceName: store.deviceName,
              invite: _invite.text.trim())
          : await widget.api.login(username, password,
              deviceId: store.deviceId, deviceName: store.deviceName);
      widget.api.authToken = s.token;
      await store.saveSession(s.token, s.username);
      widget.onDone();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.statusCode == 409
            ? tr('That name is taken — pick another username.')
            : e.statusCode == 401
                ? tr('Invalid username or password.')
                : e.message.isNotEmpty
                    ? e.message
                    : tr('Could not reach the server.');
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = tr('Could not reach the server.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('gungan.fm'),
        actions: [
          // Pre-login language picker: first-run users choose before
          // reading anything else.
          ListenableBuilder(
            listenable: LocaleStore.instance,
            builder: (_, __) => TextButton(
              onPressed: () => LocaleStore.instance.setLang(
                  LocaleStore.instance.isSpanish ? 'en' : 'es'),
              child: Text(
                LocaleStore.instance.isSpanish ? 'EN' : 'ES',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                _registerMode ? tr('Create account') : 'KLK quién tu ere',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                _registerMode
                    ? tr('Pick a username and password. Your playlists stay private to you.')
                    : tr('Sign in to reach your music and private playlists.'),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _user,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: tr('Username'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pass,
                obscureText: _obscure,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _busy ? null : _submit(),
                decoration: InputDecoration(
                  labelText: tr('Password'),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    onPressed: () =>
                        setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              if (_registerMode) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _verify,
                  obscureText: _obscure,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: tr('Repeat password'),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _invite,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _busy ? null : _submit(),
                  decoration: InputDecoration(
                    labelText: tr('Invite code (ask the owner)'),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(_registerMode
                        ? tr('Create account')
                        : tr('Sign in')),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _registerMode = !_registerMode;
                          _error = null;
                        }),
                child: Text(_registerMode
                    ? tr('Already have an account? Sign in')
                    : tr('No account yet? Create one')),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
