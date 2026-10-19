import 'package:dio/dio.dart';

import 'models/rig_model_entry.dart';
import 'models/rig_switch_status.dart';

class RigSwitcherException implements Exception {
  const RigSwitcherException(this.message);

  final String message;

  @override
  String toString() => 'RigSwitcherException: $message';
}

/// Client for the rig model switcher API (port 9000 by convention):
/// `GET /v1/list`, `GET /v1/status`, `POST /v1/switch/{name}`, `POST /v1/cancel`.
class RigModelSwitcherService {
  RigModelSwitcherService(this._dio);

  final Dio _dio;

  static const Duration _timeout = Duration(seconds: 10);

  Future<List<RigModelEntry>> fetchRoster(Uri base) async {
    final response = await _dio.get(_url(base, '/v1/list'), options: _options());
    _ensureSuccess(response, 'list');
    final data = response.data;
    final list = data is Map
        ? (data['models'] as List? ?? const [])
        : (data as List? ?? const []);
    return list.whereType<Map>().map(_entryFrom).toList();
  }

  Future<RigSwitchStatus> fetchStatus(Uri base) async {
    final response =
        await _dio.get(_url(base, '/v1/status'), options: _options());
    _ensureSuccess(response, 'status');
    final data = response.data;
    if (data is! Map) {
      throw const RigSwitcherException('Malformed status response');
    }
    return RigSwitchStatus(
      phase: (data['phase'] as String?) ?? 'idle',
      progress: (data['progress'] as num?)?.toInt() ?? 0,
      target: data['target'] as String?,
      stage: data['stage'] as String?,
      attempt: (data['attempt'] as num?)?.toInt() ?? 0,
      maxAttempts: (data['max_attempts'] as num?)?.toInt() ?? 0,
      logTail: (data['log_tail'] as List?)
              ?.map((line) => line.toString())
              .toList() ??
          const [],
      error: data['error'] as String?,
      message: data['message'] as String?,
    );
  }

  Future<void> switchTo(Uri base, String name) async {
    final response = await _dio.post(
      _url(base, '/v1/switch/${Uri.encodeComponent(name)}'),
      options: _options(),
    );
    _ensureSuccess(response, 'switch');
  }

  Future<void> cancel(Uri base) async {
    final response =
        await _dio.post(_url(base, '/v1/cancel'), options: _options());
    _ensureSuccess(response, 'cancel');
  }

  Options _options() => Options(
        receiveTimeout: _timeout,
        sendTimeout: _timeout,
        validateStatus: (status) => status != null && status < 500,
      );

  String _url(Uri base, String path) {
    final root = base.toString().replaceAll(RegExp(r'/+$'), '');
    return '$root$path';
  }

  void _ensureSuccess(Response response, String action) {
    final status = response.statusCode;
    if (status != null && status >= 200 && status < 300) return;
    final data = response.data;
    final detail = data is Map
        ? (data['error'] ?? data['message'])?.toString()
        : null;
    throw RigSwitcherException(
      detail == null || detail.isEmpty
          ? 'Model switcher $action failed (HTTP $status)'
          : detail,
    );
  }

  RigModelEntry _entryFrom(Map entry) => RigModelEntry(
        name: (entry['name'] as String?)?.trim() ?? '',
        label: (entry['label'] as String?)?.trim() ?? '',
        servedModelName:
            (entry['served_model_name'] as String?)?.trim() ?? '',
        enabled: entry['enabled'] as bool? ?? true,
        active: entry['active'] as bool? ?? false,
      );
}
