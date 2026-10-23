import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory secure storage: keeps the sync secrets out of the platform
/// keychain during tests.
class FakeSecureStorage extends Fake implements FlutterSecureStorage {
  final Map<String, String> values = {};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final args = invocation.namedArguments;
    if (invocation.memberName == #read) {
      return Future<String?>.value(values[args[#key] as String]);
    }
    if (invocation.memberName == #write) {
      final key = args[#key] as String;
      final value = args[#value] as String?;
      if (value == null) {
        values.remove(key);
      } else {
        values[key] = value;
      }
      return Future<void>.value();
    }
    if (invocation.memberName == #delete) {
      values.remove(args[#key] as String);
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

/// Points path_provider at [directory] for the current test.
void mockPathProvider(Directory directory) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  messenger.setMockMethodCallHandler(channel, (call) async {
    switch (call.method) {
      case 'getApplicationSupportDirectory':
      case 'getApplicationDocumentsDirectory':
      case 'getTemporaryDirectory':
      case 'getApplicationCacheDirectory':
        return directory.path;
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
}
