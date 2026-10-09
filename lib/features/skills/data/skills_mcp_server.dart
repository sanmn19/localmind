import 'skills_store.dart';

// Closure-members named without the underscore are intentional: the
// initializers would otherwise fight prefer_initializing_formals.
// ignore_for_file: prefer_initializing_formals

const skillsMcpServerLabel = 'Skills';
const skillsMcpServerUrl = 'local://skills';

/// The write-tool shape behind [SkillsServices.add]: a resolved skill name,
/// its one-line description and the markdown body.
typedef SkillsWrite =
    Future<void> Function(String name, String description, String content);

/// Backing services for the in-process `local://skills` MCP server.
///
/// An async-method seam decoupled from the [McpServerManager]: the
/// tooling-registration provider unfolds this bundle from closures over the
/// skills provider (store reads/writes plus the notifier refresh), so the
/// manager and this feature stay wired through one small contract. `list`
/// delegates to a fresh store read; `add`/`delete` receive names already
/// resolved and validated by the manager's dispatcher; `enabled` mirrors the
/// settings kill switch.
class SkillsServices {
  SkillsServices({
    required Future<List<SkillEntry>> Function() list,
    required SkillsWrite add,
    required Future<void> Function(String name) delete,
    required bool Function() enabled,
  }) : _list = list,
       _add = add,
       _delete = delete,
       _enabled = enabled;

  final Future<List<SkillEntry>> Function() _list;
  final Future<void> Function(String, String, String) _add;
  final Future<void> Function(String) _delete;
  final bool Function() _enabled;

  /// Every stored skill, fresh from disk, sorted by name.
  Future<List<SkillEntry>> list() => _list();

  /// Persists a validated skill; the configured hook afterwards refreshes
  /// the provider mirror so the next request injects the new entry.
  Future<void> add(String name, String description, String content) =>
      _add(name, description, content);

  /// Removes a validated, existing skill and refreshes the mirror.
  Future<void> delete(String name) => _delete(name);

  /// Whether the skills feature (settings kill switch) is currently on.
  bool get enabled => _enabled();
}

/// Model-readable `skills.list` render: one `- name: description` row per
/// skill (the same row shape the system section uses), or a single friendly
/// line when the store has no skills yet.
String formatSkillsList(List<SkillEntry> entries) {
  if (entries.isEmpty) return 'No skills defined.';
  return [
    for (final entry in entries) '- ${entry.name}: ${entry.description}',
  ].join('\n');
}

/// Model-readable `skills.read` render: the heading, the description and
/// the full markdown body. Bodies can be arbitrarily large, so the output
/// trims at [skillsReadMaxChars] with [skillsReadTruncationMarker] — the
/// same tool-output truncation convention the other local servers use.
String formatSkillsRead(SkillEntry entry) {
  final body = entry.body.trimRight();
  final text = '# ${entry.name}\n${entry.description}\n\n$body';
  if (text.length <= skillsReadMaxChars) return text;
  return '${text.substring(0, skillsReadMaxChars)}\n$skillsReadTruncationMarker';
}

/// The add-tool's invalid-name failure line, or null when the chat-provided
/// name resolves to a stored-ready skill name.
String? skillsNameFailure(String rawName) {
  if (SkillsStore.isValidName(SkillsStore.normalizeName(rawName))) return null;
  return 'invalid skill name "$rawName" — lowercase letters, digits and '
      'underscores (max ${SkillsStore.maxNameLength})';
}
