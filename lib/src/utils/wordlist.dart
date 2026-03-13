import 'dart:io';
import 'dart:convert';

/// Loads wordlists from disk or stdin, supports comments (#) and blank lines.
///
/// For very large wordlists (>1 million lines), use [WordlistStream] to avoid
/// loading everything into memory at once.
class Wordlist {
  /// Loads the entire wordlist into a List<String>. Suitable for lists <500k.
  static Future<List<String>> load(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw WordlistException('Wordlist not found: $path');
    }
    final lines = await file.readAsLines();
    return _filter(lines);
  }

  /// Returns a Stream of words — memory-efficient for huge wordlists.
  static Stream<String> stream(String path) async* {
    final file = File(path);
    if (!await file.exists()) {
      throw WordlistException('Wordlist not found: $path');
    }
    yield* file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty);
  }

  /// Reads wordlist from stdin when path is "-".
  static Stream<String> fromStdin() {
    return stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty);
  }

  static List<String> _filter(List<String> lines) {
    return lines
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();
  }

  /// Approximate line count without loading the file (for progress reporting).
  static Future<int> estimateCount(String path) async {
    final file = File(path);
    if (!await file.exists()) return 0;
    var count = 0;
    await for (final _ in file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      count++;
    }
    return count;
  }
}

class WordlistException implements Exception {
  final String message;
  WordlistException(this.message);
  @override
  String toString() => 'WordlistException: $message';
}
