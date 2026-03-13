import 'dart:io';
import 'dart:math';

/// Provides lists of User-Agent strings for rotation during scanning.
///
/// Three modes:
///   1. [UserAgentPool.single]  — one fixed UA string
///   2. [UserAgentPool.random]  — rotate from the built-in pool randomly
///   3. [UserAgentPool.fromFile] — load custom UA strings from a file
class UserAgentPool {
  final List<String> _agents;
  final bool _randomize;
  final _rng = Random.secure();
  int _idx = 0;

  UserAgentPool._(this._agents, this._randomize);

  factory UserAgentPool.single(String ua) => UserAgentPool._([ua], false);

  factory UserAgentPool.sequential() =>
      UserAgentPool._(List.of(_kBuiltinAgents), false);

  factory UserAgentPool.random() =>
      UserAgentPool._(List.of(_kBuiltinAgents)..shuffle(), true);

  static Future<UserAgentPool> fromFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('User-agent file not found: $path');
    }
    final lines = (await file.readAsLines())
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();
    if (lines.isEmpty) throw Exception('User-agent file is empty');
    return UserAgentPool._(lines, false);
  }

  String get next {
    if (_randomize) {
      return _agents[_rng.nextInt(_agents.length)];
    }
    return _agents[_idx++ % _agents.length];
  }

  List<String> get all => List.unmodifiable(_agents);
}

/// A diverse pool of real-world User-Agent strings spanning browsers,
/// crawlers, and mobile clients — good enough to evade basic UA filtering.
const _kBuiltinAgents = [
  // Chrome on Windows
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  // Firefox on Linux
  'Mozilla/5.0 (X11; Linux x86_64; rv:125.0) Gecko/20100101 Firefox/125.0',
  // Safari on macOS
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15',
  // Edge on Windows
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0',
  // Chrome on Android
  'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.6367.82 Mobile Safari/537.36',
  // Googlebot
  'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)',
  // curl
  'curl/8.7.1',
  // Python requests
  'python-requests/2.31.0',
  // Go http client
  'Go-http-client/1.1',
  // Wget
  'Wget/1.21.4',
  // Chrome on iOS
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/124.0.6367.88 Mobile/15E148 Safari/604.1',
  // DartBuster self-identification
  'DartBuster/0.1.0',
];
