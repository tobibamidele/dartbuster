import 'dart:io';

import '../core/http_client.dart';
import '../core/module.dart';

/// Enumerates directories and files on an HTTP target by appending wordlist
/// entries to the base URL, optionally trying multiple file extensions.
///
/// Equivalent to: gobuster dir -u <url> -w <wordlist> -x php,html
class DirModule extends BusterModule {
  @override
  String get name => 'dir';

  @override
  String get description => 'Directory and file path enumeration (HTTP/HTTPS)';

  @override
  List<ModuleFlag> get flags => [
        const ModuleFlag(
          name: 'extensions',
          abbr: 'x',
          help: 'Comma-separated file extensions to probe (e.g. php,html,txt)',
          defaultValue: '',
        ),
        const ModuleFlag(
          name: 'add-slash',
          help: 'Also probe each word with a trailing slash',
          isBool: true,
        ),
        const ModuleFlag(
          name: 'expanded',
          help: 'Print the full URL instead of just the path',
          isBool: true,
        ),
      ];

  late Uri _baseUri;
  late List<String> _extensions;
  late bool _addSlash;
  late List<int> _matchCodes;
  late List<int> _filterCodes;
  late int? _filterLength;

  @override
  void initialize(ModuleConfig config) {
    _baseUri = Uri.parse(config.target);
    if (!_baseUri.scheme.startsWith('http')) {
      throw ArgumentError('dir mode requires an http/https target URL');
    }
    // Normalize: remove trailing slash from base
    if (_baseUri.path.endsWith('/') && _baseUri.path.length > 1) {
      _baseUri = _baseUri.replace(path: _baseUri.path.substring(0, _baseUri.path.length - 1));
    }

    final extRaw = config.flag('extensions');
    _extensions = extRaw.isEmpty
        ? []
        : extRaw.split(',').map((e) => e.trim().replaceFirst('.', '')).toList();

    _addSlash = config.flagBool('add-slash');
    _matchCodes = config.matchStatusCodes;
    _filterCodes = config.filterStatusCodes;
    _filterLength = config.filterContentLength;
  }

  @override
  Future<ProbeResult?> probe(String word, ModuleContext ctx) async {
    // Build all candidate paths for this word
    final paths = _buildPaths(word);
    ProbeResult? bestMatch;

    for (final path in paths) {
      final uri = _baseUri.replace(path: path);
      final result = await ctx.client.get(uri, extraHeaders: ctx.config.extraHeaders);

      if (_shouldReport(result)) {
        // Return first match per word batch; caller aggregates via onResult
        bestMatch = result;
        ctx.formatter.result(result, label: path != '/${word}' ? path.split('/').last : null);
      }
    }

    return bestMatch;
  }

  List<String> _buildPaths(String word) {
    final base = _baseUri.path;
    final separator = base.endsWith('/') ? '' : '/';
    final paths = <String>['$base$separator$word'];

    for (final ext in _extensions) {
      paths.add('$base$separator$word.$ext');
    }
    if (_addSlash) {
      paths.add('$base$separator$word/');
    }

    return paths;
  }

  bool _shouldReport(ProbeResult r) {
    if (r.isError) return false;
    // Filter out explicitly excluded codes
    if (_filterCodes.contains(r.statusCode)) return false;
    // Filter by content length if set
    if (_filterLength != null && r.contentLength == _filterLength) return false;
    // Must match one of the desired status codes
    return _matchCodes.contains(r.statusCode);
  }
}
