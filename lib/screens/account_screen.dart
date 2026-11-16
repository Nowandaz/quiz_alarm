/// Sign in or create an account: email and password, or Google.
/// With [welcome] it is the first screen of a new install and can be
/// skipped; the app's alarms work without an account.
library;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../services/account.dart';
import '../services/system_bridge.dart';

class AccountScreen extends StatefulWidget {
  final bool welcome;
  const AccountScreen({super.key, this.welcome = false});
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  late bool _creating = widget.welcome;
  bool _busy = false;
  bool _showPassword = false;
  String? _error;
  String? _notice;

  // Google sign-in goes through the phone's browser.
  bool get _googleAvailable =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    Account.instance.addListener(_onAccount);
    Account.instance.oauthError.value = null;
    Account.instance.oauthError.addListener(_onGoogleResult);
  }

  @override
  void dispose() {
    Account.instance.removeListener(_onAccount);
    Account.instance.oauthError.removeListener(_onGoogleResult);
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Signed in (by either route): this screen is done.
  void _onAccount() {
    if (Account.instance.isSignedIn && mounted) Navigator.pop(context);
  }

  void _onGoogleResult() {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = Account.instance.oauthError.value;
    });
  }

  Future<void> _google() async {
    setState(() {
      _error = null;
      _notice = null;
    });
    final opened = await SystemBridge.openUrl(
      await Account.instance.googleSignInUrl(),
    );
    if (!opened && mounted) {
      setState(() => _error = 'Could not open the browser for Google sign-in.');
    }
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (!email.contains('@') || email.length < 5) {
      setState(() => _error = 'Enter your email address.');
      return;
    }
    if (password.length < 6) {
      setState(() => _error = 'The password needs at least 6 characters.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });

    String? error;
    var needsConfirmation = false;
    if (_creating) {
      final result = await Account.instance.signUp(email, password);
      error = result.error;
      needsConfirmation = result.needsConfirmation;
    } else {
      error = await Account.instance.signIn(email, password);
    }
    // On success _onAccount has already closed this screen.
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
      if (needsConfirmation) {
        _creating = false;
        _notice =
            'Account created. Open the link we emailed to $email, then come '
            'back here and sign in.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = widget.welcome
        ? 'Welcome to BrainWake'
        : _creating
        ? 'Create account'
        : 'Sign in';
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.welcome,
        title: Text(title),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          Text(
            widget.welcome
                ? 'The alarm you can only stop by answering revision '
                      'questions. ${_creating ? 'Create an account' : 'Sign in'} '
                      'to keep your progress safe and to get new questions '
                      'and explanations from the AI.'
                : _creating
                ? 'An account keeps your progress safe and turns on the AI: '
                      'new questions written for you and a tutor that '
                      'explains your answers.'
                : 'Sign in to sync your progress and use the AI on this phone.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          if (_googleAvailable) ...[
            OutlinedButton.icon(
              onPressed: _busy ? null : _google,
              icon: const Icon(Icons.public_rounded),
              label: const Text('Continue with Google'),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('or', style: theme.textTheme.bodySmall),
                ),
                const Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 16),
          ],
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            autofillHints: const [AutofillHints.email],
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Email'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: !_showPassword,
            autofillHints: [
              _creating ? AutofillHints.newPassword : AutofillHints.password,
            ],
            onSubmitted: (_) => _busy ? null : _submit(),
            decoration: InputDecoration(
              labelText: 'Password',
              helperText: _creating ? 'At least 6 characters.' : null,
              suffixIcon: IconButton(
                tooltip: _showPassword ? 'Hide password' : 'Show password',
                icon: Icon(
                  _showPassword
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                ),
                onPressed: () => setState(() => _showPassword = !_showPassword),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          if (_notice != null) ...[const SizedBox(height: 12), Text(_notice!)],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: Text(
              _busy
                  ? 'Please wait...'
                  : _creating
                  ? 'Create account'
                  : 'Sign in',
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _creating = !_creating;
                    _error = null;
                  }),
            child: Text(
              _creating
                  ? 'I already have an account'
                  : 'New here? Create an account',
            ),
          ),
          if (widget.welcome)
            TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('Skip for now'),
            ),
        ],
      ),
    );
  }
}
