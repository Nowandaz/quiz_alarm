/// Sign in or create an account (email and password).
library;

import 'package:material_ui/material_ui.dart';

import '../services/account.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _creating = false;
  bool _busy = false;
  bool _showPassword = false;
  String? _error;
  String? _notice;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
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
    if (!mounted) return;

    if (error == null && !needsConfirmation) {
      Navigator.pop(context);
      return;
    }
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
    return Scaffold(
      appBar: AppBar(title: Text(_creating ? 'Create account' : 'Sign in')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          Text(
            _creating
                ? 'An account turns on the AI: new questions written for '
                      'you and a tutor that explains your answers.'
                : 'Sign in to use the AI on this phone.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
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
        ],
      ),
    );
  }
}
