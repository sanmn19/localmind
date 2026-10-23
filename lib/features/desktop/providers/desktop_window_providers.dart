import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/storage_providers.dart';
import '../data/desktop_layout_store.dart';
import '../data/models/desktop_window.dart';

final desktopLayoutStoreProvider = Provider<DesktopLayoutStore>((ref) {
  return DesktopLayoutStore(ref.watch(sharedPreferencesProvider));
});

final desktopWindowControllerProvider =
    NotifierProvider<DesktopWindowController, DesktopLayout>(
      DesktopWindowController.new,
    );

/// Owns the open desktop tabs and the persisted layout.
///
/// The controller is the single source of truth for which tabs are open; views only
/// call its methods and render [state]. Writes to the layout store are debounced
/// and best-effort, so a slow or failing disk never blocks interaction.
class DesktopWindowController extends Notifier<DesktopLayout> {
  /// How long a burst of layout changes waits before one write.
  static const Duration _saveDebounce = Duration(milliseconds: 300);

  static final RegExp _idPattern = RegExp(r'^w(\d+)$');

  Timer? _saveTimer;
  int _nextIdNumber = 1;

  @override
  DesktopLayout build() {
    ref.onDispose(_cancelSave);
    final layout =
        ref.watch(desktopLayoutStoreProvider).load() ?? const DesktopLayout();
    _nextIdNumber = _highestIdNumber(layout.windows) + 1;
    return layout;
  }

  /// Opens a tab and returns its id.
  ///
  /// Chat tabs are unique per [conversationId]; utility tabs are unique per
  /// [kind]. Reopening an existing tab focuses it instead of creating a
  /// duplicate.
  String open({
    required DesktopWindowKind kind,
    String? route,
    String? conversationId,
    String? title,
    bool isDraft = false,
  }) {
    // Draft chats are independent: each one owns its own state, so a new draft
    // never focuses an existing tab.
    if (!isDraft) {
      final existing = _findOpen(kind, conversationId);
      if (existing != null) {
        focus(existing.id);
        return existing.id;
      }
    }
    final id = 'w${_nextIdNumber++}';
    final window = DesktopWindowState(
      id: id,
      kind: kind,
      title: title ?? kind.defaultTitle,
      route: route,
      conversationId: conversationId,
      isDraft: isDraft,
    );
    _set(
      DesktopLayout(windows: [...state.windows, window], focusedWindowId: id),
    );
    return id;
  }

  /// Closes [id] and activates the neighbouring tab.
  ///
  /// The tab that takes the closed tab's place becomes active; when the last tab
  /// was closed, the one before it does. Closing an inactive tab leaves the
  /// current focus alone.
  void close(String id) {
    final index = state.windows.indexWhere((window) => window.id == id);
    if (index < 0) return;
    final remaining = [...state.windows]..removeAt(index);
    final focused = state.focusedWindowId;
    final keepFocus = focused != id && remaining.any((w) => w.id == focused);
    _set(
      DesktopLayout(
        windows: remaining,
        focusedWindowId: keepFocus ? focused : _neighbour(remaining, index),
      ),
    );
  }

  /// Activates [id].
  void focus(String id) {
    if (state.focusedWindowId == id) return;
    if (!state.windows.any((window) => window.id == id)) return;
    _set(DesktopLayout(windows: state.windows, focusedWindowId: id));
  }

  void updateTitle(String id, String title) {
    final window = _window(id);
    if (window == null || window.title == title) return;
    _replace(window.copyWith(title: title));
  }

  DesktopWindowState? _window(String id) {
    for (final window in state.windows) {
      if (window.id == id) return window;
    }
    return null;
  }

  DesktopWindowState? _findOpen(
    DesktopWindowKind kind,
    String? conversationId,
  ) {
    for (final window in state.windows) {
      if (window.kind != kind) continue;
      if (kind == DesktopWindowKind.chat &&
          window.conversationId != conversationId) {
        continue;
      }
      return window;
    }
    return null;
  }

  /// The id of the tab that takes [closedIndex]'s place, else the one before.
  static String? _neighbour(
    List<DesktopWindowState> remaining,
    int closedIndex,
  ) {
    if (remaining.isEmpty) return null;
    final index = closedIndex >= remaining.length
        ? remaining.length - 1
        : closedIndex;
    return remaining[index].id;
  }

  void _replace(DesktopWindowState window) {
    _set(
      DesktopLayout(
        windows: [
          for (final candidate in state.windows)
            candidate.id == window.id ? window : candidate,
        ],
        focusedWindowId: state.focusedWindowId,
      ),
    );
  }

  void _set(DesktopLayout layout) {
    if (layout == state) return;
    state = layout;
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, _save);
  }

  void _save() {
    _saveTimer = null;
    // Best-effort: a failed write must never break interaction.
    try {
      unawaited(
        ref
            .read(desktopLayoutStoreProvider)
            .save(state)
            .catchError((Object _) {}),
      );
    } catch (_) {}
  }

  void _cancelSave() {
    _saveTimer?.cancel();
    _saveTimer = null;
  }

  static int _highestIdNumber(List<DesktopWindowState> windows) {
    var highest = 0;
    for (final window in windows) {
      final match = _idPattern.firstMatch(window.id);
      final number = match == null ? null : int.tryParse(match.group(1)!);
      if (number != null && number > highest) highest = number;
    }
    return highest;
  }
}
