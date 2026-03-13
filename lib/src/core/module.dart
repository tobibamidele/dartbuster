import '../core/http_client.dart';
import '../core/engine.dart';
import '../output/formatter.dart';

/// Base class for every DartBuster scan module.
///
/// To add a new mode (e.g. S3 bucket enumeration, vhost fuzzing, git-object
/// probing) implement this abstract class and register it in [ModuleRegistry].
///
/// Design goals:
///   • Modules are stateless with respect to HTTP — they receive a shared
///     [BusterHttpClient] and a [ModuleConfig].
///   • Filtering logic lives inside the module (status codes, content length,
///     regexes) so each module can expose its own filter semantics.
///   • A module returns [ProbeResult?] — null means "don't report this".
abstract class BusterModule {
  /// Short identifier used on the command line, e.g. "dir", "dns", "vhost".
  String get name;

  /// Human-readable description shown in --help.
  String get description;

  /// Module-specific argument definitions. Return [] if none.
  List<ModuleFlag> get flags => [];

  /// Called once before the scan begins. Override to validate config.
  void initialize(ModuleConfig config) {}

  /// The hot path: probe one [word] and return a [ProbeResult] to report,
  /// or null to suppress it.
  Future<ProbeResult?> probe(String word, ModuleContext ctx);

  /// Optionally transform words before they reach [probe] (e.g. add prefix).
  String transformWord(String word) => word;
}

/// Typed configuration bag passed from CLI flags into each module.
class ModuleConfig {
  final String target;
  final List<int> matchStatusCodes;
  final List<int> filterStatusCodes;
  final int? matchContentLength;
  final int? filterContentLength;
  final String? matchRegex;
  final bool followRedirects;
  final Map<String, String> extraHeaders;
  final Map<String, String> rawFlags;

  const ModuleConfig({
    required this.target,
    this.matchStatusCodes = const [200, 204, 301, 302, 307, 401, 403],
    this.filterStatusCodes = const [],
    this.matchContentLength,
    this.filterContentLength,
    this.matchRegex,
    this.followRedirects = false,
    this.extraHeaders = const {},
    this.rawFlags = const {},
  });

  /// Convenience: fetch a string flag by name with a fallback.
  String flag(String key, {String fallback = ''}) =>
      rawFlags[key] ?? fallback;

  /// Convenience: fetch a boolean flag.
  bool flagBool(String key) =>
      rawFlags[key]?.toLowerCase() == 'true';

  /// Convenience: fetch an integer flag.
  int? flagInt(String key) =>
      rawFlags[key] != null ? int.tryParse(rawFlags[key]!) : null;
}

/// Runtime context passed into [BusterModule.probe] on every call.
/// Gives the module access to the HTTP client and output machinery
/// without tight coupling.
class ModuleContext {
  final BusterHttpClient client;
  final OutputFormatter formatter;
  final ModuleConfig config;
  final CancelToken cancelToken;

  const ModuleContext({
    required this.client,
    required this.formatter,
    required this.config,
    required this.cancelToken,
  });
}

/// Declaration of a module-specific CLI flag.
class ModuleFlag {
  final String name;
  final String abbr;
  final String help;
  final String? defaultValue;
  final bool isBool;

  const ModuleFlag({
    required this.name,
    required this.help,
    this.abbr = '',
    this.defaultValue,
    this.isBool = false,
  });
}

/// Central registry: all modules are registered here at startup.
///
/// To plug in a new module:
///   1. Implement [BusterModule].
///   2. Add `ModuleRegistry.register(MyModule())` in main.dart.
class ModuleRegistry {
  static final _modules = <String, BusterModule>{};

  static void register(BusterModule module) {
    _modules[module.name] = module;
  }

  static BusterModule? find(String name) => _modules[name];

  static Iterable<BusterModule> get all => _modules.values;

  /// Returns a formatted help string listing all registered modules.
  static String helpText() {
    final sb = StringBuffer();
    for (final m in _modules.values) {
      sb.writeln('  ${m.name.padRight(12)} ${m.description}');
    }
    return sb.toString();
  }
}
