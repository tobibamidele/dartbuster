import '../core/http_client.dart';
import '../core/module.dart';

/// Virtual host enumeration: sends requests to the target IP/URL but cycles
/// the `Host:` header through wordlist-generated hostnames. Identifies vhosts
/// that return a different response than the baseline.
///
/// Equivalent to: gobuster vhost -u <url> -w <wordlist> --domain <domain>
class VhostModule extends BusterModule {
  @override
  String get name => 'vhost';

  @override
  String get description => 'Virtual host enumeration via Host header fuzzing';

  @override
  List<ModuleFlag> get flags => [
        const ModuleFlag(
          name: 'domain',
          abbr: 'd',
          help: 'Append this domain to each wordlist entry (e.g. example.com)',
        ),
        const ModuleFlag(
          name: 'append-domain',
          help: 'Append --domain to each word (word.domain vs word)',
          isBool: true,
          defaultValue: 'true',
        ),
        const ModuleFlag(
          name: 'exclude-length',
          abbr: 'l',
          help: 'Exclude responses with this content length (baseline exclusion)',
        ),
      ];

  late Uri _targetUri;
  late String _domain;
  late bool _appendDomain;
  late List<int> _matchCodes;
  late List<int> _filterCodes;
  int? _excludeLength;
  int? _baselineLength;

  @override
  void initialize(ModuleConfig config) {
    _targetUri = Uri.parse(config.target);
    _domain = config.flag('domain');
    _appendDomain = config.flagBool('append-domain');
    _matchCodes = config.matchStatusCodes;
    _filterCodes = config.filterStatusCodes;
    final el = config.flag('exclude-length');
    _excludeLength = el.isNotEmpty ? int.tryParse(el) : null;
  }

  /// Establishes the baseline response by requesting the target with a random
  /// unknown vhost. Call before starting the scan.
  Future<void> establishBaseline(BusterHttpClient client) async {
    final fakeHost = 'dartbuster-baseline-${DateTime.now().millisecondsSinceEpoch}.${_domain.isNotEmpty ? _domain : 'invalid'}';
    final result = await client.get(_targetUri, extraHeaders: {'Host': fakeHost});
    if (result.isSuccess) {
      _baselineLength = result.contentLength;
    }
  }

  @override
  Future<ProbeResult?> probe(String word, ModuleContext ctx) async {
    final host = (_appendDomain && _domain.isNotEmpty)
        ? '$word.$_domain'
        : word;

    final result = await ctx.client.get(
      _targetUri,
      extraHeaders: {
        ...ctx.config.extraHeaders,
        'Host': host,
      },
    );

    if (!_shouldReport(result)) return null;

    ctx.formatter.result(result, label: host);
    return result;
  }

  bool _shouldReport(ProbeResult r) {
    if (r.isError) return false;
    if (_filterCodes.contains(r.statusCode)) return false;
    if (!_matchCodes.contains(r.statusCode)) return false;

    // Baseline exclusion: skip responses whose length matches the default
    if (_baselineLength != null && r.contentLength == _baselineLength) return false;
    if (_excludeLength != null && r.contentLength == _excludeLength) return false;

    return true;
  }
}
