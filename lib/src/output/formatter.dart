import 'dart:convert';
import 'dart:io';

import '../core/http_client.dart';
import '../core/engine.dart';

/// All output goes through this abstraction so that the scan engine and
/// modules never directly write to stdout/stderr/files. Swap the formatter
/// at startup without touching any business logic.
abstract class OutputFormatter {
  void start(String target, String mode, int wordlistSize);
  void result(ProbeResult result, {String? label});
  void progress(int done, int total);
  void info(String message);
  void warn(String message);
  void error(String message);
  void summary(ScanSummary summary);
  void close();
}

/// Renders rich ANSI terminal output: colored status codes, progress bar,
/// and structured result lines.
class TerminalFormatter implements OutputFormatter {
  final bool noColor;
  final bool quiet;
  final IOSink _out;
  final IOSink _err;
  int _lastProgressLen = 0;

  TerminalFormatter({
    this.noColor = false,
    this.quiet = false,
    IOSink? out,
    IOSink? err,
  })  : _out = out ?? stdout,
        _err = err ?? stderr;

  // ── ANSI helpers ──────────────────────────────────────────────────────────

  String _c(String text, String code) =>
      noColor ? text : '\x1B[${code}m$text\x1B[0m';

  String _green(String t) => _c(t, '32');
  String _yellow(String t) => _c(t, '33');
  String _red(String t) => _c(t, '31');
  String _cyan(String t) => _c(t, '36');
  String _gray(String t) => _c(t, '90');
  String _bold(String t) => _c(t, '1');
  String _magenta(String t) => _c(t, '35');

  String _colorStatus(int code) {
    final s = code.toString();
    if (code >= 200 && code < 300) return _green(s);
    if (code >= 300 && code < 400) return _cyan(s);
    if (code == 401 || code == 403) return _yellow(s);
    if (code >= 500) return _red(s);
    return _gray(s);
  }

  // ── Public API ────────────────────────────────────────────────────────────

  @override
  void start(String target, String mode, int wordlistSize) {
    _clearProgress();
    _out.writeln(_banner());
    _out.writeln('${_bold("Target:")}    $target');
    _out.writeln('${_bold("Mode:")}      $mode');
    _out.writeln('${_bold("Wordlist:")}  $wordlistSize words');
    _out.writeln(_gray('─' * 60));
  }

  @override
  void result(ProbeResult result, {String? label}) {
    _clearProgress();
    final code = _colorStatus(result.statusCode);
    final uri = result.uri.toString();
    final len = result.contentLength > 0
        ? _gray(' [${result.contentLength}]')
        : '';
    final redir = result.redirectLocation != null
        ? _cyan(' → ${result.redirectLocation}')
        : '';
    final lbl = label != null ? ' ${_magenta("($label)")}' : '';
    _out.writeln('$code  $uri$len$redir$lbl');
  }

  @override
  void progress(int done, int total) {
    if (quiet) return;
    final pct = (done / total * 100).toStringAsFixed(1);
    final bar = _buildBar(done, total, 20);
    final line = '\r${_gray("Progress:")} $bar $pct% ($done/$total)';
    _err.write(line);
    _lastProgressLen = line.length;
  }

  @override
  void info(String message) {
    _clearProgress();
    _out.writeln('${_cyan("[*]")} $message');
  }

  @override
  void warn(String message) {
    _clearProgress();
    _err.writeln('${_yellow("[!]")} $message');
  }

  @override
  void error(String message) {
    _clearProgress();
    _err.writeln('${_red("[E]")} $message');
  }

  @override
  void summary(ScanSummary s) {
    _clearProgress();
    _out.writeln(_gray('─' * 60));
    _out.writeln(_bold('Scan complete'));
    _out.writeln('  Probed:  ${s.totalProbed}');
    _out.writeln('  Found:   ${_green(s.found.toString())}');
    _out.writeln('  Errors:  ${s.errors > 0 ? _yellow(s.errors.toString()) : s.errors.toString()}');
    _out.writeln('  Time:    ${_fmtDuration(s.elapsed)}');
    _out.writeln('  Req/s:   ${s.requestsPerSecond.toStringAsFixed(1)}');
  }

  @override
  void close() {
    _clearProgress();
    _out.flush();
    _err.flush();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _clearProgress() {
    if (_lastProgressLen > 0) {
      _err.write('\r${' ' * _lastProgressLen}\r');
      _lastProgressLen = 0;
    }
  }

  String _buildBar(int done, int total, int width) {
    final filled = (done / total * width).round().clamp(0, width);
    return '[${_green('=' * filled)}${_gray('-' * (width - filled))}]';
  }

  String _fmtDuration(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inSeconds}.${(d.inMilliseconds % 1000) ~/ 100}s';
  }

  String _banner() => _bold(_cyan(r'''
 ____             _   ____             _
|  _ \  __ _ _ __| |_| __ ) _   _ ___| |_ ___ _ __
| | | |/ _` | '__| __|  _ \| | | / __| __/ _ \ '__|
| |_| | (_| | |  | |_| |_) | |_| \__ \ ||  __/ |
|____/ \__,_|_|   \__|____/ \__,_|___/\__\___|_|
'''));
}

/// Streams one JSON object per line (NDJSON) — easy to pipe into jq.
class JsonFormatter implements OutputFormatter {
  final IOSink _out;
  JsonFormatter({IOSink? out}) : _out = out ?? stdout;

  @override
  void start(String target, String mode, int wordlistSize) {
    _write({'event': 'start', 'target': target, 'mode': mode, 'wordlistSize': wordlistSize});
  }

  @override
  void result(ProbeResult r, {String? label}) {
    _write({
      'event': 'result',
      'url': r.uri.toString(),
      'status': r.statusCode,
      'length': r.contentLength,
      'contentType': r.contentType,
      'redirect': r.redirectLocation,
      if (label != null) 'label': label,
    });
  }

  @override void progress(int done, int total) {}
  @override void info(String m) => _write({'event': 'info', 'message': m});
  @override void warn(String m) => _write({'event': 'warn', 'message': m});
  @override void error(String m) => _write({'event': 'error', 'message': m});

  @override
  void summary(ScanSummary s) {
    _write({
      'event': 'summary',
      'totalProbed': s.totalProbed,
      'found': s.found,
      'errors': s.errors,
      'elapsedMs': s.elapsed.inMilliseconds,
      'reqPerSec': s.requestsPerSecond,
    });
  }

  @override
  void close() => _out.flush();

  void _write(Map<String, dynamic> obj) {
    _out.writeln(jsonEncode(obj));
  }
}

/// Comma-separated output — headers + result rows only.
class CsvFormatter implements OutputFormatter {
  final IOSink _out;
  CsvFormatter({IOSink? out}) : _out = out ?? stdout;

  @override
  void start(String target, String mode, int wordlistSize) {
    _out.writeln('url,status,length,content_type,redirect');
  }

  @override
  void result(ProbeResult r, {String? label}) {
    _out.writeln([
      r.uri.toString(),
      r.statusCode,
      r.contentLength,
      r.contentType ?? '',
      r.redirectLocation ?? '',
    ].map(_escape).join(','));
  }

  String _escape(dynamic v) {
    final s = v.toString();
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  @override void progress(int done, int total) {}
  @override void info(String m) {}
  @override void warn(String m) {}
  @override void error(String m) => stderr.writeln('[E] $m');
  @override void summary(ScanSummary s) {}
  @override void close() => _out.flush();
}
