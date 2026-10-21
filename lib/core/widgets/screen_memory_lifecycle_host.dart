import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import '../providers/screen_memory_providers.dart';

/// Runs the screen-memory lifecycle: watching `screenMemoryTickProvider` starts
/// and stops the sampler from settings, and opening or resuming the app drains the
/// sample queue. The Ask Local overlay triggers its own batch when it is shown.
class ScreenMemoryLifecycleHost extends ConsumerStatefulWidget {
  const ScreenMemoryLifecycleHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ScreenMemoryLifecycleHost> createState() =>
      _ScreenMemoryLifecycleHostState();
}

class _ScreenMemoryLifecycleHostState
    extends ConsumerState<ScreenMemoryLifecycleHost>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _batchNow());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _batchNow();
    }
  }

  void _batchNow() {
    if (!mounted) return;
    if (!ref.read(settingsProvider).screenMemoryEnabled) return;
    unawaited(ref.read(screenMemorySchedulerProvider).batchNow());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Starts/stops the sampler timers whenever the relevant settings change.
    ref.watch(screenMemoryTickProvider);
    return widget.child;
  }
}
