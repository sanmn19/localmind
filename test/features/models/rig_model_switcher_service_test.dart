import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/models/data/rig_model_switcher_service.dart';

Dio _dioWith(
  Object? data, {
  int statusCode = 200,
  List<RequestOptions>? recorded,
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        recorded?.add(options);
        handler.resolve(
          Response(requestOptions: options, statusCode: statusCode, data: data),
        );
      },
    ),
  );
  return dio;
}

void main() {
  test('fetchRoster decodes name/label/served_model_name/enabled/active',
      () async {
    final service = RigModelSwitcherService(
      _dioWith({
        'models': [
          {
            'name': 'ds41-flash-1017',
            'label': 'DeepSeek V4.1 Flash',
            'served_model_name': 'DeepSeek-V4.1-Flash',
            'enabled': true,
            'active': false,
          },
        ],
      }),
    );

    final roster = await service.fetchRoster(Uri.parse('http://rig:9000'));

    expect(roster.single.name, 'ds41-flash-1017');
    expect(roster.single.label, 'DeepSeek V4.1 Flash');
    expect(roster.single.servedModelName, 'DeepSeek-V4.1-Flash');
    expect(roster.single.enabled, isTrue);
    expect(roster.single.active, isFalse);
  });

  test('fetchRoster accepts a bare JSON array and defaults enabled/active',
      () async {
    final service = RigModelSwitcherService(
      _dioWith([
        {'name': 'n1', 'label': 'N1', 'served_model_name': 'm1'},
      ]),
    );

    final roster = await service.fetchRoster(Uri.parse('http://rig:9000/'));

    expect(roster.single.enabled, isTrue);
    expect(roster.single.active, isFalse);
  });

  test('fetchStatus decodes phase/progress/stage/attempt/log_tail', () async {
    final service = RigModelSwitcherService(
      _dioWith({
        'phase': 'loading',
        'progress': 42,
        'target': 'ds41-flash-1017',
        'stage': 'weights',
        'attempt': 1,
        'max_attempts': 3,
        'log_tail': ['a', 'b'],
      }),
    );

    final status = await service.fetchStatus(Uri.parse('http://rig:9000'));

    expect(status.phase, 'loading');
    expect(status.progress, 42);
    expect(status.target, 'ds41-flash-1017');
    expect(status.stage, 'weights');
    expect(status.attempt, 1);
    expect(status.maxAttempts, 3);
    expect(status.logTail, ['a', 'b']);
    expect(status.isInFlight, isTrue);
    expect(status.isHealthy, isFalse);
  });

  test('switchTo POSTs /v1/switch/{name} and cancel POSTs /v1/cancel',
      () async {
    final recorded = <RequestOptions>[];
    final service = RigModelSwitcherService(
      _dioWith({'ok': true}, recorded: recorded),
    );

    await service.switchTo(Uri.parse('http://rig:9000/'), 'ds41 flash');
    await service.cancel(Uri.parse('http://rig:9000/'));

    expect(recorded[0].method, 'POST');
    expect(recorded[0].uri.toString(), 'http://rig:9000/v1/switch/ds41%20flash');
    expect(recorded[1].method, 'POST');
    expect(recorded[1].uri.toString(), 'http://rig:9000/v1/cancel');
  });

  test('a non-2xx switch response throws RigSwitcherException', () async {
    final service = RigModelSwitcherService(
      _dioWith({'error': 'model disabled'}, statusCode: 400),
    );

    expect(
      () => service.switchTo(Uri.parse('http://rig:9000'), 'n1'),
      throwsA(isA<RigSwitcherException>()),
    );
  });
}
