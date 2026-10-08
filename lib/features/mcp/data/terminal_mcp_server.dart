import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'web/web_fetch_service.dart';

const terminalMcpServerLabel = 'Terminal';
const terminalMcpServerUrl = 'local://terminal';

/// Exit code fed back when a run exceeded its timeout and was hard-killed.
const terminalTimeoutExitCode = -1;

const terminalRunTimeout = Duration(seconds: 15);
const terminalMaxChars = 6000;
const netHttpMaxChars = 8000;

/// Result of one sandboxed shell run.
class TerminalRunResult {
  const TerminalRunResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Executable seam so tests can fake shell runs while production code uses
/// a real `sh -c` child process inside the app sandbox.
abstract class TerminalProcessRunner {
  Future<TerminalRunResult> run(String command, {Duration timeout});
}

class ShellProcessRunner implements TerminalProcessRunner {
  const ShellProcessRunner();

  @override
  Future<TerminalRunResult> run(
    String command, {
    Duration timeout = terminalRunTimeout,
  }) async {
    final process = await Process.start('sh', ['-c', command]);

    final stdoutText = process.stdout
        .transform(utf8.decoder)
        .join();
    final stderrText = process.stderr
        .transform(utf8.decoder)
        .join();

    final exitCode = await process.exitCode
        .timeout(
          timeout,
          onTimeout: () {
            // Hard-kill so no runaway child survives the answer window.
            process.kill(ProcessSignal.sigkill);
            return terminalTimeoutExitCode;
          },
        );

    // After SIGKILL the streams close quickly; keep a belt-and-braces
    // guard so a wedged pipe can never hang the tool call past the kill.
    final guard = timeout + const Duration(seconds: 2);
    final stdout = await stdoutText.timeout(guard, onTimeout: () => '');
    final stderr = await stderrText.timeout(guard, onTimeout: () => '');

    return TerminalRunResult(
      exitCode: exitCode,
      stdout: stdout,
      stderr: stderr,
    );
  }
}

/// Partitioning of one terminal output payload: everything is model-readable
/// text, never thrown, and truncated with an explicit `[truncated]` marker.
String truncateTerminalOutput(String output, {int maxChars = terminalMaxChars}) {
  final text = output;
  if (text.length <= maxChars) return text;
  return '${text.substring(0, maxChars)}\n[truncated]';
}

/// Model-readable single-run formatting shared by the manager's dispatch.
String formatTerminalRunResult(
  TerminalRunResult result, {
  int maxChars = terminalMaxChars,
}) {
  final exitLine = result.exitCode == terminalTimeoutExitCode
      ? 'exit: timeout (process killed after hard-limit)'
      : 'exit: ${result.exitCode}';
  final stdout = result.stdout.trim();
  final stderr = result.stderr.trim();
  final body = StringBuffer('$exitLine\n');
  if (stdout.isNotEmpty) {
    body..writeln('stdout:')..writeln(stdout);
  }
  if (stderr.isNotEmpty) {
    body..writeln('stderr:')..writeln(stderr);
  }
  final rendered = body.toString().trimRight();
  return truncateTerminalOutput(rendered, maxChars: maxChars);
}

/// User-configured command allowlist that decides which `terminal.run`
/// invocations may skip the approval dialog.
///
/// Safety model (deliberately conservative): an entry whitelists a WHOLE
/// command line by its first token, but only when the rest of the line is a
/// plain single command. Any unquoted (or double-quoted) shell metacharacter
/// — pipes, semicolons, conditionals, redirections, backticks, command
/// substitution — disqualifies the call because the tail could smuggle an
/// arbitrary expression after the whitelisted first word. Those calls fall
/// back to the standard approval dialog instead of running silently.
class TerminalWhitelist {
  TerminalWhitelist(List<String> entries) : _entries = _normalize(entries);

  static const whitelistOnlyToolEntry = 'net.http';

  final List<String> _entries;

  List<String> get entries => List.unmodifiable(_entries);

  static List<String> _normalize(List<String> entries) => [
    for (final raw in entries)
      if (raw.trim().isNotEmpty && !raw.trim().startsWith('#')) raw.trim(),
  ];

