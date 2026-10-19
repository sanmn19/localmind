import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/enums.dart';

import '../data/models/model_info.dart';
import '../data/models/rig_model_entry.dart';
import '../data/models/rig_switch_status.dart';
import 'rig_switcher_providers.dart';
import '../../servers/providers/server_providers.dart';

class RigLoadState {
  const RigLoadState({
    required this.serverId,
    required this.modelId,
    required this.status,
    required this.active,
  });

  final String serverId;

  final String modelId;

  final RigSwitchStatus status;

  /// True while the load owns the rig (from `start` until healthy/failed).
  final bool active;

  RigLoadState copyWith({RigSwitchStatus? status, bool? active}) {
    return RigLoadState(
      serverId: serverId,
      modelId: modelId,
      status: status ?? this.status,
      active: active ?? this.active,
    );
  }
}

final rigLoadProvider = NotifierProvider<RigLoadNotifier, RigLoadState?>(
  RigLoadNotifier.new,
);

/// Drives one switch at a time: `POST /v1/switch/{name}`, then polls
/// `GET /v1/status` until healthy/failed. The switch itself runs on the rig —
/// disposing this notifier (app closed) never cancels it.
class RigLoadNotifier extends Notifier<RigLoadState?> {
  static Duration pollInterval = const Duration(seconds: 3);

  Timer? _timer;
  Uri? _base;
  String? _serverId;
  String? _modelId;
  RigModelEntry? _target;
  void Function()? _onLoaded;
  String? _switcherUrl;

  @override
  RigLoadState? build() {
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
    });
    return null;
  }

  Future<void> start(
    Uri base,
    String serverId,
    ModelInfo model,
    RigModelEntry target, {
    void Function()? onLoaded,
  }) async {
    final current = state;
    if (current != null && current.active) return;

    _base = base;
    _switcherUrl = base.toString();
    _serverId = serverId;
    _modelId = model.id;
    _target = target;
    _onLoaded = onLoaded;
    state = RigLoadState(
      serverId: serverId,
      modelId: model.id,
      status: RigSwitchStatus(
        phase: 'starting',
        progress: 0,
        target: target.name,
      ),
      active: true,
    );

    try {
      await ref.read(rigSwitcherServiceProvider).switchTo(base, target.name);
    } catch (error) {
      state = RigLoadState(
        serverId: serverId,
        modelId: model.id,
        status: RigSwitchStatus(
          phase: 'failed',
          progress: 0,
          error: error.toString(),
        ),
        active: false,
      );
      return;
    }

    _poll(base, onLoaded);
  }

  /// Resumes an in-flight switch after an app restart (the rig kept working).
  Future<void> resumeIfInFlight(
    Uri base,
    String serverId, {
    void Function()? onLoaded,
  }) async {
    if (state?.active ?? false) return;
    try {
      final status = await ref
          .read(rigSwitcherServiceProvider)
          .fetchStatus(base);
      if (!ref.mounted || !status.isInFlight) return;
      _base = base;
      _serverId = serverId;
      state = RigLoadState(
        serverId: serverId,
        modelId: status.target ?? '',
        status: status,
        active: true,
      );
      _poll(base, onLoaded);
    } catch (_) {
      // No switcher reachable: nothing to resume.
    }
  }

  /// Retries the last failed switch with the same target.
  Future<void> retry() async {
    final base = _base;
    final serverId = _serverId;
    final modelId = _modelId;
    final target = _target;
    if (base == null || serverId == null || modelId == null || target == null) {
      return;
    }
    state = null;
    await start(
      base,
      serverId,
      ModelInfo(
        id: modelId,
        name: modelId,
        serverType: ServerType.openAICompatible,
        serverId: serverId,
      ),
      target,
      onLoaded: _onLoaded,
    );
  }

  /// Provider deletion: stop polling its switch (never calls `/v1/cancel`).
  void resetForServer(String serverId) {
    if (state?.serverId != serverId) return;
    _timer?.cancel();
    _timer = null;
    state = null;
  }

  /// Explicit user cancellation (the only path that calls `/v1/cancel`).
  Future<void> cancel() async {
    final current = state;
    final base = _base;
    _timer?.cancel();
    _timer = null;
    if (current == null || base == null) return;
    await ref.read(rigSwitcherServiceProvider).cancel(base);
    state = null;
  }

  void _poll(Uri base, void Function()? onLoaded) {
    _timer?.cancel();
    _timer = Timer.periodic(pollInterval, (timer) async {
      final latest = state;
      if (latest == null) {
        timer.cancel();
        return;
      }
      try {
        final status = await ref
            .read(rigSwitcherServiceProvider)
            .fetchStatus(base);
        if (!ref.mounted) {
          timer.cancel();
          return;
        }
        final current = state;
        if (current == null) {
          timer.cancel();
          return;
        }
        if (status.isHealthy) {
          // The rig can report the PREVIOUS model's healthy state while the
          // switch is still queued; only this load's target counts.
          final superseded = status.target != null &&
              status.target != _target?.name;
          timer.cancel();
          if (superseded) {
            state = null;
            return;
          }
          ref.invalidate(availableModelsProvider(latest.serverId));
          final switcherUrl = _switcherUrl;
          if (switcherUrl != null) {
            ref.invalidate(rigRosterProvider(switcherUrl));
          }
          state = null;
          (onLoaded ?? _onLoaded)?.call();
        } else if (status.isFailed) {
          timer.cancel();
          state = current.copyWith(status: status, active: false);
        } else {
          state = current.copyWith(status: status);
        }
      } catch (_) {
        // Transient status failure: keep polling.
      }
    });
  }
}
