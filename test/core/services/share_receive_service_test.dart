import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/services/share_receive_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('localmind/share_receive_test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  ShareReceiveService buildService() {
    final service = ShareReceiveService(
      channel: channel,
      supportedPlatform: true,
    );
    addTearDown(service.dispose);
    return service;
  }

  test('emits a cold-start text share from consumePendingShare', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'consumePendingShare');
      return {
        'pending': true,
        'payload': {'kind': 'text', 'text': 'Hello from another app'},
      };
    });
    final service = buildService();
    final payloads = <SharedPayload>[];
    final subscription = service.payloads.listen(payloads.add);
    addTearDown(subscription.cancel);

    await service.initialize();
    await Future<void>.delayed(Duration.zero);

    expect(payloads, hasLength(1));
    expect(payloads.first.kind, SharePayloadKind.text);
    expect(payloads.first.text, 'Hello from another app');
  });

  test('emits nothing when no share is pending', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return {'pending': false, 'payload': null};
    });
    final service = buildService();
    final payloads = <SharedPayload>[];
    final subscription = service.payloads.listen(payloads.add);
    addTearDown(subscription.cancel);

    await service.initialize();
    await Future<void>.delayed(Duration.zero);

    expect(payloads, isEmpty);
  });

  test('emits a live single-file share pushed over the channel', () async {
    final service = buildService();
    final payloads = <SharedPayload>[];
    final subscription = service.payloads.listen(payloads.add);
    addTearDown(subscription.cancel);
    // initialize() wires the native `shareReceived` handler before the push.
    messenger.setMockMethodCallHandler(channel, (call) async {
      return {'pending': false, 'payload': null};
    });
    await service.initialize();
    await Future<void>.delayed(Duration.zero);
    payloads.clear();

    Object? ack;
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('shareReceived', {
          'payload': {
            'kind': 'file',
            'path': '/data/cache/share/172800.png',
            'mimeType': 'image/png',
          },
        }),
      ),
      (data) {
        ack = data == null
            ? null
            : const StandardMethodCodec().decodeEnvelope(data);
      },
    );
    await Future<void>.delayed(Duration.zero);

    expect(payloads, hasLength(1));
    expect(payloads.first.kind, SharePayloadKind.file);
    expect(payloads.first.filePath, '/data/cache/share/172800.png');
    expect(payloads.first.mimeType, 'image/png');
    // Ack: the Dart handler must echo a truthy reply so the native side
    // clears its pending stash (same contract as the assistant channel).
    expect(ack, isTrue);
  });

  test('decodes multi-image shares with per-file mime types', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'consumePendingShare') {
        return {
          'pending': true,
          'payload': {
            'kind': 'files',
            'paths': ['/a/one.png', '/a/two.jpg'],
            'mimeTypes': ['image/png', 'image/jpeg'],
          },
        };
      }
      return null;
    });
    final service = buildService();
    final payloads = <SharedPayload>[];
    final subscription = service.payloads.listen(payloads.add);
    addTearDown(subscription.cancel);

    await service.initialize();
    await Future<void>.delayed(Duration.zero);

    expect(payloads, hasLength(1));
    expect(payloads.first.kind, SharePayloadKind.files);
    expect(payloads.first.paths, ['/a/one.png', '/a/two.jpg']);
    expect(payloads.first.mimeTypes, ['image/png', 'image/jpeg']);
  });

  test('drops malformed share payloads instead of throwing', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'consumePendingShare') {
        return {
          'pending': true,
          'payload': {'kind': '???'},
        };
      }
      return null;
    });
    final service = buildService();
    final payloads = <SharedPayload>[];
    final subscription = service.payloads.listen(payloads.add);
    addTearDown(subscription.cancel);

    await service.initialize();
    await Future<void>.delayed(Duration.zero);

    expect(payloads, isEmpty);
  });

  test('does not call native code on unsupported platforms', () async {
    var called = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      called = true;
      return null;
    });
    final service = ShareReceiveService(
      channel: channel,
      supportedPlatform: false,
    );
    addTearDown(service.dispose);

    await service.initialize();

    expect(called, isFalse);
  });
}
