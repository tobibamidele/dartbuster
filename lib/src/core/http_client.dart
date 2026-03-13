import 'dart:io';

/// A thin wrapper around [dart:io]'s [HttpClient] tuned for brute-force
/// enumeration workloads:
///   • Connection reuse via persistent keep-alive
///   • Configurable timeout
///   • Optional redirect following
///   • Optional TLS certificate verification bypass (--insecure)
///   • Per-request User-Agent injection
class BusterHttpClient {
  final HttpClient _inner;
  final Duration timeout;
  final bool followRedirects;
  final int maxRedirects;
  final List<String> _userAgents;
  int _uaIndex = 0;

  BusterHttpClient({
    this.timeout = const Duration(seconds: 10),
    this.followRedirects = false,
    this.maxRedirects = 5,
    bool insecure = false,
    List<String>? userAgents,
    int maxConnectionsPerHost = 0, // 0 = unlimited
  })  : _inner = _buildClient(insecure, maxConnectionsPerHost),
        _userAgents = userAgents ?? [_kDefaultUA];

  static HttpClient _buildClient(bool insecure, int maxConns) {
    final ctx = SecurityContext.defaultContext;
    HttpClient client;
    if (insecure) {
      client = HttpClient(context: ctx)
        ..badCertificateCallback = (_, __, ___) => true;
    } else {
      client = HttpClient(context: ctx);
    }
    if (maxConns > 0) {
      client.maxConnectionsPerHost = maxConns;
    }
    return client;
  }

  /// Rotate user agent strings in round-robin fashion.
  String get _nextUserAgent {
    final ua = _userAgents[_uaIndex % _userAgents.length];
    _uaIndex++;
    return ua;
  }

  /// Performs an HTTP GET and returns a [ProbeResult].
  /// Never throws on HTTP-level errors — only on network/timeout failures.
  Future<ProbeResult> get(
    Uri uri, {
    Map<String, String>? extraHeaders,
    String? userAgentOverride,
  }) async {
    final ua = userAgentOverride ?? _nextUserAgent;
    HttpClientRequest req;
    try {
      req = await _inner
          .getUrl(uri)
          .timeout(timeout, onTimeout: () => throw TimeoutException(uri));

      req.followRedirects = followRedirects;
      req.maxRedirects = maxRedirects;
      req.headers.set(HttpHeaders.userAgentHeader, ua);
      req.headers.set(HttpHeaders.connectionHeader, 'keep-alive');

      if (extraHeaders != null) {
        extraHeaders.forEach((k, v) => req.headers.set(k, v));
      }

      final resp = await req.close().timeout(
            timeout,
            onTimeout: () => throw TimeoutException(uri),
          );

      // We must drain the body to free the connection back to the pool.
      final body = await resp.fold<List<int>>(
        [],
        (prev, chunk) => prev..addAll(chunk),
      );

      final length = resp.headers.contentLength == -1
          ? body.length
          : resp.headers.contentLength;

      final location =
          resp.headers.value(HttpHeaders.locationHeader);

      return ProbeResult(
        uri: uri,
        statusCode: resp.statusCode,
        contentLength: length,
        contentType: resp.headers.contentType?.mimeType,
        redirectLocation: location,
        body: body,
      );
    } on TimeoutException {
      return ProbeResult.timeout(uri);
    } on SocketException catch (e) {
      return ProbeResult.networkError(uri, e.message);
    } on HttpException catch (e) {
      return ProbeResult.networkError(uri, e.message);
    } on TlsException catch (e) {
      return ProbeResult.networkError(uri, 'TLS: ${e.message}');
    } catch (e) {
      return ProbeResult.networkError(uri, e.toString());
    }
  }

  void close({bool force = false}) => _inner.close(force: force);
}

/// Immutable result from a single HTTP probe.
class ProbeResult {
  final Uri uri;
  final int statusCode;
  final int contentLength;
  final String? contentType;
  final String? redirectLocation;
  final List<int> body;
  final bool isTimeout;
  final bool isError;
  final String? errorMessage;

  const ProbeResult({
    required this.uri,
    required this.statusCode,
    required this.contentLength,
    this.contentType,
    this.redirectLocation,
    this.body = const [],
    this.isTimeout = false,
    this.isError = false,
    this.errorMessage,
  });

  factory ProbeResult.timeout(Uri uri) => ProbeResult(
        uri: uri,
        statusCode: 0,
        contentLength: 0,
        isTimeout: true,
        isError: true,
        errorMessage: 'Timeout',
      );

  factory ProbeResult.networkError(Uri uri, String msg) => ProbeResult(
        uri: uri,
        statusCode: 0,
        contentLength: 0,
        isError: true,
        errorMessage: msg,
      );

  bool get isSuccess => !isError;

  @override
  String toString() =>
      'ProbeResult(${uri.path}, status=$statusCode, len=$contentLength)';
}

/// Sentinel thrown internally; caught in [BusterHttpClient.get].
class TimeoutException implements Exception {
  final Uri uri;
  TimeoutException(this.uri);
}

const _kDefaultUA =
    'DartBuster/0.1.0 (https://github.com/tobibamidele/dartbuster)';
