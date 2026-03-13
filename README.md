# DartBuster

A high-performance web content discovery tool written in Dart. Inspired by [GoBuster](https://github.com/OJ/gobuster) — built for speed, extensibility, and modern red team workflows.

```
 ____             _   ____             _
|  _ \  __ _ _ __| |_| __ ) _   _ ___| |_ ___ _ __
| | | |/ _` | '__| __|  _ \| | | / __| __/ _ \ '__|
| |_| | (_| | |  | |_| |_) | |_| \__ \ ||  __/ |
|____/ \__,_|_|   \__|____/ \__,_|___/\__\___|_|
```

> **For authorised security testing and CTF use only.** Do not use against targets without explicit written permission.

---

## Contents

- [Why DartBuster](#why-dartbuster)
- [Installation](#installation)
- [Modes](#modes)
  - [dir — Directory & File Enumeration](#dir--directory--file-enumeration)
  - [dns — Subdomain Enumeration](#dns--subdomain-enumeration)
  - [vhost — Virtual Host Discovery](#vhost--virtual-host-discovery)
  - [fuzz — Generic Fuzzer](#fuzz--generic-fuzzer)
- [Global Flags](#global-flags)
- [Output Formats](#output-formats)
- [User-Agent Rotation](#user-agent-rotation)
- [Architecture](#architecture)
- [Writing a Custom Module](#writing-a-custom-module)
- [Contributing](#contributing)

---

## Why DartBuster

GoBuster is great. DartBuster exists for three reasons:

1. **Single AOT binary, any platform.** `dart compile exe` produces a self-contained native binary with no runtime dependency — deploy it on a pentest box, inside a Docker container, or on a Raspberry Pi without installing Go.
2. **Dart as a first-class security tooling language.** The Dart ecosystem lacks serious offensive tooling. DartBuster is both a useful tool and a reference implementation for async-heavy CLI security tools in Dart.
3. **Designed to be extended.** Every scan mode is a plugin. Adding a new one (S3 buckets, git objects, SOCKS proxy fuzzing, OTP brute-force) requires touching exactly one file after writing the module itself.

**HTTP engine:** `dart:io`'s native `HttpClient` — not `package:dio`, not `package:http`. The native client gives you direct control over TLS callbacks, redirect policy, keep-alive pooling, and connection limits that wrappers abstract away.

**Concurrency model:** A counting `Semaphore` over Dart's async event loop. HTTP I/O is event-loop-bound; Dart isolates (threads) are for CPU-bound work. `-t 100` means 100 concurrent in-flight futures, not 100 OS threads. This gives you GoBuster-level throughput at a fraction of the memory.

---

## Installation

### Prerequisites

- Dart SDK ≥ 3.0.0 — [install](https://dart.dev/get-dart)

### Run from source

```bash
git clone https://github.com/yourusername/dartbuster
cd dartbuster
dart pub get
dart run bin/main.dart --help
```

### Compile to a native AOT binary

```bash
dart compile exe bin/main.dart -o dartbuster
./dartbuster --help
```

The resulting binary has zero runtime dependencies. Copy it anywhere.

### Install as a global Dart tool

```bash
dart pub global activate --source path .
dartbuster --help
```

---

## Modes

### `dir` — Directory & File Enumeration

Appends wordlist entries to a base URL and probes for valid paths. Supports multi-extension probing per word and trailing-slash variants.

```bash
dartbuster dir -u <url> -w <wordlist> [flags]
```

**Module flags:**

| Flag | Short | Default | Description |
|---|---|---|---|
| `--extensions` | `-x` | _(none)_ | Comma-separated extensions to probe per word: `php,html,txt` |
| `--add-slash` | | `false` | Also probe `word/` for each entry |
| `--expanded` | | `false` | Print full URL instead of path only |

**Examples:**

```bash
# Basic directory scan
dartbuster dir -u https://example.com -w /usr/share/wordlists/dirb/common.txt

# Multi-extension, 50 threads, match 200/403 only
dartbuster dir -u https://example.com \
  -w /usr/share/wordlists/dirbuster/directory-list-2.3-medium.txt \
  -x php,html,bak,old \
  -t 50 \
  -s 200,403

# Scan a subdirectory
dartbuster dir -u https://example.com/api/v2 -w endpoints.txt -x json

# With cookie and custom header
dartbuster dir -u https://target.internal \
  -w common.txt \
  -H "Cookie: session=abc123" \
  -H "X-Forwarded-For: 127.0.0.1"

# Follow redirects, ignore TLS errors (self-signed cert)
dartbuster dir -u https://10.10.10.5 -w common.txt -r -k
```

---

### `dns` — Subdomain Enumeration

Resolves `<word>.<domain>` for every wordlist entry using native DNS lookups. Includes automatic wildcard DNS detection — if the target resolves every random subdomain to the same IP(s), those results are filtered.

```bash
dartbuster dns -u <domain> -w <wordlist> [flags]
```

**Module flags:**

| Flag | Short | Default | Description |
|---|---|---|---|
| `--show-ips` | `-i` | `false` | Print resolved IP addresses alongside each found subdomain |
| `--wildcard-threshold` | | `3` | Number of random probes used to confirm wildcard DNS |

> **Note:** The `-u` flag accepts a bare domain (`example.com`) or `http(s)://example.com` — the scheme is stripped automatically.

**Examples:**

```bash
# Basic subdomain enumeration
dartbuster dns -u example.com -w subdomains-top1million.txt

# Show IPs, high thread count for large wordlists
dartbuster dns -u target.com -w /usr/share/seclists/Discovery/DNS/bitquark-subdomains-top100000.txt \
  --show-ips -t 100

# Pipe to a file for later processing
dartbuster dns -u target.com -w subs.txt -o json > results.ndjson
```

---

### `vhost` — Virtual Host Discovery

Sends every request to the same target IP/URL but rotates the `Host:` header through wordlist entries. Identifies vhosts that return a response different from the baseline (established by probing with a random hostname before the scan starts).

Particularly useful on HackTheBox/CTF machines and internal networks where many vhosts sit behind a single IP.

```bash
dartbuster vhost -u <url> -w <wordlist> [flags]
```

**Module flags:**

| Flag | Short | Default | Description |
|---|---|---|---|
| `--domain` | `-d` | _(none)_ | Domain to append: `word` becomes `word.domain` |
| `--append-domain` | | `true` | Enable/disable the domain append behaviour |
| `--exclude-length` | `-l` | _(none)_ | Exclude responses with this exact content length |

**Examples:**

```bash
# HTB-style: single IP, many vhosts
dartbuster vhost -u http://10.10.11.20 \
  -w /usr/share/seclists/Discovery/DNS/subdomains-top1million-5000.txt \
  --domain htb.local \
  -t 40

# Exclude the default 404 page length to reduce noise
dartbuster vhost -u http://10.10.11.20 -w vhosts.txt --domain htb.local \
  --exclude-length 10918

# No domain append (wordlist already contains full hostnames)
dartbuster vhost -u http://10.10.11.20 -w full-hostnames.txt --append-domain=false
```

---

### `fuzz` — Generic Fuzzer

Replaces the `FUZZ` placeholder anywhere in the target URL or request headers with each wordlist entry. The most flexible mode — use it for endpoint discovery, parameter fuzzing, header injection testing, or anything else that doesn't fit the other modes.

```bash
dartbuster fuzz -u "https://target.com/<path-with-FUZZ>" -w <wordlist> [flags]
```

**Module flags:**

| Flag | Short | Default | Description |
|---|---|---|---|
| `--method` | `-m` | `GET` | HTTP method (`GET`, `POST`, `PUT`, `DELETE`, …) |
| `--body` | `-b` | _(none)_ | Request body template (use `FUZZ` as placeholder) |
| `--match-regex` | | _(none)_ | Only report results whose body matches this regex |

**Examples:**

```bash
# API endpoint discovery
dartbuster fuzz -u "https://api.target.com/v1/FUZZ" -w api-endpoints.txt -s 200,201,400

# Path parameter fuzzing
dartbuster fuzz -u "https://example.com/user/FUZZ/profile" -w usernames.txt

# Header value fuzzing (role escalation testing)
dartbuster fuzz -u "https://example.com/admin" \
  -H "X-Role: FUZZ" \
  -w roles.txt \
  -s 200

# Filter noise by content length + JSON output piped to jq
dartbuster fuzz -u "https://target.com/FUZZ" \
  -w common.txt \
  --filter-length 1024 \
  -o json | jq 'select(.event == "result")'
```

---

## Global Flags

These flags work across all modes.

| Flag | Short | Default | Description |
|---|---|---|---|
| `--url` | `-u` | _(required)_ | Target URL or domain |
| `--wordlist` | `-w` | _(required)_ | Path to wordlist file |
| `--threads` | `-t` | `10` | Concurrent request count |
| `--timeout` | | `10` | Request timeout in seconds |
| `--delay` | | `0` | Milliseconds between requests (rate limiting) |
| `--user-agent` | `-a` | _(DartBuster UA)_ | Fixed User-Agent string |
| `--random-agent` | | `false` | Rotate a random UA per request |
| `--agent-file` | | _(none)_ | Path to file of User-Agent strings to rotate |
| `--header` | `-H` | _(none)_ | Extra request header, repeatable: `"Name: Value"` |
| `--match-codes` | `-s` | `200,204,301,302,307,401,403` | Status codes to report |
| `--filter-codes` | `-b` | _(none)_ | Status codes to suppress |
| `--filter-length` | | _(none)_ | Suppress responses with this exact content length |
| `--follow-redirects` | `-r` | `false` | Follow HTTP redirects |
| `--insecure` | `-k` | `false` | Skip TLS certificate verification |
| `--output-format` | `-o` | `terminal` | Output format: `terminal`, `json`, `csv` |
| `--no-color` | | `false` | Disable ANSI colour output |
| `--quiet` | `-q` | `false` | Suppress progress bar |
| `--verbose` | `-v` | `false` | Show all probes, not just matches |

---

## Output Formats

### `terminal` (default)

Coloured, human-readable output with an inline progress bar on stderr and results on stdout. Status codes are colour-coded: green (2xx), cyan (3xx), yellow (401/403), red (5xx).

```
200  https://example.com/admin [4821]
301  https://example.com/images [0] → /images/
403  https://example.com/.htaccess [274]
```

Disable colour with `--no-color` (e.g. when piping terminal output to a file).

### `json` (NDJSON)

One JSON object per line. Every event type is tagged — parse with `jq`, feed into SIEM, or integrate with other tooling.

```bash
dartbuster dir -u https://example.com -w common.txt -o json | jq 'select(.event == "result")'
```

```json
{"event":"start","target":"https://example.com","mode":"dir","wordlistSize":4614}
{"event":"result","url":"https://example.com/admin","status":200,"length":4821,"contentType":"text/html"}
{"event":"result","url":"https://example.com/login","status":301,"length":0,"redirect":"/login/"}
{"event":"summary","totalProbed":4614,"found":12,"errors":0,"elapsedMs":9823,"reqPerSec":470.1}
```

### `csv`

Headers + one result row per match. Suitable for importing into spreadsheets or further processing with `cut`, `awk`, or pandas.

```bash
dartbuster dir -u https://example.com -w common.txt -o csv > results.csv
```

```
url,status,length,content_type,redirect
https://example.com/admin,200,4821,text/html,
https://example.com/login,301,0,,/login/
```

---

## User-Agent Rotation

Three levels of control:

```bash
# Fixed UA
dartbuster dir -u https://example.com -w common.txt -a "Mozilla/5.0 (compatible; CustomBot/1.0)"

# Random rotation from the built-in pool of 12 real-world UAs
dartbuster dir -u https://example.com -w common.txt --random-agent

# Rotate from your own file (one UA per line, # for comments)
dartbuster dir -u https://example.com -w common.txt --agent-file /path/to/agents.txt
```

The built-in pool includes Chrome, Firefox, Safari, Edge, Googlebot, curl, wget, Python requests, and Go's http client — enough to blend into typical access logs or evade basic UA blocklists.

---

## Architecture

```
dartbuster/
├── bin/
│   └── main.dart               # CLI parsing, module dispatch, SIGINT
├── lib/
│   ├── dartbuster.dart         # Barrel export (embed as a library)
│   └── src/
│       ├── core/
│       │   ├── http_client.dart  # BusterHttpClient — dart:io, TLS, pooling
│       │   ├── engine.dart       # ScanEngine, Semaphore, RateLimiter, CancelToken
│       │   └── module.dart       # BusterModule, ModuleRegistry, ModuleConfig
│       ├── modules/
│       │   ├── dir_module.dart
│       │   ├── dns_module.dart
│       │   ├── vhost_module.dart
│       │   └── fuzz_module.dart
│       ├── output/
│       │   └── formatter.dart    # OutputFormatter, TerminalFormatter, JsonFormatter, CsvFormatter
│       └── utils/
│           ├── wordlist.dart     # Async streaming wordlist loader
│           └── user_agents.dart  # UserAgentPool
└── test/
    └── dartbuster_test.dart
```

### Core data flow

```
main.dart
  │
  ├─ parses CLI flags
  ├─ initializes BusterHttpClient (dart:io, keep-alive, TLS config)
  ├─ loads wordlist into memory (or streams for very large lists)
  ├─ constructs ModuleContext {client, formatter, config, cancelToken}
  │
  └─ ScanEngine.run()
       │
       ├─ Semaphore(threads) — caps concurrent in-flight futures
       ├─ RateLimiter — enforces --delay between requests
       │
       └─ for each word → module.probe(word, ctx)
            │
            ├─ BusterHttpClient.get() → ProbeResult
            ├─ module filtering (_shouldReport)
            └─ formatter.result() if match
```

### Why `dart:io` over `package:http` / `package:dio`

`package:http` is a thin, portable wrapper around `dart:io`. For a CLI security tool that will only ever run on native Dart (not in a browser), there is no reason to pay the abstraction cost. `dart:io`'s `HttpClient` exposes:

- `badCertificateCallback` — essential for `--insecure` against self-signed certs
- `followRedirects` + `maxRedirects` per-request — critical for dir mode
- `maxConnectionsPerHost` — direct connection pool control
- Raw `HttpClientRequest`/`HttpClientResponse` — full header manipulation

`package:dio` adds interceptors, FormData, and Dio-specific abstractions that are irrelevant to brute-force enumeration and add latency.

---

## Writing a Custom Module

Adding a new scan mode takes three steps and touches exactly two files.

### 1. Implement `BusterModule`

```dart
// lib/src/modules/s3_module.dart
import '../core/http_client.dart';
import '../core/module.dart';

class S3Module extends BusterModule {
  @override
  String get name => 's3';

  @override
  String get description => 'AWS S3 bucket enumeration';

  @override
  List<ModuleFlag> get flags => [
    const ModuleFlag(
      name: 'region',
      help: 'AWS region to target (default: us-east-1)',
      defaultValue: 'us-east-1',
    ),
  ];

  late String _region;

  @override
  void initialize(ModuleConfig config) {
    _region = config.flag('region', fallback: 'us-east-1');
  }

  @override
  Future<ProbeResult?> probe(String word, ModuleContext ctx) async {
    final uri = Uri.parse('https://$word.s3.$_region.amazonaws.com');
    final result = await ctx.client.get(uri);

    // Report publicly accessible or listable buckets
    if (result.statusCode == 200 || result.statusCode == 403) {
      ctx.formatter.result(result, label: word);
      return result;
    }
    return null;
  }
}
```

### 2. Register it in `main.dart`

```dart
void _registerModules() {
  ModuleRegistry.register(DirModule());
  ModuleRegistry.register(DnsModule());
  ModuleRegistry.register(VhostModule());
  ModuleRegistry.register(FuzzModule());
  ModuleRegistry.register(S3Module()); // ← one line
}
```

### 3. Use it

```bash
dartbuster s3 -u ignored -w bucket-names.txt --region eu-west-1 -t 100
```

The new module automatically inherits all global flags: `--threads`, `--timeout`, `--delay`, `--random-agent`, `--output-format`, `--match-codes`, `--filter-codes`, `--header`, etc.

### `BusterModule` contract

| Method | Required | Purpose |
|---|---|---|
| `name` | ✅ | CLI subcommand identifier |
| `description` | ✅ | Shown in `--help` |
| `flags` | ✗ | Module-specific CLI flag declarations |
| `initialize(config)` | ✗ | Validate config; throw `ArgumentError` to abort with a clean message |
| `probe(word, ctx)` | ✅ | Hot path — return a `ProbeResult` to report, `null` to suppress |
| `transformWord(word)` | ✗ | Pre-process each word before it reaches `probe` |

---

## Contributing

Pull requests are welcome. A few guidelines:

- **New modules** should live in `lib/src/modules/` and follow the `BusterModule` contract above. Include at least one initialization test in `test/dartbuster_test.dart`.
- **Core changes** (engine, HTTP client, formatter) should not break the `BusterModule` interface. If a breaking change is necessary, update all existing modules in the same PR.
- Run `dart analyze` and `dart test` before opening a PR — both must pass clean.
- Format with `dart format .`.

```bash
dart pub get
dart analyze
dart test
dart format --set-exit-if-changed .
```

---

## Licence

MIT — see [LICENSE](LICENSE).

---

*DartBuster is an independent project and is not affiliated with or endorsed by the GoBuster project or its authors.*
