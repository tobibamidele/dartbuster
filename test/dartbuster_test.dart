import 'dart:io';
import 'package:test/test.dart';
import '../lib/dartbuster.dart';

void main() {
  group('Semaphore', () {
    test('limits concurrency to maxCount', () async {
      final sem = Semaphore(3);
      var concurrent = 0;
      var maxConcurrent = 0;

      final futures = List.generate(10, (_) async {
        await sem.acquire();
        concurrent++;
        maxConcurrent = concurrent > maxConcurrent ? concurrent : maxConcurrent;
        await Future.delayed(const Duration(milliseconds: 20));
        concurrent--;
        sem.release();
      });

      await Future.wait(futures);
      expect(maxConcurrent, lessThanOrEqualTo(3));
    });

    test('run() releases on exception', () async {
      final sem = Semaphore(1);
      try {
        await sem.run(() async => throw Exception('boom'));
      } catch (_) {}
      // Should be acquirable immediately after
      var acquired = false;
      await sem.run(() async => acquired = true);
      expect(acquired, isTrue);
    });
  });

  group('ProbeResult', () {
    test('timeout factory sets isError and isTimeout', () {
      final r = ProbeResult.timeout(Uri.parse('http://example.com/test'));
      expect(r.isTimeout, isTrue);
      expect(r.isError, isTrue);
      expect(r.isSuccess, isFalse);
      expect(r.statusCode, equals(0));
    });

    test('networkError factory sets error message', () {
      final r = ProbeResult.networkError(Uri.parse('http://x.com'), 'refused');
      expect(r.errorMessage, equals('refused'));
      expect(r.isError, isTrue);
    });

    test('successful result has isSuccess = true', () {
      final r = ProbeResult(
        uri: Uri.parse('http://example.com/admin'),
        statusCode: 200,
        contentLength: 1024,
      );
      expect(r.isSuccess, isTrue);
      expect(r.isError, isFalse);
    });
  });

  group('ScanSummary', () {
    test('requestsPerSecond computed correctly', () {
      final s = ScanSummary(
        totalProbed: 100,
        found: 5,
        errors: 2,
        elapsed: const Duration(seconds: 10),
      );
      expect(s.requestsPerSecond, equals(10.0));
    });

    test('zero elapsed returns 0 req/s', () {
      final s = ScanSummary(
        totalProbed: 100,
        found: 5,
        errors: 0,
        elapsed: Duration.zero,
      );
      expect(s.requestsPerSecond, equals(0));
    });
  });

  group('ModuleRegistry', () {
    setUp(() {
      ModuleRegistry.register(DirModule());
      ModuleRegistry.register(DnsModule());
      ModuleRegistry.register(VhostModule());
      ModuleRegistry.register(FuzzModule());
    });

    test('finds registered modules by name', () {
      expect(ModuleRegistry.find('dir'), isA<DirModule>());
      expect(ModuleRegistry.find('dns'), isA<DnsModule>());
      expect(ModuleRegistry.find('vhost'), isA<VhostModule>());
      expect(ModuleRegistry.find('fuzz'), isA<FuzzModule>());
    });

    test('returns null for unknown module', () {
      expect(ModuleRegistry.find('nonexistent'), isNull);
    });

    test('all returns all registered modules', () {
      final names = ModuleRegistry.all.map((m) => m.name).toSet();
      expect(names, containsAll(['dir', 'dns', 'vhost', 'fuzz']));
    });
  });

  group('DirModule initialization', () {
    test('throws on non-http target', () {
      final module = DirModule();
      expect(
        () => module.initialize(ModuleConfig(target: 'ftp://example.com')),
        throwsArgumentError,
      );
    });

    test('initializes successfully with valid URL', () {
      final module = DirModule();
      expect(
        () => module.initialize(ModuleConfig(target: 'https://example.com')),
        returnsNormally,
      );
    });
  });

  group('FuzzModule initialization', () {
    test('throws if FUZZ placeholder missing', () {
      final module = FuzzModule();
      expect(
        () => module.initialize(ModuleConfig(target: 'https://example.com/api')),
        throwsArgumentError,
      );
    });

    test('initializes with FUZZ in URL', () {
      final module = FuzzModule();
      expect(
        () => module.initialize(ModuleConfig(target: 'https://example.com/FUZZ')),
        returnsNormally,
      );
    });
  });

  group('UserAgentPool', () {
    test('single returns same UA every time', () {
      final pool = UserAgentPool.single('TestBot/1.0');
      expect(pool.next, equals('TestBot/1.0'));
      expect(pool.next, equals('TestBot/1.0'));
    });

    test('sequential rotates through agents', () {
      final pool = UserAgentPool.sequential();
      final first = pool.next;
      final second = pool.next;
      // They're in the built-in list so both should be non-empty
      expect(first, isNotEmpty);
      expect(second, isNotEmpty);
    });

    test('random pool returns agents from the built-in list', () {
      final pool = UserAgentPool.random();
      final ua = pool.next;
      expect(ua, isNotEmpty);
    });
  });

  group('Wordlist', () {
    late File tempFile;

    setUp(() async {
      tempFile = File('${Directory.systemTemp.path}/dartbuster_test_wordlist.txt');
      await tempFile.writeAsString('''
# This is a comment
admin
login

  backup  
api
# another comment
''');
    });

    tearDown(() async {
      if (await tempFile.exists()) await tempFile.delete();
    });

    test('load strips comments and blank lines', () async {
      final words = await Wordlist.load(tempFile.path);
      expect(words, equals(['admin', 'login', 'backup', 'api']));
    });

    test('stream yields same results', () async {
      final words = await Wordlist.stream(tempFile.path).toList();
      expect(words, equals(['admin', 'login', 'backup', 'api']));
    });

    test('throws WordlistException for missing file', () async {
      expect(
        () => Wordlist.load('/nonexistent/path/words.txt'),
        throwsA(isA<WordlistException>()),
      );
    });
  });

  group('ModuleConfig helpers', () {
    test('flag() returns fallback for missing key', () {
      final cfg = ModuleConfig(target: 'http://x.com', rawFlags: {});
      expect(cfg.flag('nonexistent', fallback: 'default'), equals('default'));
    });

    test('flagBool() parses true string', () {
      final cfg = ModuleConfig(
        target: 'http://x.com',
        rawFlags: {'add-slash': 'true'},
      );
      expect(cfg.flagBool('add-slash'), isTrue);
    });

    test('flagInt() parses integer string', () {
      final cfg = ModuleConfig(
        target: 'http://x.com',
        rawFlags: {'wildcard-threshold': '5'},
      );
      expect(cfg.flagInt('wildcard-threshold'), equals(5));
    });
  });
}
