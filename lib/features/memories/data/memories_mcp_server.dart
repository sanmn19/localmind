import '../data/models/memory.dart';

const memoriesMcpServerLabel = 'Memories';
const memoriesMcpServerUrl = 'local://memories';

/// Backing services for the in-process `local://memories` MCP server.
/// Mirrors [SkillsServices]: closures over the memory providers so the manager
/// and the feature stay wired through one small contract. `remember` is a
/// passive write (auto-approved); `forget` always crosses the approval dialog.
class MemoriesServices {
  MemoriesServices({
    required Future<List<Memory>> Function() list,
    required Future<Memory> Function(
      String title,
      String content,
      MemoryKind kind,
      int importance,
    )
    remember,
    required Future<List<Memory>> Function(String query) search,
    required Future<bool> Function(String memoryId) forget,
    required Future<MemoryRelation> Function(
      String from,
      String to,
      String label,
    )
    link,
    required Future<List<MemoryRelation>> Function(String memoryId)
    relationsFor,
    required bool Function() enabled,
    required Future<void> Function(Memory memory) afterRemember,
  }) : _list = list,
       _remember = remember,
       _search = search,
       _forget = forget,
       _link = link,
       _relationsFor = relationsFor,
       _enabled = enabled,
       _afterRemember = afterRemember;

  final Future<List<Memory>> Function() _list;
  final Future<Memory> Function(String, String, MemoryKind, int)
  _remember;
  final Future<List<Memory>> Function(String) _search;
  final Future<bool> Function(String) _forget;
  final Future<MemoryRelation> Function(String, String, String) _link;
  final Future<List<MemoryRelation>> Function(String) _relationsFor;
  final bool Function() _enabled;
  final Future<void> Function(Memory) _afterRemember;

  Future<List<Memory>> list() => _list();

  Future<Memory> remember(
    String title,
    String content,
    MemoryKind kind,
    int importance,
  ) async {
    final memory = await _remember(title, content, kind, importance);
    // Embedding/indexing is best-effort: a failure never fails the write.
    await _afterRemember(memory);
    return memory;
  }

  Future<List<Memory>> search(String query) => _search(query);

  Future<bool> forget(String memoryId) => _forget(memoryId);

  Future<MemoryRelation> link(String from, String to, String label) =>
      _link(from, to, label);

  Future<List<MemoryRelation>> relationsFor(String memoryId) =>
      _relationsFor(memoryId);

  bool get enabled => _enabled();
}

/// Model-readable list render: one `- [kind] title: content` row per memory.
String formatMemoriesList(List<Memory> memories) {
  if (memories.isEmpty) return 'No memories yet.';
  return [
    for (final memory in memories)
      '- [${memory.kind.name}] ${memory.title}: ${memory.content}',
  ].join('\n');
}

/// Model-readable search render with ids so the model can link/forget.
String formatMemoriesSearch(List<Memory> memories) {
  if (memories.isEmpty) return 'No matching memories.';
  return [
    for (final memory in memories)
      '- [${memory.kind.name}] ${memory.title}: ${memory.content} '
          '(id: ${memory.id})',
  ].join('\n');
}

/// Model-readable remember render.
String formatMemoryRemember(Memory memory) =>
    'Remembered: [${memory.kind.name}] ${memory.title}: ${memory.content} '
    '(id: ${memory.id})';

/// The remember tool's invalid-input line, or null when valid.
String? memoriesRememberFailure(String title, String content) {
  if (title.trim().isEmpty) return 'a memory title is required';
  if (content.trim().isEmpty) return 'memory content is required';
  return null;
}
