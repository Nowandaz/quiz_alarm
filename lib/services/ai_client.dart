/// Asks the app's server to do the AI work: write questions, explain an
/// answer, mark a typed answer. The server holds the AI keys and checks the
/// user's daily allowance; this file only sends the signed-in request.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'account.dart';
import 'server_config.dart';

class AiException implements Exception {
  final String message;
  const AiException(this.message);
  @override
  String toString() => message;
}

/// How much AI the user may still use today.
class AiAllowance {
  final bool enabled;
  final String plan;
  final int limit;
  final int used;
  const AiAllowance({
    required this.enabled,
    required this.plan,
    required this.limit,
    required this.used,
  });
  int get remaining => limit > used ? limit - used : 0;
}

class AiClient {
  /// Tests replace this with a fake.
  @visibleForTesting
  static http.Client httpClient = http.Client();

  /// AI features need an account.
  static bool get available => Account.instance.isSignedIn;

  static const String signInHint = 'Sign in (Settings) to use AI features.';

  static Future<Map<String, dynamic>> _call(
    String method,
    String path, {
    Map<String, dynamic>? body,
    required Duration timeout,
  }) async {
    final token = await Account.instance.accessToken();
    if (token == null) {
      throw AiException(
        Account.instance.isSignedIn
            ? 'Could not reach the server. Check your connection.'
            : signInHint,
      );
    }
    final uri = Uri.parse('${ServerConfig.apiUrl}$path');
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };

    final http.Response res;
    try {
      res =
          await (method == 'GET'
                  ? httpClient.get(uri, headers: headers)
                  : httpClient.post(
                      uri,
                      headers: headers,
                      body: jsonEncode(body),
                    ))
              .timeout(timeout);
    } on TimeoutException {
      throw const AiException('The AI took too long to answer. Try again.');
    } catch (e) {
      throw const AiException(
        'Could not reach the server. Check your connection.',
      );
    }

    dynamic data;
    try {
      data = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {}
    if (res.statusCode != 200) {
      final detail = data is Map ? data['detail'] : null;
      throw AiException(
        detail is String && detail.isNotEmpty
            ? detail
            : 'The server answered ${res.statusCode}. Try again later.',
      );
    }
    if (data is! Map<String, dynamic>) {
      throw const AiException('The server sent an unreadable reply.');
    }
    return data;
  }

  /// New questions on [subject], as raw maps (type, text, options, answer,
  /// alt_answers, explanation). [avoid] lists question texts already owned.
  static Future<List<dynamic>> generate(
    String subject, {
    required int count,
    List<String> avoid = const [],
    String objectives = '',
  }) async {
    final data = await _call(
      'POST',
      '/v1/ai/generate',
      body: {
        'subject': subject,
        'count': count.clamp(1, 10),
        // What the user said the topic should cover, if anything.
        if (objectives.trim().isNotEmpty)
          'objectives': objectives.trim().length > 900
              ? objectives.trim().substring(0, 900)
              : objectives.trim(),
        'avoid': [
          for (final text in avoid.take(40))
            text.length > 1900 ? text.substring(0, 1900) : text,
        ],
      },
      timeout: const Duration(seconds: 150),
    );
    final questions = data['questions'];
    return questions is List ? questions : const [];
  }

  /// The tutor's reply: {correct, feedback, explanation}.
  static Future<Map<String, dynamic>> feedback({
    required String question,
    required List<String> options,
    required String correctAnswer,
    required String explanation,
    required String userAnswer,
    bool? knownVerdict,
  }) {
    String cut(String s, int max) => s.length > max ? s.substring(0, max) : s;
    return _call(
      'POST',
      '/v1/ai/feedback',
      body: {
        'question': cut(question, 1900),
        'options': [for (final o in options.take(8)) cut(o, 290)],
        'correct_answer': cut(correctAnswer, 290),
        'explanation': cut(explanation, 1900),
        'user_answer': cut(userAnswer, 290),
        'known_verdict': knownVerdict,
      },
      timeout: const Duration(seconds: 60),
    );
  }

  /// Whether a typed answer is right. Kept short: it runs while an alarm
  /// is ringing, so the caller falls back to its own matching on failure.
  static Future<bool> grade({
    required String question,
    required String correctAnswer,
    required String userAnswer,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    String cut(String s, int max) => s.length > max ? s.substring(0, max) : s;
    final data = await _call(
      'POST',
      '/v1/ai/grade',
      body: {
        'question': cut(question, 1900),
        'correct_answer': cut(correctAnswer, 290),
        'user_answer': cut(userAnswer, 290),
      },
      timeout: timeout,
    );
    if (data['correct'] is! bool) {
      throw const AiException('The server sent an unreadable reply.');
    }
    return data['correct'] as bool;
  }

  static Future<AiAllowance> allowance() async {
    final data = await _call(
      'GET',
      '/v1/ai/status',
      timeout: const Duration(seconds: 15),
    );
    return AiAllowance(
      enabled: data['enabled'] != false,
      plan: '${data['plan'] ?? 'free'}',
      limit: (data['limit'] as num?)?.toInt() ?? 0,
      used: (data['used'] as num?)?.toInt() ?? 0,
    );
  }
}
