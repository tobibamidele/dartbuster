import '../core/http_client.dart';
import '../core/module.dart';

/// Generic fuzzer: replaces the `FUZZ` placeholder anywhere in the URL,
/// headers, or request body with each wordlist entry.
///
/// Example:
///   dartbuster fuzz -u "https://example.com/user/FUZZ" -w names.txt
///   dartbuster fuzz -u "https://example.com/api" -H "X-Role: FUZZ" -w roles.txt
class FuzzModule extends BusterModule {
  @override
  String get name => 'fuzz';

  @override
  String get description =>
      'Generic fuzzer — replaces FUZZ placeholder in URL/headers';

  @override
  List<ModuleFlag> get flags => [
        const ModuleFlag(
          name: 'method',
          abbr: 'm',
          help: 'HTTP method to use (GET, POST, PUT, …)',
          defaultValue: 'GET',
        ),
        const ModuleFlag(
          name: 'body',
          abbr: 'b',
          help: 'Request body template (use FUZZ as placeholder)',
        ),
        const ModuleFlag(
          name: 'match-regex',
          help: 'Only report results whose body matches this regex',
        ),
      ];

  static const _kPlaceholder = 'FUZZ';

  late String _urlTemplate;
  late List<int> _matchCodes;
  late List<int> _filterCodes;
  int? _filterLength;

  @override
  void initialize(ModuleConfig config) {
    _urlTemplate = config.target;
    if (!_urlTemplate.contains(_kPlaceholder)) {
      throw ArgumentError(
        'fuzz mode requires the FUZZ placeholder in the target URL. '
        'Example: https://example.com/FUZZ',
      );
    }
    _matchCodes = config.matchStatusCodes;
    _filterCodes = config.filterStatusCodes;
    _filterLength = config.filterContentLength;
  }

  @override
  Future<ProbeResult?> probe(String word, ModuleContext ctx) async {
    final urlStr = _urlTemplate.replaceAll(_kPlaceholder, Uri.encodeComponent(word));
    final uri = Uri.parse(urlStr);

    // Substitute FUZZ in headers too
    final headers = ctx.config.extraHeaders.map(
      (k, v) => MapEntry(k, v.replaceAll(_kPlaceholder, word)),
    );

    final result = await ctx.client.get(uri, extraHeaders: headers);

    if (!_shouldReport(result)) return null;

    ctx.formatter.result(result, label: word);
    return result;
  }

  bool _shouldReport(ProbeResult r) {
    if (r.isError) return false;
    if (_filterCodes.contains(r.statusCode)) return false;
    if (!_matchCodes.contains(r.statusCode)) return false;
    if (_filterLength != null && r.contentLength == _filterLength) return false;
    return true;
  }
}
