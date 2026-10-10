import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/providers/storage_providers.dart';
import 'skills_store.dart';

/// The filesystem host behind [skillsProvider]: one `.md` file per skill
/// under the app documents `skills/` directory. Tests override this with an
/// in-memory [SkillFileHost].
final skillsFileHostProvider = Provider<SkillFileHost>((ref) {
  return DirectorySkillFileHost(ref.watch(storageDirectoryProvider.future));
});

/// The in-memory skills mirror. The notifier performs no IO in
/// [SkillsNotifier.build] — bootstrap-style callers invoke
/// [SkillsNotifier.refresh] after startup so chat request assembly only
/// ever reads the snapshot synchronously.
final skillsProvider = NotifierProvider<SkillsNotifier, SkillsState>(() {
  return SkillsNotifier();
});

/// The provider snapshot: the settings kill switch plus the skill mirror.
class SkillsState {
  const SkillsState({required this.enabled, this.entries = const []});

  /// Mirrors `AppSettings.skillsEnabled` (default ON — the injection is the
  /// feature). When off, chat request assembly skips the section entirely.
  final bool enabled;

  final List<SkillEntry> entries;

  SkillsState copyWith({bool? enabled, List<SkillEntry>? entries}) {
    return SkillsState(
      enabled: enabled ?? this.enabled,
      entries: entries ?? this.entries,
    );
  }
}

class SkillsNotifier extends Notifier<SkillsState> {
  @override
  SkillsState build() {
    return SkillsState(enabled: ref.read(settingsProvider).skillsEnabled);
  }

  /// Re-reads the skills directory into the mirror. Called after bootstrap
  /// and (from the later tasks) by the skills UI and the skills MCP write
  /// tools, so the next request's system-builder picks the fresh snapshot
  /// up mid-conversation.
  Future<void> refresh() async {
    final settings = ref.read(settingsProvider);
    final entries = await SkillsStore(
      ref.read(skillsFileHostProvider),
    ).refresh();
    state = state.copyWith(enabled: settings.skillsEnabled, entries: entries);
  }

  /// Toggles the injection kill switch; persists it through the settings
  /// notifier (awaited so a hard kill cannot lose the flip).
  Future<void> setEnabled(bool value) async {
    state = state.copyWith(enabled: value);
    await ref
        .read(settingsProvider.notifier)
        .updateSettings(
          ref.read(settingsProvider).copyWith(skillsEnabled: value),
        );
  }
}
