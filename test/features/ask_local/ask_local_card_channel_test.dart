import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/ask_local/data/ask_local_card_bootstrap.dart';
import 'package:localmind/features/ask_local/data/ask_local_card_channel.dart';

// Card-channel wrapper tests (task 4): fetches the newest staged payload
// (bounded retries), the Kotlin→Dart payload re-push + early closed-event
// handler registration and the execute-tool forward degrade/decode paths.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
  const channelName = 'localmind/ask_local_card';

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), null);
  });

  test('getInitialPayload resolves the newest delivery (staging + bootstrap)',
      () async {
    messenger.setMockMethodCallHandler(
      const MethodChannel(channelName),
      (call) async {
        expect(call.method, 'getInitialPayload');
        return <String, Object?>{
          'selectedText': 'pick',
          'capturePath': '/staged/a.png',
          'requestId': 'req-1',
          'bootstrap': {
            'requestId': 'req-1',
            'storeDir': '/docs/localmind_objectbox',
            'modelId': 'model-x',
            'server': {
              'id': 'srv',
              'name': 'remote',
              'type': 'openAICompatible',
              'host': '10.0.0.2',
              'port': 8000,
            },
            'params': <String, Object?>{},
            'toolDefs': <Object?>[],
            'settings': '{}',
          },
        };
      },
    );

    final delivery = await AskLocalCardChannel().requestInitialPayload(
      retryDelays: const [Duration(milliseconds: 1)],
    );
    expect(delivery, isNotNull);
    expect(delivery!.payload.selectedText, 'pick');
    expect(delivery.deliveryId, 'req-1');
    expect(delivery.bootstrap, isNotNull);
    expect(delivery.bootstrap!.modelId, 'model-x');
  });

  test('getInitialPayload resolves null after bounded retries (no host)',
      () async {
    final delivery = await AskLocalCardChannel().requestInitialPayload(
      retryDelays: const [],
    );
    expect(delivery, isNull);
  });

  test('payload re-pushes hit the registered listener exactly once each; '
      'closed pushes call the reap callback; malformed pushes dropped',
      () async {
    final channel = AskLocalCardChannel();
    final updates = <(AskLocalCardDelivery, bool)>[];
    var reaps = 0;
    channel.manage((delivery, force) => updates.add((delivery, force)), () => reaps++);

    Future<void> push(String method, Object? args) async {
      await messenger.handlePlatformMessage(
        channelName,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (data) {},
      );
    }

    await push(
      AskLocalCardBootstrapKeys.payloadUpdateCardMethod,
      <String, Object?>{'selectedText': 'fresh pick', 'requestId': 'req-2'},
    );
    await push('askLocalCardClosed', null);
    await push(
      AskLocalCardBootstrapKeys.payloadUpdateCardMethod,
      <String, Object?>{},
    );

    await Future<void>.delayed(Duration.zero);
    expect(updates, hasLength(1));
    expect(updates.single.$1.payload.selectedText, 'fresh pick');
    expect(updates.single.$2, isFalse);
    expect(reaps, 1);
  });

  test('executeTool decodes the main-engine success envelope', () async {
    messenger.setMockMethodCallHandler(
      const MethodChannel(channelName),
      (call) async {
        expect(call.method, AskLocalCardBootstrapKeys.executeToolCardMethod);
        expect(call.arguments['toolName'], 'mail.send');
        return {'success': true, 'output': 'mail sent', 'error': null};
      },
    );
    final outcome =
        await AskLocalCardChannel().executeTool('mail.send', {'to': 'a@b.c'});
    expect(outcome.success, isTrue);
    expect(outcome.output, 'mail sent');
  });

  test('executeTool degrades when the main engine has no handler', () async {
    final outcome =
        await AskLocalCardChannel().executeTool('mail.send', {'to': 'a@b.c'});
    expect(outcome.success, isFalse);
    expect(outcome.error, isNotNull);
  });

  test('captureNow degrades to null (no host / off service)', () async {
    expect(await AskLocalCardChannel().captureNow(), isNull);
  });
}
