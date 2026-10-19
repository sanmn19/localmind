import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/rig_model_entry.dart';
import '../data/rig_model_switcher_service.dart';

final rigSwitcherServiceProvider = Provider<RigModelSwitcherService>((ref) {
  final dio = Dio(
    BaseOptions(connectTimeout: const Duration(seconds: 10)),
  );
  return RigModelSwitcherService(dio);
});

/// The switcher roster, or `null` when the switcher is unreachable. The merge
/// calls this on every detection, so it is intentionally uncached.
final rigRosterProvider =
    FutureProvider.family<List<RigModelEntry>?, String>((
  ref,
  switcherUrl,
) async {
  final uri = Uri.tryParse(switcherUrl.trim());
  if (uri == null || !uri.hasScheme) return null;
  try {
    return await ref.watch(rigSwitcherServiceProvider).fetchRoster(uri);
  } catch (_) {
    return null;
  }
});