  /// True when [command] may auto-run: its first whitespace token matches an
  /// entry exactly (case-sensitive) AND the line contains no shell
  /// metacharacter outside single quotes. An empty whitelist allows nothing.
  bool allows(String command) {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return false;
    if (_containsRedirectionRisk(trimmed)) return false;
    final firstToken = trimmed.split(RegExp(r'\s+')).first;
    return _entries.contains(firstToken);
  }

  /// Tool-level whitelist entry ([TerminalWhitelist.whitelistOnlyToolEntry])
  /// lets the HTTP tool auto-run without any command line at all.
  bool allowsTool(String toolName) => _entries.contains(toolName);

  /// Scans the line with shell quote semantics: inside single quotes nothing
  /// is special (a quoted `a|b` argument is fine); inside double quotes only
  /// backticks and `$(` keep expanding, so they stay forbidden there; outside
  /// quotes all of `| ; & > <` plus backticks and `$(` disqualify the call.
  static bool _containsRedirectionRisk(String command) {
    var inSingleQuote = false;
    var inDoubleQuote = false;
    for (var i = 0; i < command.length; i++) {
      final char = command[i];
      if (inSingleQuote) {
        if (char == "'") inSingleQuote = false;
        continue;
      }
      if (inDoubleQuote) {
        if (char == r'\') {
          i++;
          continue;
        }
        if (char == '"') inDoubleQuote = false;
        if (char == '`' || char == r'$') return true;
        continue;
      }
      if (char == r'\') {
        i++;
        continue;
      }
      if (char == "'") {
        inSingleQuote = true;
        continue;
      }
      if (char == '"') {
        inDoubleQuote = true;
        continue;
      }
      if (const {'|', ';', '&', '>', '<', '`'}.contains(char)) return true;
      if (char == r'$' &&
          i + 1 < command.length &&
          command[i + 1] == '(') {
        return true;
      }
    }
    return false;
  }
}

/// `net.http` — a curl substitute backed by Dio: any http(s) method, optional
/// headers and body, SSRF-guarded exactly like `web.fetch` (the guard runs
/// FIRST), 30s overall timeout, and output truncated with a `[truncated]`
/// marker. Every failure is an `ERROR: …` string for the model, never thrown.
class NetHttpTool {
  NetHttpTool({Dio? dio, int? maxResponseChars})
    : _dio = dio ?? _defaultDio(),
      _defaultMaxChars = maxResponseChars ?? netHttpMaxChars;

  final Dio _dio;
  final int _defaultMaxChars;

  Future<String> run({
    required String method,
    required String url,
    Map<String, String>? headers,
    String? body,
    int? maxChars,
  }) async {
    final limit = (maxChars ?? _defaultMaxChars).clamp(1, netHttpMaxChars);
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return 'ERROR: only http(s) URLs are supported';
    }
    // SSRF guard runs first, before any socket is opened.
    if (isBlockedFetchTarget(uri)) {
      return 'ERROR: refused to fetch a local/private address';
    }
    try {
      final response = await _dio.requestUri<String>(
        uri,
        data: body,
        options: Options(
          method: method.toUpperCase(),
          responseType: ResponseType.plain,
          headers: headers,
          // Bound the whole exchange so an API tool cannot stall a reply.
          sendTimeout: _totalTimeout,
          receiveTimeout: _totalTimeout,
        ),
      );
      final payload = response.data ?? '';
      final rendered = payload.isEmpty
          ? 'HTTP ${response.statusCode}'
          : 'HTTP ${response.statusCode}\n$payload';
      return _truncate(rendered, limit);
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      return 'ERROR: request failed${code == null ? '' : ' (HTTP $code)'}';
    } catch (_) {
      return 'ERROR: request failed';
    }
  }

  static const _totalTimeout = Duration(seconds: 30);

  static Dio _defaultDio() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: _totalTimeout,
      followRedirects: true,
      maxRedirects: 5,
      validateStatus: (code) =>
          code != null && code < 400 && code >= 200,
    ),
  );

  String _truncate(String text, int maxChars) {
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}\n[truncated]';
  }
}
