import 'dart:io';
import 'dart:async';

import 'package:args/args.dart';

import '../lib/src/core/http_client.dart';
import '../lib/src/core/engine.dart';
import '../lib/src/core/module.dart';
import '../lib/src/output/formatter.dart';
import '../lib/src/utils/wordlist.dart';
import '../lib/src/utils/user_agents.dart';
import '../lib/src/modules/dir_module.dart';
import '../lib/src/modules/dns_module.dart';
import '../lib/src/modules/vhost_module.dart';
import '../lib/src/modules/fuzz_module.dart';

// ── Module registration ────────────────────────────────────────────────────
// Add new modules here — no other file needs to change.

void _registerModules() {
  ModuleRegistry.register(DirModule());
  ModuleRegistry.register(DnsModule());
  ModuleRegistry.register(VhostModule());
  ModuleRegistry.register(FuzzModule());
}

// ── Entrypoint ─────────────────────────────────────────────────────────────

Future<void> main(List<String> args) async {
  _registerModules();

  final globalParser = _buildGlobalParser();

  if (args.isEmpty || args.contains('--help') || args.contains('-h')) {
    _printHelp(globalParser);
    exit(0);
  }

  // First positional arg is the mode/command name
  final mode = args.first;
  final module = ModuleRegistry.find(mode);
  if (module == null) {
    stderr.writeln('Unknown mode: "$mode"');
    stderr.writeln('Available modes: ${ModuleRegistry.all.map((m) => m.name).join(", ")}');
    exit(1);
  }

  // Re-parse with per-module flags merged in
  final parser = _buildGlobalParser();
  for (final flag in module.flags) {
    if (flag.isBool) {
      parser.addFlag(
        flag.name,
        abbr: flag.abbr.isEmpty ? null : flag.abbr,
        help: flag.help,
        defaultsTo: flag.defaultValue?.toLowerCase() == 'true',
        negatable: false,
      );
    } else {
      parser.addOption(
        flag.name,
        abbr: flag.abbr.isEmpty ? null : flag.abbr,
        help: flag.help,
        defaultsTo: flag.defaultValue,
      );
    }
  }

  ArgResults parsed;
  try {
    parsed = parser.parse(args.skip(1).toList());
  } on FormatException catch (e) {
    stderr.writeln('Argument error: ${e.message}');
    exit(1);
  }

  // ── Validate required flags ──────────────────────────────────────────────

  final target = parsed['url'] as String?;
  final wordlistPath = parsed['wordlist'] as String?;

  if (target == null || target.isEmpty) {
    stderr.writeln('Missing required flag: --url (-u)');
    exit(1);
  }
  if (wordlistPath == null || wordlistPath.isEmpty) {
    stderr.writeln('Missing required flag: --wordlist (-w)');
    exit(1);
  }

  // ── Output formatter ─────────────────────────────────────────────────────

  final outputFormat = parsed['output-format'] as String;
  final noColor = parsed['no-color'] as bool;
  final quiet = parsed['quiet'] as bool;

  final OutputFormatter formatter = switch (outputFormat) {
    'json' => JsonFormatter(),
    'csv' => CsvFormatter(),
    _ => TerminalFormatter(noColor: noColor, quiet: quiet),
  };

  // ── User agents ──────────────────────────────────────────────────────────

  final randomUA = parsed['random-agent'] as bool;
  final uaFile = parsed['agent-file'] as String?;
  final customUA = parsed['user-agent'] as String?;

  UserAgentPool uaPool;
  if (uaFile != null && uaFile.isNotEmpty) {
    uaPool = await UserAgentPool.fromFile(uaFile);
  } else if (randomUA) {
    uaPool = UserAgentPool.random();
  } else if (customUA != null && customUA.isNotEmpty) {
    uaPool = UserAgentPool.single(customUA);
  } else {
    uaPool = UserAgentPool.sequential();
  }

  // ── Extra headers ────────────────────────────────────────────────────────

  final rawHeaders = parsed['header'] as List<String>;
  final extraHeaders = <String, String>{};
  for (final h in rawHeaders) {
    final idx = h.indexOf(':');
    if (idx < 0) {
      formatter.warn('Ignoring malformed header: $h (missing colon)');
      continue;
    }
    extraHeaders[h.substring(0, idx).trim()] = h.substring(idx + 1).trim();
  }

  // ── Module config ────────────────────────────────────────────────────────

  final matchCodes = _parseIntList(parsed['match-codes'] as String);
  final filterCodes = _parseIntList(parsed['filter-codes'] as String);
  final filterLength = int.tryParse(parsed['filter-length'] as String? ?? '');
  final followRedirects = parsed['follow-redirects'] as bool;

  // Collect module-specific raw flags
  final rawFlags = <String, String>{};
  for (final flag in module.flags) {
    final val = parsed[flag.name];
    if (val != null) rawFlags[flag.name] = val.toString();
  }

  final config = ModuleConfig(
    target: target,
    matchStatusCodes: matchCodes,
    filterStatusCodes: filterCodes,
    filterContentLength: filterLength,
    followRedirects: followRedirects,
    extraHeaders: extraHeaders,
    rawFlags: rawFlags,
  );

  try {
    module.initialize(config);
  } catch (e) {
    formatter.error('Module initialization failed: $e');
    exit(1);
  }

  // ── Wildcard detection (DNS only) ────────────────────────────────────────
  if (module is DnsModule) {
    await (module as DnsModule).detectWildcard(formatter.warn);
  }

  // ── Baseline (VHost only) ────────────────────────────────────────────────

  // ── HTTP client ──────────────────────────────────────────────────────────

  final threads = int.tryParse(parsed['threads'] as String) ?? 10;
  final timeoutSecs = int.tryParse(parsed['timeout'] as String) ?? 10;
  final insecure = parsed['insecure'] as bool;
  final delayMs = int.tryParse(parsed['delay'] as String? ?? '0') ?? 0;

  final client = BusterHttpClient(
    timeout: Duration(seconds: timeoutSecs),
    followRedirects: followRedirects,
    insecure: insecure,
    userAgents: uaPool.all,
  );

  if (module is VhostModule) {
    await (module as VhostModule).establishBaseline(client);
  }

  // ── Wordlist ─────────────────────────────────────────────────────────────

  List<String> words;
  try {
    words = await Wordlist.load(wordlistPath);
  } on WordlistException catch (e) {
    formatter.error(e.toString());
    exit(1);
  }

  // ── SIGINT graceful shutdown ─────────────────────────────────────────────

  final cancelToken = CancelToken();
  ProcessSignal.sigint.watch().listen((_) {
    formatter.warn('Caught SIGINT — stopping scan gracefully…');
    cancelToken.cancel();
  });

  // ── Run ──────────────────────────────────────────────────────────────────

  formatter.start(target, mode, words.length);

  final engine = ScanEngine(
    client: client,
    threads: threads,
    requestDelay: delayMs > 0 ? Duration(milliseconds: delayMs) : null,
    verbose: parsed['verbose'] as bool,
  );

  final ctx = ModuleContext(
    client: client,
    formatter: formatter,
    config: config,
    cancelToken: cancelToken,
  );

  final summary = await engine.run(
    words: words,
    probe: (word) => module.probe(word, ctx),
    onResult: (_) {}, // modules call formatter directly for richer labeling
    onProgress: formatter.progress,
    cancel: cancelToken,
  );

  formatter.summary(summary);
  formatter.close();
  client.close();
  exit(0);
}

