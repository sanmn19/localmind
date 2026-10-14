import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/ask_local/data/ask_local_payload.dart';

void main() {
  group('AskLocalRequestPayload contract', () {
    test('round-trips selectedText and capturePath through channel args', () {
      const payload = AskLocalRequestPayload(
        selectedText: 'line one\nline two',
        capturePath: '/cache/ask_local_screenshots/ask_local_1.png',
      );
      final decoded = AskLocalRequestPayload.fromMap(payload.toChannelArgs());
      expect(decoded, isNotNull);
      expect(decoded!.selectedText, payload.selectedText);
      expect(decoded.capturePath, payload.capturePath);
    });

    test('capturePath is optional (capture off / failed)', () {
      final decoded = AskLocalRequestPayload.fromMap(<String, Object?>{
        'selectedText': 'just the pick',
      });
      expect(decoded!.selectedText, 'just the pick');
      expect(decoded.capturePath, isNull);
    });

    test('null capturePath survives the round trip', () {
      const payload = AskLocalRequestPayload(selectedText: 'no shot');
      final decoded = AskLocalRequestPayload.fromMap(payload.toChannelArgs());
      expect(decoded!.capturePath, isNull);
      expect(decoded.toChannelArgs()['capturePath'], isNull);
    });

    test('foreign or malformed args decode to null', () {
      expect(AskLocalRequestPayload.fromMap(null), isNull);
      expect(AskLocalRequestPayload.fromMap('nope'), isNull);
      expect(AskLocalRequestPayload.fromMap(<String, Object?>{}), isNull);
    });
  });

  group('ask_local channel-listener registration', () {
    test('re-registering the same listener never double-delivers', () {
      final arrivals = AskLocalRequestArrivals();
      final payloads = <AskLocalRequestPayload>[];
      void listener(AskLocalRequestPayload payload) => payloads.add(payload);

      arrivals.register(listener);
      arrivals.register(listener);

      arrivals.deliver(const AskLocalRequestPayload(
        selectedText: 'sel',
        capturePath: null,
      ).toChannelArgs());

      expect(payloads.length, 1);
      expect(payloads.single.selectedText, 'sel');
      expect(payloads.single.capturePath, isNull);
    });

    test('mid-stream re-registration swaps listeners, still one delivery', () {
      final arrivals = AskLocalRequestArrivals();
      var firstCalls = 0;
      var secondCalls = 0;
      arrivals.register((_) => firstCalls++);
      arrivals.register((_) => secondCalls++);

      arrivals.deliver(<String, Object?>{'selectedText': 'pick'});

      expect(firstCalls, 0);
      expect(secondCalls, 1);
    });

    test('malformed pushes are dropped without calling the listener', () {
      final arrivals = AskLocalRequestArrivals();
      var calls = 0;
      arrivals.register((_) => calls++);
      arrivals.deliver(null);
      arrivals.deliver(<String, Object?>{'capturePath': '/x.png'});
      expect(calls, 0);
    });
  });

  test('channel constants match the Kotlin side', () {
    expect(AskLocalRequestPayload.askLocalChannel, 'localmind/ask_local');
    expect(
      AskLocalRequestPayload.askLocalRequestArrivedMethod,
      'askLocalRequestArrived',
    );
    expect(AskLocalRequestPayload.captureNowMethod, 'captureNow');
    expect(
      AskLocalRequestPayload.isCaptureAvailableMethod,
      'isCaptureAvailable',
    );
    expect(AskLocalRequestPayload.openOverlayNowMethod, 'openOverlayNow');
    expect(
      AskLocalRequestPayload.consumePendingMethod,
      'consumePendingAskLocal',
    );
  });
}
