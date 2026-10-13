import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/chat/data/background_engine.dart';
import 'package:localmind/features/chat/data/background_task_service.dart';
import 'package:localmind/features/chat/data/models/background_task.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';

// Task-1 review #1 (binding): the resume bridge must tolerate the
// winding-down race. The parked loop lingers in the engine's registry until
// its abort future settles; a plain requestRun silently no-ops in that
// window. The bounded retry waits 150/300/600ms BEFORE each attempt and
// re-reads the authoritative row each time — a row that left `running`
// meanwhile stops the retrying WITHOUT enqueueing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('engine fake with a lagging loop removal: the enqueue lands after '
      'retries', () async {
    // The parked loop's registry entry survives until its whenComplete
    // removal fires — simulating an abort path that settles ~200ms in.
    var loopActive = true;
    Timer(const Duration(milliseconds: 200), () => loopActive = false);
    final enqueues = <String>[];

    final landed = await enqueueBackgroundResumeRun(
      taskId: 't-1',
      // requestRun mirror: refuses while the old loop is still registered.
      tryEnqueue: (id) {
        if (loopActive) return false;
        enqueues.add(id);
        return true;
      },
      readRow: (_) async => _resumableRow(),
    );

    expect(landed, isTrue);
    expect(
      enqueues,
      ['t-1'],
      reason: 'exactly ONE enqueue, only after the lag cleared',
    );
  });

  test('a row that leaves `running` mid-retries stops retrying without '
      'enqueueing', () async {
    var polls = 0;
    final enqueues = <String>[];

    final landed = await enqueueBackgroundResumeRun(
      taskId: 't-1',
      tryEnqueue: (id) {
        enqueues.add(id);
        return false; // the engine stays busy forever in this shape
      },
      readRow: (_) async {
        polls++;
        // Poll 1 (t≈150ms): still running. Poll 2 (t≈450ms): the row was
        // re-paused meanwhile — retrying must stop, never enqueue again.
        return polls >= 2
            ? _resumableRow(state: BackgroundTaskState.paused)
            : _resumableRow();
      },
    );

    expect(landed, isFalse);
    expect(polls, 2);
    expect(
      enqueues,
      hasLength(1),
      reason: 'only the attempt BEFORE the row left running',
    );
  });

  test('a still-lagging loop after the full retry window reports failure '
      '(never a silent dropped enqueue)', () async {
    final enqueues = <String>[];

    final landed = await enqueueBackgroundResumeRun(
      taskId: 't-1',
      tryEnqueue: (id) {
        enqueues.add(id);
        return false;
      },
      readRow: (_) async => _resumableRow(),
    );

    expect(landed, isFalse);
    expect(
      enqueues,
      hasLength(3),
      reason: 'the 150/300/600ms schedule makes exactly three attempts',
    );
  });

  test('actions.resume on a LAGGING parked loop does not silently lose the '
      'enqueue', () async {
    // The parked loop's registry entry lingers until its abort future
    // settles — the T2 lagging-loop fake pattern, now through the FULL
    // actions-provider closure. Fix round 1: the actions resume used to
    // call _ensureTaskRunning without `resumed: true`, dropping the
    // bounded retry for this exact shape.
    var loopActive = true;
    Timer(const Duration(milliseconds: 200), () => loopActive = false);
    final enqueues = <String>[];

    final container = ProviderContainer(
      overrides: [
        backgroundTasksServiceProvider.overrideWith((_) => _ActionsService()),
        backgroundEngineProvider.overrideWith(
          (_) => _LaggingEngine((id) {
            // requestRun mirror: refuses while the old loop is still
            // registered in the engine.
            if (loopActive) return false;
            enqueues.add(id);
            return true;
          }),
        ),
      ],
    );
    addTearDown(container.dispose);

    final actions = container.read(backgroundTaskActionsProvider);
    final resumed = await actions.resume('t-1');

    // Advance past a retry tick: attempt 1 (~150ms) is refused by the
    // lingering loop, attempt 2 (~450ms) lands after the lag cleared.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(resumed, isTrue);
    expect(
      enqueues,
      ['t-1'],
      reason: 'the enqueue lands exactly once, only after the lag cleared',
    );
  });
}

BackgroundTask _resumableRow({
  BackgroundTaskState state = BackgroundTaskState.running,
}) {
  return BackgroundTask(
    id: 't-1',
    ownerConversationId: 'owner-1',
    taskConversationId: 'task-c1',
    prompt: 'watch the mail',
    loopMinutes: 10,
    maxRuns: 10,
    runCount: 2,
    state: state,
    createdAt: DateTime.utc(2026, 10, 12, 9),
  );
}

/// Minimal service fake over the actions-provider resume seam: an
/// authoritative `taskById` read + a resumeTask flip, matching the
/// _PageBgService shape without the page harness.
class _ActionsService extends Fake implements BackgroundTasksService {
  BackgroundTask row = _resumableRow();

  @override
  Future<BackgroundTask?> taskById(String taskId) async => row;

  @override
  Future<bool> resumeTask(String taskId) async {
    row = _resumableRow();
    return true;
  }
}

/// Engine fake whose requestRun mirrors the parked-loop registry: refuse
/// while the lagging loop still occupies the slot.
class _LaggingEngine extends Fake implements BackgroundRunEngine {
  _LaggingEngine(this.tryRun);

  final bool Function(String taskId) tryRun;

  @override
  bool requestRun(String taskId) => tryRun(taskId);
}
