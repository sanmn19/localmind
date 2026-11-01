import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/memories/data/screen_text_gateway.dart';

class _FakeChannel extends MethodChannel {
  _FakeChannel(this.payload) : super('localmind/screen');

  final Object? payload;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async =>
      payload as T?;
}

class _ThrowingChannel extends MethodChannel {
  _ThrowingChannel() : super('localmind/screen');

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    throw PlatformException(code: 'read_failed');
  }
}

class _StalledChannel extends MethodChannel {
  _StalledChannel() : super('localmind/screen');

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) =>
      Completer<T?>().future;
}

void main() {
  test('the gateway decodes the channel payload', () async {
    final gateway = MethodChannelScreenTextGateway(
      channel: _FakeChannel({
        'packageName': 'com.whatsapp',
        'text': 'Standup 10:00',
        'isInteractive': true,
      }),
    );
    final screen = await gateway.readText();
    expect(screen!.packageName, 'com.whatsapp');
    expect(screen.text, 'Standup 10:00');
    expect(screen.isInteractive, isTrue);
  });

  test('a missing payload reads as null', () async {
    final gateway = MethodChannelScreenTextGateway(
      channel: _FakeChannel(null),
    );
    expect(await gateway.readText(), isNull);
  });

  test('a platform error reads as null', () async {
    final gateway = MethodChannelScreenTextGateway(
      channel: _ThrowingChannel(),
    );
    expect(await gateway.readText(), isNull);
  });

  test('a stalled channel times out as null', () async {
    final gateway = MethodChannelScreenTextGateway(
      channel: _StalledChannel(),
      timeout: const Duration(milliseconds: 10),
    );
    expect(await gateway.readText(), isNull);
  });

  test('the noop gateway reads as null', () async {
    expect(await const NoopScreenTextGateway().readText(), isNull);
  });
}
