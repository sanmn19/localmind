/// The screen a desktop tab hosts.
///
/// Utility tabs are one-per-kind; [chat] tabs are one-per-conversation.
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

  /// The title used when a caller opens a tab without one.
  ///
  /// Views pass localised titles instead; this is only a fallback so a tab is
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

/// One open tab in the desktop workspace.
class DesktopWindowState {
  const DesktopWindowState({
    required this.id,
    required this.kind,
    required this.title,
    this.route,
    this.conversationId,
  });

  final String id;
  final DesktopWindowKind kind;
  final String title;
  final String? route;
  final String? conversationId;

  DesktopWindowState copyWith({
    DesktopWindowKind? kind,
    String? title,
    String? route,
    bool clearRoute = false,
    String? conversationId,
    bool clearConversationId = false,
  }) {
    return DesktopWindowState(
      id: id,
      kind: kind ?? this.kind,
      title: title ?? this.title,
      route: clearRoute ? null : (route ?? this.route),
      conversationId: clearConversationId
          ? null
          : (conversationId ?? this.conversationId),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'kind': kind.name,
      'title': title,
      'route': route,
      'conversationId': conversationId,
    };
  }

  /// Returns `null` when the persisted tab cannot be trusted: a missing [id] or an
  /// unknown [kind].
  ///
  /// Fields written by an older layout (rect, z-index, minimise and maximise
  /// flags) are ignored, and a missing title falls back to the kind's default, so a
  /// layout can always be read after an upgrade.
  static DesktopWindowState? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final kind = DesktopWindowKind.tryParse(json['kind']);
    if (id is! String || id.isEmpty || kind == null) return null;
    final title = json['title'];
    final route = json['route'];
    final conversationId = json['conversationId'];
    return DesktopWindowState(
      id: id,
      kind: kind,
      title: title is String && title.isNotEmpty ? title : kind.defaultTitle,
      route: route is String ? route : null,
      conversationId: conversationId is String ? conversationId : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesktopWindowState &&
          other.id == id &&
          other.kind == kind &&
          other.title == title &&
          other.route == route &&
          other.conversationId == conversationId;

  @override
  int get hashCode => Object.hash(id, kind, title, route, conversationId);

  @override
  String toString() => 'DesktopWindowState($id, ${kind.name}, $title)';
}

/// Every open tab plus which one is active.
class DesktopLayout {
  const DesktopLayout({this.windows = const [], this.focusedWindowId});

  final List<DesktopWindowState> windows;
  final String? focusedWindowId;

  /// The active tab, or `null` when nothing (or a closed tab) is focused.
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

  /// Returns `null` when [json] is not a layout at all. Individual tabs that
  /// cannot be trusted are skipped, and a focus that points at a skipped tab is
  /// dropped.
  ///
  /// A layout written before tabs stored no window list at all, so a missing list
  /// reads as an empty layout.
  static DesktopLayout? fromJson(Object? json) {
    if (json is! Map) return null;
    final rawWindows = json['windows'];
    if (rawWindows != null && rawWindows is! List) return null;
    final windows = <DesktopWindowState>[
      if (rawWindows is List)
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
