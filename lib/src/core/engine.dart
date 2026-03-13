import 'dart:async';
import 'http_client.dart';

/// A counting semaphore that limits concurrent async tasks — the primary
/// mechanism for controlling request concurrency in DartBuster.
///
/// Unlike spinning on a fixed-size list of Futures, this integrates cleanly
/// with Dart's event loop: waiters are queued and resumed via [Completer],
/// so the event loop isn't starved.
class Semaphore {
  final int maxCount;
  int _count;
  final _waiters = <Completer<void>>[];

  Semaphore(this.maxCount) : _count = maxCount;

  Future<void> acquire() {
    if (_count > 0) {
      _count--;
      return Future.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      final next = _waiters.removeAt(0);
      next.complete();
    } else {
      _count++;
    }
  }

  /// Wraps [fn] with acquire/release, ensuring the semaphore slot is always
  /// freed even if [fn] throws.
  Future<T> run<T>(Future<T> Function() fn) async {
    await acquire();
    try {
      return await fn();
    } finally {
      release();
    }
  }
}

/// Callback type invoked for every probe result (match or not).
typedef ResultCallback = void Function(ProbeResult result);

/// Optional rate-limiter: minimum duration between outbound requests.
/// Set to [Duration.zero] to disable.
class RateLimiter {
  final Duration _delay;
  DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);

  RateLimiter(this._delay);

  Future<void> wait() async {
    if (_delay == Duration.zero) return;
    final now = DateTime.now();
    final elapsed = now.difference(_lastRequest);
    if (elapsed < _delay) {
      await Future.delayed(_delay - elapsed);
    }
    _lastRequest = DateTime.now();
  }
}

/// The central scan engine: feeds wordlist entries to modules concurrently,
/// respects the semaphore limit, and dispatches results to the formatter.
class ScanEngine {
  final BusterHttpClient client;
  final int threads;
  final Duration? requestDelay;
  final bool verbose;

  ScanEngine({
    required this.client,
    this.threads = 10,
    this.requestDelay,
    this.verbose = false,
  });

  /// Runs [probe] for every [word] in [words] with controlled concurrency.
  ///
  /// [onResult] is called for every result (filtered by the module itself).
  /// [onProgress] is called after every attempt with the count so far.
  Future<ScanSummary> run({
    required Iterable<String> words,
    required Future<ProbeResult?> Function(String word) probe,
    required ResultCallback onResult,
    void Function(int done, int total)? onProgress,
    CancelToken? cancel,
  }) async {
    final sem = Semaphore(threads);
    final rateLimiter = RateLimiter(requestDelay ?? Duration.zero);
    final wordList = words.toList();
    final total = wordList.length;
    var done = 0;
    var found = 0;
    var errors = 0;
    final startTime = DateTime.now();

    final futures = <Future<void>>[];

    for (final word in wordList) {
      if (cancel?.isCancelled == true) break;

      final f = sem.run(() async {
        if (cancel?.isCancelled == true) return;
        await rateLimiter.wait();
        final result = await probe(word);
        done++;
        onProgress?.call(done, total);
        if (result != null) {
          onResult(result);
          if (!result.isError) found++;
          if (result.isError) errors++;
        }
      });
      futures.add(f);
    }

    await Future.wait(futures);
    final elapsed = DateTime.now().difference(startTime);

    return ScanSummary(
      totalProbed: done,
      found: found,
      errors: errors,
      elapsed: elapsed,
    );
  }
}

/// Allows the user to cancel an in-progress scan (e.g. on SIGINT).
class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class ScanSummary {
  final int totalProbed;
  final int found;
  final int errors;
  final Duration elapsed;

  const ScanSummary({
    required this.totalProbed,
    required this.found,
    required this.errors,
    required this.elapsed,
  });

  double get requestsPerSecond =>
      elapsed.inMilliseconds == 0
          ? 0
          : totalProbed / (elapsed.inMilliseconds / 1000);
}
