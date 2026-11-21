/// The sign-in screen: create an account or sign in, with email and
/// password or with Google. An account is required, so this screen cannot
/// be dismissed; it closes by itself once the user is signed in.
library;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../services/account.dart';
import '../services/system_bridge.dart';
import '../widgets/app_widgets.dart';
import '../widgets/brand.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();
  bool _creating = true;
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
    _passwordFocus.dispose();
    super.dispose();
  }

  /// Signed in (by either route): this screen is done.
  void _onAccount() {
    if (!Account.instance.isSignedIn || !mounted) return;
    // Remove THIS screen. A plain pop would close whatever is on top of
    // it, which could be the quiz of an alarm that started ringing.
    final route = ModalRoute.of(context);
    if (route == null) return;
    if (route.isCurrent) {
      Navigator.pop(context);
    } else {
      Navigator.removeRoute(context, route);
    }
  }

  void _onGoogleResult() {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = Account.instance.oauthError.value;
    });
  }

  void _setMode(bool creating) {
    if (_busy || creating == _creating) return;
    setState(() {
      _creating = creating;
      _error = null;
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

  /// "Forgot password?": emails a link for setting a new one.
  Future<void> _forgotPassword() async {
    final email = _email.text.trim();
    if (!email.contains('@') || email.length < 5) {
      setState(() {
        _error = 'Enter your email address first.';
        _notice = null;
      });
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    final error = await Account.instance.resetPassword(email);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
      if (error == null) {
        _notice =
            'We emailed you a link to set a new password. Open it, then '
            'come back and sign in.';
      }
    });
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
    final scheme = theme.colorScheme;
    final muted = scheme.onSurface.withValues(alpha: 0.62);

    return PopScope(
      canPop: false, // an account is required
      child: Scaffold(
        body: AppBackground(
          child: Stack(
            children: [
              const Positioned.fill(child: BrandDial()),
              SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(22, 28, 22, 28),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Brand
                          Row(
                            children: [
                              const BrandMark(size: 60),
                              const SizedBox(width: 14),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'BrainWake',
                                    style: theme.textTheme.headlineSmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: -0.5,
                                          height: 1.1,
                                        ),
                                  ),
                                  Text(
                                    'THE QUIZ ALARM',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: scheme.primary,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 2.4,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 36),
                          Text(
                            _creating ? 'Wake up\nsmarter.' : 'Welcome\nback.',
                            style: theme.textTheme.displaySmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              height: 1.05,
                              letterSpacing: -1,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _creating
                                ? 'The alarm that only stops when you answer '
                                      'revision questions. Create your account '
                                      'to begin.'
                                : 'Sign in to pick up your alarms, progress and '
                                      'questions where you left them.',
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: muted,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 16),
                          const Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              Pill(
                                'Answer to dismiss',
                                icon: Icons.quiz_rounded,
                              ),
                              Pill(
                                'AI tutor',
                                icon: Icons.auto_awesome_rounded,
                              ),
                              Pill(
                                'Track progress',
                                icon: Icons.insights_rounded,
                              ),
                            ],
                          ),
                          const SizedBox(height: 22),

                          GlossCard(
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _ModeSwitch(
                                  creating: _creating,
                                  onChanged: _setMode,
                                ),
                                const SizedBox(height: 16),
                                TextField(
                                  controller: _email,
                                  keyboardType: TextInputType.emailAddress,
                                  autocorrect: false,
                                  autofillHints: const [AutofillHints.email],
                                  textInputAction: TextInputAction.next,
                                  onSubmitted: (_) =>
                                      _passwordFocus.requestFocus(),
                                  decoration: const InputDecoration(
                                    labelText: 'Email',
                                    prefixIcon: Icon(
                                      Icons.mail_outline_rounded,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: _password,
                                  focusNode: _passwordFocus,
                                  obscureText: !_showPassword,
                                  autofillHints: [
                                    _creating
                                        ? AutofillHints.newPassword
                                        : AutofillHints.password,
                                  ],
                                  onSubmitted: (_) => _busy ? null : _submit(),
                                  decoration: InputDecoration(
                                    labelText: 'Password',
                                    helperText: _creating
                                        ? 'At least 6 characters.'
                                        : null,
                                    prefixIcon: const Icon(
                                      Icons.lock_outline_rounded,
                                    ),
                                    suffixIcon: IconButton(
                                      tooltip: _showPassword
                                          ? 'Hide password'
                                          : 'Show password',
                                      icon: Icon(
                                        _showPassword
                                            ? Icons.visibility_off_rounded
                                            : Icons.visibility_rounded,
                                      ),
                                      onPressed: () => setState(
                                        () => _showPassword = !_showPassword,
                                      ),
                                    ),
                                  ),
                                ),
                                if (!_creating)
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton(
                                      onPressed: _busy ? null : _forgotPassword,
                                      child: const Text('Forgot password?'),
                                    ),
                                  ),
                                if (_error != null) ...[
                                  const SizedBox(height: 12),
                                  _Message(_error!, color: scheme.error),
                                ],
                                if (_notice != null) ...[
                                  const SizedBox(height: 12),
                                  _Message(_notice!, color: scheme.primary),
                                ],
                                const SizedBox(height: 16),
                                PrimaryButton(
                                  onPressed: _busy ? null : _submit,
                                  icon: _busy
                                      ? null
                                      : Icons.arrow_forward_rounded,
                                  label: _busy
                                      ? 'Please wait...'
                                      : _creating
                                      ? 'Create account'
                                      : 'Sign in',
                                ),
                              ],
                            ),
                          ),

                          if (_googleAvailable) ...[
                            const SizedBox(height: 18),
                            Row(
                              children: [
                                const Expanded(child: Divider()),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  child: Text(
                                    'or',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: muted,
                                    ),
                                  ),
                                ),
                                const Expanded(child: Divider()),
                              ],
                            ),
                            const SizedBox(height: 18),
                            SizedBox(
                              height: 56,
                              child: OutlinedButton(
                                onPressed: _busy ? null : _google,
                                style: OutlinedButton.styleFrom(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Container(
                                      width: 34,
                                      height: 34,
                                      alignment: Alignment.center,
                                      decoration: const BoxDecoration(
                                        color: Colors.white,
                                        shape: BoxShape.circle,
                                      ),
                                      child: const GoogleLogo(size: 20),
                                    ),
                                    const SizedBox(width: 12),
                                    Text(
                                      'Continue with Google',
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 22),
                          Text(
                            'Your alarms keep ringing without internet. The '
                            'account keeps your progress safe and brings new '
                            'questions.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "Create account | Sign in" switch at the top of the card.
class _ModeSwitch extends StatelessWidget {
  final bool creating;
  final ValueChanged<bool> onChanged;
  const _ModeSwitch({required this.creating, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget side(String label, bool value) {
      final on = creating == value;
      return Expanded(
        child: Semantics(
          button: true,
          selected: on,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onChanged(value),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? scheme.onSurface : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: on
                      ? scheme.surface
                      : scheme.onSurface.withValues(alpha: 0.62),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [side('Create account', true), side('Sign in', false)],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final String text;
  final Color color;
  const _Message(this.text, {required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Text(text, style: TextStyle(color: color, height: 1.35)),
  );
}
