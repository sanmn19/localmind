import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/chat/data/mcp_client.dart';
import 'package:localmind/features/chat/data/mcp_server_manager.dart';
import 'package:localmind/features/mcp/data/terminal_mcp_server.dart';

import 'web/stub_dio_adapter.dart';

class _FakeRunner implements TerminalProcessRunner {
  _FakeRunner(this.result);

  final TerminalRunResult result;

  @override
  Future<TerminalRunResult> run(
    String command, {
    Duration timeout = terminalRunTimeout,
  }) async {
    ranCommands.add(command);
    ranTimeouts.add(timeout);
    return result;
  }

  final ranCommands = <String>[];
  final ranTimeouts = <Duration>[];
}

Future<McpServerManager> _managerWith(
  _FakeRunner runner, {
  TerminalWhitelist? whitelist,
}) async {
  final manager = McpServerManager();
  await manager.addTerminalServer(
    TerminalServices(
      runner: runner,
      http: NetHttpTool(
        dio: Dio()
          ..httpClientAdapter = StubAdapter({
            'https://api.example.com/data': const StubResponse(200, 'payload'),
            'https://api.example.com/big': StubResponse(200, 'x' * 12000),
          }),
      ),
      whitelist: whitelist ?? TerminalWhitelist(const []),
    ),
  );
  return manager;
}

