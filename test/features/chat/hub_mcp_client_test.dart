import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/chat/data/hub_mcp_client.dart';
import 'package:localmind/features/chat/data/mcp_client.dart';
import 'package:localmind/features/chat/data/mcp_server_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(hubMcpChannelName);
  final calls = <MethodCall>[];

  const catalogue = {
    'protocolVersion': 1,
    'tools': [
      {
        'name': 'dev.mcphub.testpublisher.echo',
        'description': 'Answer ok, so a caller can see the call ran',
        'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
        'readOnly': true,
        'available': true,
      },
    ],
  };

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'initialize':
              return {'tools': true, 'resources': false, 'prompts': false};
            case 'listTools':
              return jsonEncode(catalogue);
            case 'callTool':
              final arguments = Map<String, dynamic>.from(
                call.arguments as Map,
              );
              switch (arguments['name']) {
                case 'dev.mcphub.testpublisher.echo':
                  return {
                    'resultJson': jsonEncode({
                      'content': [
                        {'type': 'text', 'text': 'ok'},
                      ],
                    }),
                    'body': null,
                  };
                case 'dev.mcphub.testpublisher.big':
                  return {
                    'resultJson': jsonEncode({
                      'content': [
                        {'type': 'text', 'text': 'see descriptor'},
                      ],
                    }),
                    'body': 'the descriptor payload',
                  };
                case 'dev.mcphub.testpublisher.plain':
                  return {'resultJson': 'ok', 'body': null};
                default:
                  return {
                    'resultJson': jsonEncode({'content': <dynamic>[]}),
                    'body': null,
                  };
              }
            case 'readResource':
              throw PlatformException(
                code: 'resources_unsupported',
                message: 'MCP Hub does not expose resources',
              );
            case 'close':
              return null;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('HubMcpClient', () {
    test('initialize maps the hub capabilities', () async {
      final client = HubMcpClient(channel: channel, version: '9.9.9');

      final capabilities = await client.initialize();

      expect(client.isInitialized, isTrue);
      expect(capabilities.tools, isTrue);
      expect(capabilities.resources, isFalse);
      expect(capabilities.prompts, isFalse);
      expect(calls.single.method, 'initialize');
      expect(calls.single.arguments, {
        'clientInfo': {'name': 'localmind', 'version': '9.9.9'},
      });
    });

    test('listTools maps the hub catalogue to McpTool models', () async {
      final client = HubMcpClient(channel: channel);

      final tools = await client.listTools();

      expect(tools, hasLength(1));
      expect(tools.single.name, 'dev.mcphub.testpublisher.echo');
      expect(
        tools.single.description,
        'Answer ok, so a caller can see the call ran',
      );
      expect(tools.single.inputSchema, {
        'type': 'object',
        'properties': <String, dynamic>{},
      });
      expect(calls.map((call) => call.method), ['initialize', 'listTools']);
    });

    test(
      'callTool sends JSON arguments and returns the first text block',
      () async {
        final client = HubMcpClient(channel: channel);

        final result = await client.callTool('dev.mcphub.testpublisher.echo', {
          'message': 'hello',
        });

        expect(result, 'ok');
        final call = calls.last;
        expect(call.method, 'callTool');
        expect(call.arguments, {
          'name': 'dev.mcphub.testpublisher.echo',
          'arguments': jsonEncode({'message': 'hello'}),
        });
      },
    );

    test('callTool prefers a non-null descriptor body', () async {
      final client = HubMcpClient(channel: channel);

      final result = await client.callTool(
        'dev.mcphub.testpublisher.big',
        const {},
      );

      expect(result, 'the descriptor payload');
    });

    test('callTool returns bare text from a non-result payload', () async {
      final client = HubMcpClient(channel: channel);

      final result = await client.callTool(
        'dev.mcphub.testpublisher.plain',
        const {},
      );

      expect(result, 'ok');
    });

    test('callTool returns empty text for an empty content list', () async {
      final client = HubMcpClient(channel: channel);

      final result = await client.callTool(
        'dev.mcphub.testpublisher.empty',
        const {},
      );

      expect(result, '');
    });

    test(
      'listResources is empty because the hub has no resource surface',
      () async {
        final client = HubMcpClient(channel: channel);

        expect(await client.listResources(), isEmpty);
      },
    );

    test('readResource surfaces the hub protocol error', () async {
      final client = HubMcpClient(channel: channel);

      await expectLater(
        client.readResource('mem://one'),
        throwsA(
          isA<McpException>().having(
            (error) => error.message,
            'message',
            contains('MCP Hub does not expose resources'),
          ),
        ),
      );
      expect(calls.last.method, 'readResource');
      expect(calls.last.arguments, {'uri': 'mem://one'});
    });

    test('close invokes the host and resets initialization state', () async {
      final client = HubMcpClient(channel: channel);
      await client.initialize();

      await client.close();

      expect(client.isInitialized, isFalse);
      expect(client.capabilities, isNull);
      expect(calls.last.method, 'close');
    });
  });

  group('McpServerManager hub wiring', () {
    test('addServer uses HubMcpClient for binder://hub', () async {
      final manager = McpServerManager();

      await manager.addServer(hubMcpServerLabel, hubMcpServerUrl);

      expect(manager.hasHubServer(), isTrue);
      expect(manager.hasServer(hubMcpServerLabel), isTrue);
      expect(manager.getServerUrl(hubMcpServerLabel), hubMcpServerUrl);
      expect(manager.getCapabilities(hubMcpServerLabel)?.tools, isTrue);
      expect(
        manager.getTools(hubMcpServerLabel).single.name,
        'dev.mcphub.testpublisher.echo',
      );
      expect(calls.map((call) => call.method), ['initialize', 'listTools']);
    });

    test('addHubServer registers the built-in label', () async {
      final manager = McpServerManager();

      expect(await manager.addHubServer(), isTrue);

      expect(manager.hasHubServer(), isTrue);
      expect(manager.getServerUrl(hubMcpServerLabel), hubMcpServerUrl);
    });

    test('addHubServer reports unavailable when the bind fails', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(
              code: 'hub_unavailable',
              message: 'MCP Hub is not installed',
            );
          });
      final manager = McpServerManager();

      expect(await manager.addHubServer(), isFalse);

      expect(manager.hasHubServer(), isFalse);
    });
  });
}
