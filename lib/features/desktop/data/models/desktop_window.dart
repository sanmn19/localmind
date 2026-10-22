import 'dart:ui';

/// The screen a desktop window hosts.
///
/// Utility windows are one-per-kind; [chat] windows are one-per-conversation.
enum DesktopWindowKind {
  chat,
  history,
  savedMessages,
  servers,
  addServer,
  personas,
  createPersona,
  settings,
  cloudSync,
  mcpTools,
  skills,
  skillEditor,
  background,
  onDeviceModels,
  ttsModels,
  lmStudioModels,
  onboarding;

  /// The title used when a caller opens a window without one.
  ///
  /// Views pass localised titles instead; this is only a fallback so a window is
  /// never untitled.
  String get defaultTitle => switch (this) {
    DesktopWindowKind.chat => 'Chat',
    DesktopWindowKind.history => 'History',
    DesktopWindowKind.savedMessages => 'Saved messages',
    DesktopWindowKind.servers => 'Servers',
    DesktopWindowKind.addServer => 'Add server',
    DesktopWindowKind.personas => 'Personas',
    DesktopWindowKind.createPersona => 'New persona',
    DesktopWindowKind.settings => 'Settings',
    DesktopWindowKind.cloudSync => 'Cloud sync',
    DesktopWindowKind.mcpTools => 'MCP tools',
    DesktopWindowKind.skills => 'Skills',
    DesktopWindowKind.skillEditor => 'Skill editor',
    DesktopWindowKind.background => 'Background tasks',
    DesktopWindowKind.onDeviceModels => 'On-device models',
    DesktopWindowKind.ttsModels => 'TTS models',
    DesktopWindowKind.lmStudioModels => 'LM Studio models',
    DesktopWindowKind.onboarding => 'Welcome',
  };

  /// Parses a persisted [name], returning `null` for unknown values so a layout
  /// written by a newer build does not break the current one.
  static DesktopWindowKind? tryParse(Object? name) {
    if (name is! String) return null;
    for (final kind in values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// One floating window in the desktop layout.
class DesktopWindowState {
  const DesktopWindowState({
    required this.id,
    required this.kind,
    required this.title,
    required this.rect,
    this.route,
    this.conversationId,
    this.isMinimized = false,
    this.isMaximized = false,
    this.zIndex = 0,
  });

  final String id;
  final DesktopWindowKind kind;
  final String title;
  final Rect rect;
  final String? route;
  final String? conversationId;
  final bool isMinimized;
  final bool isMaximized;
  final int zIndex;

  DesktopWindowState copyWith({
    DesktopWindowKind? kind,
    String? title,
    Rect? rect,
    String? route,
    bool clearRoute = false,
    String? conversationId,
    bool clearConversationId = false,
    bool? isMinimized,
    bool? isMaximized,
    int? zIndex,
  }) {
    return DesktopWindowState(
      id: id,
      kind: kind ?? this.kind,
      title: title ?? this.title,
      rect: rect ?? this.rect,
      route: clearRoute ? null : (route ?? this.route),
      conversationId: clearConversationId
          ? null
          : (conversationId ?? this.conversationId),
      isMinimized: isMinimized ?? this.isMinimized,
      isMaximized: isMaximized ?? this.isMaximized,
      zIndex: zIndex ?? this.zIndex,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'kind': kind.name,
      'title': title,
      'left': rect.left,
      'top': rect.top,
      'width': rect.width,
      'height': rect.height,
      'route': route,
      'conversationId': conversationId,
      'isMinimized': isMinimized,
      'isMaximized': isMaximized,
      'zIndex': zIndex,
    };
  }

  /// Returns `null` when the persisted window cannot be trusted: an unknown
  /// [kind] or a rect that is not finite (or missing).
  static DesktopWindowState? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final kind = DesktopWindowKind.tryParse(json['kind']);
    final title = json['title'];
    final left = _toDouble(json['left']);
    final top = _toDouble(json['top']);
    final width = _toDouble(json['width']);
    final height = _toDouble(json['height']);
    if (id is! String || id.isEmpty) return null;
    if (kind == null || title is! String) return null;
    if (left == null || top == null || width == null || height == null) {
      return null;
    }
    final route = json['route'];
    final conversationId = json['conversationId'];
    final zIndex = json['zIndex'];
    return DesktopWindowState(
      id: id,
      kind: kind,
      title: title,
      rect: Rect.fromLTWH(left, top, width, height),
      route: route is String ? route : null,
      conversationId: conversationId is String ? conversationId : null,
      isMinimized: json['isMinimized'] == true,
      isMaximized: json['isMaximized'] == true,
      zIndex: zIndex is int ? zIndex : 0,
    );
  }

  static double? _toDouble(Object? value) {
    if (value is! num) return null;
    final result = value.toDouble();
    return result.isFinite ? result : null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesktopWindowState &&
          other.id == id &&
          other.kind == kind &&
          other.title == title &&
          other.rect == rect &&
          other.route == route &&
          other.conversationId == conversationId &&
          other.isMinimized == isMinimized &&
          other.isMaximized == isMaximized &&
          other.zIndex == zIndex;

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    title,
    rect,
    route,
    conversationId,
    isMinimized,
    isMaximized,
    zIndex,
  );

  @override
  String toString() => 'DesktopWindowState($id, ${kind.name}, $rect)';
}

/// Every open window plus which one has focus.
class DesktopLayout {
  const DesktopLayout({this.windows = const [], this.focusedWindowId});

  final List<DesktopWindowState> windows;
  final String? focusedWindowId;

  /// The focused window, or `null` when nothing (or a closed window) is focused.
  DesktopWindowState? get focusedWindow {
    final id = focusedWindowId;
    if (id == null) return null;
    for (final window in windows) {
      if (window.id == id) return window;
    }
    return null;
  }

  DesktopLayout copyWith({
    List<DesktopWindowState>? windows,
    String? focusedWindowId,
    bool clearFocusedWindow = false,
  }) {
    return DesktopLayout(
      windows: windows ?? this.windows,
      focusedWindowId: clearFocusedWindow
          ? null
          : (focusedWindowId ?? this.focusedWindowId),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'windows': [for (final window in windows) window.toJson()],
      'focusedWindowId': focusedWindowId,
    };
  }

  /// Returns `null` when [json] is not a layout at all. Individual windows that
  /// cannot be trusted are skipped, and a focus that points at a skipped window is
  /// dropped.
  static DesktopLayout? fromJson(Object? json) {
    if (json is! Map) return null;
    final rawWindows = json['windows'];
    if (rawWindows is! List) return null;
    final windows = <DesktopWindowState>[
      for (final raw in rawWindows) ?DesktopWindowState.fromJson(raw),
    ];
    final rawFocused = json['focusedWindowId'];
    final focusedWindowId =
        rawFocused is String && windows.any((w) => w.id == rawFocused)
        ? rawFocused
        : null;
    return DesktopLayout(windows: windows, focusedWindowId: focusedWindowId);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesktopLayout &&
          other.focusedWindowId == focusedWindowId &&
          _sameWindows(other.windows, windows);

  @override
  int get hashCode => Object.hash(focusedWindowId, Object.hashAll(windows));

  static bool _sameWindows(
    List<DesktopWindowState> a,
    List<DesktopWindowState> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