void main() {
  TerminalRunResult okRunner() =>
      const TerminalRunResult(exitCode: 0, stdout: '', stderr: '');

  group('terminal mcp server registration', () {
    test(
      'addTerminalServer advertises both tools with the local url',
      () async {
        final manager = await _managerWith(_FakeRunner(okRunner()));

        expect(manager.hasTerminalServer(), isTrue);
        expect(manager.hasServer(terminalMcpServerLabel), isTrue);
        expect(
          manager.getServerUrl(terminalMcpServerLabel),
          terminalMcpServerUrl,
        );
        expect(manager.serverLabels, contains(terminalMcpServerLabel));
        final toolNames = manager
            .getTools(terminalMcpServerLabel)
            .map((t) => t.name)
            .toSet();
        expect(toolNames, {'terminal.run', 'net.http'});
        expect(manager.hasWebServer(), isFalse);
      },
    );

    test('re-registration replaces without duplicating', () async {
      final manager = McpServerManager();
      final runner = _FakeRunner(okRunner());
      await manager.addTerminalServer(_services(runner));
      await manager.addTerminalServer(_services(runner));

      expect(manager.getTools(terminalMcpServerLabel), hasLength(2));
      expect(manager.getTerminalServices(), isNotNull);
      expect(manager.serverCount, 1);
    });

    test('removeServer and clear tear the terminal server down', () async {
      final manager = await _managerWith(_FakeRunner(okRunner()));
      await manager.removeServer(terminalMcpServerLabel);
      expect(manager.hasTerminalServer(), isFalse);
      expect(manager.getTerminalServices(), isNull);

      final manager2 = await _managerWith(_FakeRunner(okRunner()));
      await manager2.clear();
      expect(manager2.hasTerminalServer(), isFalse);
      expect(manager2.hasServer(terminalMcpServerLabel), isFalse);
    });
  });

  group('terminal.run dispatch', () {
    test('formats exit code, stdout and stderr output', () async {
      final runner = _FakeRunner(
        const TerminalRunResult(
          exitCode: 2,
          stdout: 'alpha\nbeta',
          stderr: 'boom',
        ),
      );
      final manager = await _managerWith(runner);

      final output = await manager.callTool(
        terminalMcpServerLabel,
        'terminal.run',
        {'command': 'ls /data'},
      );

      expect(output, contains('exit: 2'));
      expect(output, contains('stdout:'));
      expect(output, contains('alpha\nbeta'));
      expect(output, contains('stderr:'));
      expect(output, contains('boom'));
      expect(runner.ranCommands, contains('ls /data'));
      // The 15s hard-kill timeout is passed down to the runner.
      expect(runner.ranTimeouts.single, terminalRunTimeout);
    });

    test('a killed-by-timeout run reports the timeout sentinel', () async {
      final manager = await _managerWith(_FakeRunner(
        const TerminalRunResult(
          exitCode: terminalTimeoutExitCode,
          stdout: 'partial',
          stderr: '',
        ),
      ));

      final output = await manager.callTool(
        terminalMcpServerLabel,
        'terminal.run',
        {'command': 'sleep 9999'},
      );
      expect(output, contains('exit: timeout'));
    });

    test('long output is truncated with the marker', () async {
      final manager = await _managerWith(_FakeRunner(
        TerminalRunResult(exitCode: 0, stdout: 'y' * 9000, stderr: ''),
      ));

      final output = await manager.callTool(
        terminalMcpServerLabel,
        'terminal.run',
        {'command': 'cat big.txt'},
      );
      expect(output, contains('[truncated]'));
      expect(output.length, lessThan(6600));
    });

    test('requires a string command', () async {
      final manager = await _managerWith(_FakeRunner(okRunner()));
      expect(
        () => manager.callTool(terminalMcpServerLabel, 'terminal.run', {}),
        throwsA(isA<McpException>()),
      );
      expect(
        () => manager.callTool(terminalMcpServerLabel, 'terminal.run', {
          'command': 42,
        }),
        throwsA(isA<McpException>()),
      );
    });

    test('unknown tool names raise McpException', () async {
      final manager = await _managerWith(_FakeRunner(okRunner()));
      expect(
        () => manager.callTool(terminalMcpServerLabel, 'terminal.nope', {
          'command': 'ls',
        }),
        throwsA(isA<McpException>()),
      );
    });
  });

  group('net.http dispatch', () {
    test('performs a GET and prefixes the status line', () async {
      final manager = await _managerWith(_FakeRunner(okRunner()));

      final output = await manager.callTool(
        terminalMcpServerLabel,
        'net.http',
        {'url': 'https://api.example.com/data'},
      );
      expect(output, contains('HTTP 200'));
      expect(output, contains('payload'));
    });

    test('refuses local/private targets before any request', () async {
      final adapter = StubAdapter({});
      final manager = McpServerManager();
      await manager.addTerminalServer(
        TerminalServices(
          runner: _FakeRunner(okRunner()),
          http: NetHttpTool(dio: Dio()..httpClientAdapter = adapter),
          whitelist: TerminalWhitelist(const []),
        ),
      );

      for (final url in [
        'http://127.0.0.1/x',
        'http://localhost/x',
        'http://192.168.1.5/x',
        'http://100.126.102.37/x',
      ]) {
        final output = await manager.callTool(
          terminalMcpServerLabel,
          'net.http',
          {'url': url},
        );
        expect(
          output,
          contains('ERROR: refused to fetch a local/private address'),
          reason: '$url must be refused',
        );
      }
      expect(adapter.routes, isEmpty);
    });

    test('http errors surface as ERROR strings, never thrown', () async {
      final manager = McpServerManager();
      await manager.addTerminalServer(
        TerminalServices(
          runner: _FakeRunner(okRunner()),
          http: NetHttpTool(
            dio: Dio()
              ..httpClientAdapter = StubAdapter({
                'https://api.example.com/missing': const StubResponse(
                  404,
                  'nope',
                ),
              }),
          ),
          whitelist: TerminalWhitelist(const []),
        ),
      );

      final output = await manager.callTool(
        terminalMcpServerLabel,
        'net.http',
        {'url': 'https://api.example.com/missing'},
      );
      expect(output, contains('ERROR: request failed (HTTP 404)'));
    });

    test('body over the limit is truncated with the marker', () async {
      final manager = await _managerWith(_FakeRunner(okRunner()));

      final output = await manager.callTool(
        terminalMcpServerLabel,
        'net.http',
        {'url': 'https://api.example.com/big'},
      );
      expect(output, contains('[truncated]'));
    });

    test('requires a url and clamps max_chars', () async {
      final manager = await _managerWith(_FakeRunner(okRunner()));
      expect(
        () => manager.callTool(terminalMcpServerLabel, 'net.http', {}),
        throwsA(isA<McpException>()),
      );
    });

    test('non-http schemes are refused', () async {
      final manager = await _managerWith(_FakeRunner(okRunner()));
      final output = await manager.callTool(
        terminalMcpServerLabel,
        'net.http',
        {'url': 'file:///etc/passwd'},
      );
      expect(output, contains('ERROR: only http(s) URLs are supported'));
    });
  });
}

TerminalServices _services(_FakeRunner runner) => TerminalServices(
  runner: runner,
  http: NetHttpTool(dio: Dio()..httpClientAdapter = StubAdapter(const {})),
  whitelist: TerminalWhitelist(const []),
);