// ── CLI parser ─────────────────────────────────────────────────────────────

ArgParser _buildGlobalParser() {
  return ArgParser(allowTrailingOptions: true)
    ..addOption('url', abbr: 'u', help: 'Target URL or domain', mandatory: false)
    ..addOption('wordlist', abbr: 'w', help: 'Path to wordlist file')
    ..addOption('threads', abbr: 't', help: 'Number of concurrent threads', defaultsTo: '10')
    ..addOption('timeout', help: 'HTTP request timeout (seconds)', defaultsTo: '10')
    ..addOption('delay', help: 'Delay between requests in milliseconds', defaultsTo: '0')
    ..addOption('user-agent', abbr: 'a', help: 'Custom User-Agent string')
    ..addFlag('random-agent', help: 'Rotate random User-Agent per request', negatable: false)
    ..addOption('agent-file', help: 'File containing User-Agent strings to rotate')
    ..addMultiOption('header', abbr: 'H', help: 'Extra header (repeatable): "Name: Value"')
    ..addOption('match-codes', abbr: 's', help: 'Match these status codes (comma-separated)', defaultsTo: '200,204,301,302,307,401,403')
    ..addOption('filter-codes', abbr: 'b', help: 'Filter (exclude) these status codes', defaultsTo: '')
    ..addOption('filter-length', help: 'Filter responses by exact content length')
    ..addFlag('follow-redirects', abbr: 'r', help: 'Follow HTTP redirects', negatable: false)
    ..addFlag('insecure', abbr: 'k', help: 'Skip TLS certificate verification', negatable: false)
    ..addOption('output-format', abbr: 'o', help: 'Output format: terminal, json, csv', defaultsTo: 'terminal')
    ..addFlag('no-color', help: 'Disable ANSI color output', negatable: false)
    ..addFlag('quiet', abbr: 'q', help: 'Suppress progress output', negatable: false)
    ..addFlag('verbose', abbr: 'v', help: 'Show all probes (not just matches)', negatable: false);
}

void _printHelp(ArgParser parser) {
  print('''
DartBuster — web content discovery tool

Usage:
  dartbuster <mode> [flags]

Modes:
${ModuleRegistry.helpText()}
Global Flags:
${parser.usage}

Examples:
  dartbuster dir -u https://example.com -w /usr/share/wordlists/dirb/common.txt -x php,html -t 50
  dartbuster dns -d example.com -w subdomains.txt --show-ips
  dartbuster vhost -u http://10.10.10.10 -w vhosts.txt --domain htb.local
  dartbuster fuzz -u "https://example.com/api/FUZZ" -w endpoints.txt -s 200,201
''');
}

// ── Helpers ────────────────────────────────────────────────────────────────

List<int> _parseIntList(String raw) {
  if (raw.trim().isEmpty) return [];
  return raw
      .split(',')
      .map((s) => int.tryParse(s.trim()))
      .whereType<int>()
      .toList();
}
