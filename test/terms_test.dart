// Creating an account needs the terms agreed to; signing in does not.
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quiz_alarm/screens/account_screen.dart';
import 'package:quiz_alarm/services/account.dart';
import 'package:quiz_alarm/services/server_config.dart';

import 'helpers.dart';

const _system = MethodChannel('brainwake/system');
const _needTerms = 'Please agree to the terms to create an account.';

void main() {
  late List<http.Request> requests;
  late List<String> opened;

  Future<void> show(WidgetTester tester, {bool welcome = false}) async {
    tester.view.physicalSize = const Size(1600, 4200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.runAsync(resetApp);
    requests = [];
    opened = [];
    Account.httpClient = MockClient((request) async {
      requests.add(request);
      return http.Response('{"id":"user-1","email":"me@example.com"}', 200);
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_system, (
      call,
    ) async {
      if (call.method == 'openUrl') {
        opened.add((call.arguments as Map)['url'] as String);
        return true;
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _system,
        null,
      ),
    );
    await tester.pumpWidget(MaterialApp(home: AccountScreen(welcome: welcome)));
    await tester.pump();
  }

  Future<void> fill(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).at(0), 'me@example.com');
    await tester.enterText(find.byType(TextField).at(1), 'secret1');
  }

  /// Taps the button of the form (not the tab of the same name).
  Future<void> submit(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).last);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }

  /// Taps the link called [name] inside the sentence that starts with
  /// [start].
  void tapLink(WidgetTester tester, String start, String name) {
    final text = tester.widget<RichText>(
      find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText().startsWith(start),
      ),
    );
    InlineSpan? link;
    text.text.visitChildren((span) {
      if (span is TextSpan && span.text == name) link = span;
      return link == null;
    });
    ((link! as TextSpan).recognizer! as TapGestureRecognizer).onTap!();
  }

  testWidgets('Create account: unticked is refused, nothing is sent', (
    tester,
  ) async {
    await show(tester);
    expect(
      find.text(
        'I agree to the Terms and Conditions and the Privacy Policy.',
        findRichText: true,
      ),
      findsOneWidget,
    );
    await fill(tester);
    await submit(tester, 'Create account');
    expect(find.text(_needTerms), findsOneWidget);
    expect(requests, isEmpty);
  });

  testWidgets('ticked: the account is made and the agreement recorded', (
    tester,
  ) async {
    await show(tester);
    await fill(tester);
    await submit(tester, 'Create account');
    expect(find.text(_needTerms), findsOneWidget);

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(find.text(_needTerms), findsNothing);
    final before = DateTime.now().toUtc();
    await submit(tester, 'Create account');

    final request = requests.single;
    expect(request.url.path, '/auth/v1/signup');
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    expect(body['email'], 'me@example.com');
    final data = body['data'] as Map<String, dynamic>;
    expect(data['terms_version'], '2026-11-22');
    expect(data['terms_version'], Account.termsVersion);
    final at = data['terms_accepted_at'] as String;
    expect(at, endsWith('Z'));
    expect(DateTime.parse(at).difference(before).inSeconds.abs(), lessThan(60));
    expect(find.textContaining('Account created'), findsOneWidget);
  });

  testWidgets('the two names open the legal pages', (tester) async {
    await show(tester);
    tapLink(tester, 'I agree', 'Terms and Conditions');
    tapLink(tester, 'I agree', 'Privacy Policy');
    await tester.pump();
    expect(opened, [ServerConfig.termsUrl, ServerConfig.privacyUrl]);
  });

  testWidgets('Google is held back on the Create account tab only', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.text('Continue with Google'));
    await tester.pump();
    expect(find.text(_needTerms), findsOneWidget);
    expect(opened, isEmpty);
    // No "by continuing" line here: the box says it.
    expect(
      find.textContaining('By continuing you agree', findRichText: true),
      findsNothing,
    );

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.text('Continue with Google'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(find.text(_needTerms), findsNothing);
    expect(opened.single, contains('/auth/v1/authorize'));
    expect(requests, isEmpty);
  });

  testWidgets('Sign in: no box; Google goes ahead under a short line', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
    expect(
      find.text(
        'By continuing you agree to the Terms and Conditions and Privacy '
        'Policy.',
        findRichText: true,
      ),
      findsOneWidget,
    );
    tapLink(tester, 'By continuing', 'Privacy Policy');
    tapLink(tester, 'By continuing', 'Terms and Conditions');
    await tester.pump();
    expect(opened, [ServerConfig.privacyUrl, ServerConfig.termsUrl]);
    opened.clear();

    await tester.tap(find.text('Continue with Google'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(find.text(_needTerms), findsNothing);
    expect(opened.single, contains('/auth/v1/authorize'));

    // The email form signs in without any box either.
    await fill(tester);
    await submit(tester, 'Sign in');
    expect(requests.single.url.path, '/auth/v1/token');
    expect(find.text(_needTerms), findsNothing);
  });

  testWidgets('"Continue without an account" is not held back', (tester) async {
    await show(tester, welcome: true);
    await tester.tap(find.text('Continue without an account'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(find.text(_needTerms), findsNothing);
  });
}
