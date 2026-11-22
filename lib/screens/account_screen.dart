/// The sign-in screen: create an account or sign in, with email and
/// password or with Google. It closes by itself once the user is signed
/// in.
///
/// As the welcome screen (the first thing a new user sees) it cannot be
/// dismissed, but offers "Continue without an account". Opened later
/// (from Settings, or from a "create an account" prompt) it has a back
/// button instead.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../services/account.dart';
import '../services/guest_mode.dart';
import '../services/server_config.dart';
import '../services/system_bridge.dart';
import '../widgets/app_widgets.dart';
import '../widgets/brand.dart';

class AccountScreen extends StatefulWidget {
  /// True for the welcome screen shown when the app opens.
  final bool welcome;
  const AccountScreen({super.key, this.welcome = false});
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

  /// The "I agree to the Terms..." box on the Create account tab.
  bool _agreed = false;
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
    Account.instance.recovering.addListener(_onRecovering);
  }

  @override
  void dispose() {
    Account.instance.removeListener(_onAccount);
    Account.instance.oauthError.removeListener(_onGoogleResult);
    Account.instance.recovering.removeListener(_onRecovering);
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

  /// "Continue without an account": remembered, so the app opens
  /// normally from now on.
  Future<void> _continueAsGuest() async {
    await GuestMode.choose();
    if (mounted) Navigator.pop(context);
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

  /// Creating an account (by email or with Google) needs the terms box
  /// ticked. False, with the reason shown, when it is not.
  bool _termsOk() {
    if (!_creating || _agreed) return true;
    setState(() {
      _error = 'Please agree to the terms to create an account.';
      _notice = null;
    });
    return false;
  }

  Future<void> _google() async {
    if (!_termsOk()) return;
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

  /// The emailed "set a new password" link was opened: this screen now
  /// asks for the new password only.
  bool get _recovering => Account.instance.recovering.value;

  void _onRecovering() {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _creating = false;
      _error = null;
      _notice = null;
      _password.clear();
    });
  }

  Future<void> _saveNewPassword() async {
    if (_password.text.length < 6) {
      setState(() => _error = 'The password needs at least 6 characters.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await Account.instance.setNewPassword(_password.text);
    // On success _onAccount has already closed this screen.
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
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
            'We emailed you a link. Open it on this phone: it brings you '
            'back here to choose a new password.';
      }
    });
  }

  Future<void> _submit() async {
    if (_recovering) return _saveNewPassword();
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
    if (!_termsOk()) return;
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
            'Account created. Open the link we emailed to $email on this '
            'phone and you are in.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurface.withValues(alpha: 0.62);

    return PopScope(
      // The welcome screen is left by signing in or by choosing to go on
      // without an account, not with the back button.
      canPop: !widget.welcome,
      child: Scaffold(
        body: AppBackground(
          child: Stack(
            children: [
              const Positioned.fill(child: BrandDial()),
              if (!widget.welcome)
                const SafeArea(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: EdgeInsets.all(4),
                      child: BackButton(),
                    ),
                  ),
                ),
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
                            _recovering
                                ? 'New\npassword.'
                                : _creating
                                ? 'Wake up\nsmarter.'
                                : 'Welcome\nback.',
                            style: theme.textTheme.displaySmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              height: 1.05,
                              letterSpacing: -1,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _recovering
                                ? 'Choose a new password for your account. '
                                      'You will be signed in straight away.'
                                : _creating
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
                          const SizedBox(height: 22),

                          GlossCard(
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (!_recovering) ...[
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
                                ],
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
                                    labelText: _recovering
                                        ? 'New password'
                                        : 'Password',
                                    helperText: _creating || _recovering
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
                                if (_creating && !_recovering) ...[
                                  const SizedBox(height: 10),
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      Checkbox(
                                        value: _agreed,
                                        onChanged: _busy
                                            ? null
                                            : (v) => setState(() {
                                                _agreed = v ?? false;
                                                if (_agreed) _error = null;
                                              }),
                                      ),
                                      const Expanded(
                                        child: _TermsText(
                                          before: 'I agree to the ',
                                          between: ' and the ',
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                                if (!_creating && !_recovering)
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
                                      : _recovering
                                      ? 'Save new password'
                                      : _creating
                                      ? 'Create account'
                                      : 'Sign in',
                                ),
                                if (_recovering)
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : Account.instance.cancelRecovery,
                                    child: const Text('Cancel'),
                                  ),
                              ],
                            ),
                          ),

                          if (_googleAvailable && !_recovering) ...[
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
                            if (!_creating) ...[
                              const SizedBox(height: 10),
                              _TermsText(
                                before: 'By continuing you agree to the ',
                                between: ' and ',
                                small: true,
                                color: muted,
                              ),
                            ],
                          ],
                          if (widget.welcome && !_recovering) ...[
                            const SizedBox(height: 14),
                            TextButton(
                              onPressed: _busy ? null : _continueAsGuest,
                              child: const Text('Continue without an account'),
                            ),
                            Text(
                              '3 alarms and two starter topics. You can '
                              'create an account any time.',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: muted,
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

/// A sentence naming the Terms and Conditions and the Privacy Policy,
/// each a link that opens the page in the browser.
class _TermsText extends StatefulWidget {
  final String before;
  final String between;
  final bool small;
  final Color? color;
  const _TermsText({
    required this.before,
    required this.between,
    this.small = false,
    this.color,
  });

  @override
  State<_TermsText> createState() => _TermsTextState();
}

class _TermsTextState extends State<_TermsText> {
  final _terms = TapGestureRecognizer()
    ..onTap = () => SystemBridge.openUrl(ServerConfig.termsUrl);
  final _privacy = TapGestureRecognizer()
    ..onTap = () => SystemBridge.openUrl(ServerConfig.privacyUrl);

  @override
  void dispose() {
    _terms.dispose();
    _privacy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = TextStyle(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.w600,
      decoration: TextDecoration.underline,
      decorationColor: theme.colorScheme.primary,
    );
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: widget.before),
          TextSpan(
            text: 'Terms and Conditions',
            style: link,
            recognizer: _terms,
          ),
          TextSpan(text: widget.between),
          TextSpan(text: 'Privacy Policy', style: link, recognizer: _privacy),
          const TextSpan(text: '.'),
        ],
      ),
      textAlign: widget.small ? TextAlign.center : TextAlign.start,
      style:
          (widget.small
                  ? theme.textTheme.bodySmall
                  : theme.textTheme.bodyMedium)
              ?.copyWith(color: widget.color, height: 1.35),
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
