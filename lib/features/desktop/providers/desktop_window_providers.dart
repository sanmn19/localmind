import 'dart:async';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/storage_providers.dart';
import '../data/desktop_layout_store.dart';
import '../data/models/desktop_window.dart';
import '../utils/window_geometry.dart';

final desktopLayoutStoreProvider = Provider<DesktopLayoutStore>((ref) {
  return DesktopLayoutStore(ref.watch(sharedPreferencesProvider));
});

final desktopWindowControllerProvider =
    NotifierProvider<DesktopWindowController, DesktopLayout>(
      DesktopWindowController.new,
    );

/// Owns the open desktop windows, their stacking order and their persisted
/// layout.
///
/// The controller is the single source of truth for window placement; views only
/// call its methods and render [state]. Writes to the layout store are debounced
/// and best-effort, so a slow or failing disk never blocks interaction.
class DesktopWindowController extends Notifier<DesktopLayout> {
  /// How long a burst of layout changes waits before one write.
  static const Duration _saveDebounce = Duration(milliseconds: 300);

  /// The size a window gets when the caller does not ask for one.
  static const double _defaultWidth = 720;
  static const double _defaultHeight = 520;

  static const double _cascadeStep = 28;
  static const double _cascadeLeft = 120;
  static const double _cascadeTop = 96;
  static const int _cascadeSlots = 6;
  static final RegExp _idPattern = RegExp(r'^w(\d+)$');

  Rect? _workspace;
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

  /// Opens a window and returns its id.
  ///
  /// Chat windows are unique per [conversationId]; utility windows are unique
  /// per [kind]. Reopening an existing window restores it and focuses it instead
  /// of creating a duplicate.
  String open({
    required DesktopWindowKind kind,
    String? route,
    String? conversationId,
    String? title,
    Rect? rect,
    bool maximized = false,
  }) {
    final existing = _findOpen(kind, conversationId);
    if (existing != null) {
      restore(existing.id);
      return existing.id;
    }
    final id = 'w${_nextIdNumber++}';
    final window = DesktopWindowState(
      id: id,
      kind: kind,
      title: title ?? kind.defaultTitle,
      rect: _clampToWorkspace(rect ?? _cascadeRect(state.windows.length)),
      route: route,
      conversationId: conversationId,
      isMaximized: maximized,
      zIndex: _topZIndex() + 1,
    );
    _set(
      DesktopLayout(windows: [...state.windows, window], focusedWindowId: id),
    );
    return id;
  }

  /// Closes [id] and focuses the topmost remaining window.
  void close(String id) {
    if (!state.windows.any((window) => window.id == id)) return;
    final remaining = [
      for (final window in state.windows)
        if (window.id != id) window,
    ];
    final focused = state.focusedWindowId;
    final keepFocus =
        focused != id && remaining.any((window) => window.id == focused);
    _set(
      DesktopLayout(
        windows: remaining,
        focusedWindowId: keepFocus ? focused : _topmostVisible(remaining)?.id,
      ),
    );
  }

  /// Focuses [id], bringing it to the top of the stack.
  void focus(String id) {
    final window = _window(id);
    if (window == null) return;
    if (state.focusedWindowId == id && window.zIndex == _topZIndex()) return;
    _bringToFront(window);
  }

  /// Hides [id] and moves focus to the next topmost visible window.
  void minimize(String id) {
    final window = _window(id);
    if (window == null || window.isMinimized) return;
    final windows = [
      for (final candidate in state.windows)
        candidate.id == id ? candidate.copyWith(isMinimized: true) : candidate,
    ];
    final focusedWindowId = state.focusedWindowId == id
        ? _topmostVisible(windows)?.id
        : state.focusedWindowId;
    _set(DesktopLayout(windows: windows, focusedWindowId: focusedWindowId));
  }

  /// Shows a minimised window again and focuses it.
  void restore(String id) {
    final window = _window(id);
    if (window == null) return;
    _bringToFront(window.copyWith(isMinimized: false));
  }

  /// Flips the maximised flag. The stored rect is left untouched so the
  /// window returns to its previous size when it is un-maximised.
  void toggleMaximize(String id) {
    final window = _window(id);
    if (window == null) return;
    _replace(window.copyWith(isMaximized: !window.isMaximized));
  }

  /// Moves [id], clamped to the workspace when one is known.
  void move(String id, Rect rect) => _setRect(id, rect);

  /// Resizes [id], clamped to the workspace when one is known.
  void resize(String id, Rect rect) => _setRect(id, rect);

  /// Fills [edge] of the workspace with [id] and un-maximises it.
  ///
  /// Does nothing until the shell has reported a workspace: there is no edge to
  /// fill before that.
  void snap(String id, DesktopSnapEdge edge) {
    final window = _window(id);
    final workspace = _workspace;
    if (window == null || workspace == null) return;
    final next = window.copyWith(
      rect: _clampToWorkspace(WindowGeometry.snapped(edge, workspace)),
      isMaximized: false,
    );
    if (next == window) return;
    _replace(next);
  }

  /// Sets the workspace used to keep windows on screen and re-clamps every
  /// window already open.
  void setWorkspace(Rect workspace) {
    _workspace = workspace;
    _set(
      DesktopLayout(
        windows: [
          for (final window in state.windows)
            window.copyWith(rect: WindowGeometry.clamp(window.rect, workspace)),
        ],
        focusedWindowId: state.focusedWindowId,
      ),
    );
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

  int _topZIndex() {
    var top = 0;
    for (final window in state.windows) {
      if (window.zIndex > top) top = window.zIndex;
    }
    return top;
  }

  /// The highest stacked window that is not minimised.
  DesktopWindowState? _topmostVisible(List<DesktopWindowState> windows) {
    DesktopWindowState? top;
    for (final window in windows) {
      if (window.isMinimized) continue;
      if (top == null || window.zIndex > top.zIndex) top = window;
    }
    return top;
  }

  void _bringToFront(DesktopWindowState window) {
    final raised = window.copyWith(zIndex: _topZIndex() + 1);
    _set(
      DesktopLayout(
        windows: [
          for (final candidate in state.windows)
            candidate.id == window.id ? raised : candidate,
        ],
        focusedWindowId: raised.id,
      ),
    );
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

  void _setRect(String id, Rect rect) {
    final window = _window(id);
    if (window == null) return;
    final next = _clampToWorkspace(rect);
    if (next == window.rect) return;
    _replace(window.copyWith(rect: next));
  }

  Rect _clampToWorkspace(Rect rect) {
    final workspace = _workspace;
    return workspace == null ? rect : WindowGeometry.clamp(rect, workspace);
  }

  Rect _cascadeRect(int index) {
    final offset = _cascadeStep * (index % _cascadeSlots);
    return Rect.fromLTWH(
      _cascadeLeft + offset,
      _cascadeTop + offset,
      _defaultWidth,
      _defaultHeight,
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
