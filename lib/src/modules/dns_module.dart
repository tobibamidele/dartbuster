import 'dart:io';

import '../core/http_client.dart';
import '../core/module.dart';

/// Enumerates subdomains via DNS resolution — no HTTP requests made.
///
/// For each word in the wordlist, constructs `<word>.<domain>` and attempts
/// a DNS A/AAAA lookup. Wildcard detection is performed at initialization.
///
/// Equivalent to: gobuster dns -d <domain> -w <wordlist>
class DnsModule extends BusterModule {
  @override
  String get name => 'dns';

  @override
  String get description => 'Subdomain enumeration via DNS resolution';

  @override
  List<ModuleFlag> get flags => [
        const ModuleFlag(
          name: 'show-ips',
          abbr: 'i',
          help: 'Show resolved IP addresses in results',
          isBool: true,
        ),
        const ModuleFlag(
          name: 'wildcard-threshold',
          help: 'Number of random lookups to confirm wildcard (default: 3)',
          defaultValue: '3',
        ),
      ];

  late String _domain;
  late bool _showIps;
  bool _hasWildcard = false;
  Set<String> _wildcardIps = {};
  late int _wildcardThreshold;

  @override
  void initialize(ModuleConfig config) {
    _domain = config.target.replaceFirst(RegExp(r'^https?://'), '').split('/').first;
    _showIps = config.flagBool('show-ips');
    _wildcardThreshold = config.flagInt('wildcard-threshold') ?? 3;
  }

  /// Call this once before the scan to detect wildcard DNS.
  /// Returns true if wildcard was detected.
  Future<bool> detectWildcard(void Function(String) onWarn) async {
    final rng = DateTime.now().millisecondsSinceEpoch;
    final testHosts = List.generate(
      _wildcardThreshold,
      (i) => 'dartbuster-wildcard-${rng + i}.$_domain',
    );

    final resolvedSets = <Set<String>>[];
    for (final host in testHosts) {
      try {
        final addrs = await InternetAddress.lookup(host);
        if (addrs.isNotEmpty) {
          resolvedSets.add(addrs.map((a) => a.address).toSet());
        }
      } catch (_) {
        // NXDOMAIN — expected
      }
    }

    if (resolvedSets.length >= _wildcardThreshold) {
      _hasWildcard = true;
      // Collect IPs common across all wildcard responses
      _wildcardIps = resolvedSets.reduce((a, b) => a.intersection(b));
      onWarn(
        'Wildcard DNS detected for *.$_domain → ${_wildcardIps.join(", ")}. '
        'Filtering wildcard results.',
      );
    }

    return _hasWildcard;
  }

  @override
  Future<ProbeResult?> probe(String word, ModuleContext ctx) async {
    final host = '$word.$_domain';
    try {
      final addrs = await InternetAddress.lookup(host);
      if (addrs.isEmpty) return null;

      final resolvedIps = addrs.map((a) => a.address).toSet();

      // Wildcard suppression: if all resolved IPs match the wildcard set, skip
      if (_hasWildcard && resolvedIps.every((ip) => _wildcardIps.contains(ip))) {
        return null;
      }

      // Return a synthetic ProbeResult — DNS probes have no HTTP status
      final uri = Uri.parse('http://$host');
      final result = ProbeResult(
        uri: uri,
        statusCode: 200, // sentinel: "resolved"
        contentLength: 0,
        contentType: 'dns',
      );

      final label = _showIps ? resolvedIps.join(', ') : null;
      ctx.formatter.result(result, label: label ?? host);
      return result;
    } on SocketException {
      // NXDOMAIN or network error — not a finding
      return null;
    } catch (_) {
      return null;
    }
  }
}
