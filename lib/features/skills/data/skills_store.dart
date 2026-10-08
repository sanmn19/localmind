import 'dart:io';

/// One named markdown skill: a unique name, a one-line description and the
/// markdown body injected verbatim into chats.
class SkillEntry {
  const SkillEntry({
    required this.name,
    required this.description,
    required this.body,
  });

  final String name;
  final String description;
  final String body;

  SkillEntry copyWith({String? name, String? description, String? body}) {
    return SkillEntry(
      name: name ?? this.name,
      description: description ?? this.description,
      body: body ?? this.body,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SkillEntry &&
          other.name == name &&
          other.description == description &&
          other.body == body;

  @override
  int get hashCode => Object.hash(name, description, body);

  @override
  String toString() => 'SkillEntry($name)';
}

/// Character budget for the skills section injected into a system prompt.
const skillsSystemSectionBudget = 12000;

/// Marker appended when body text was dropped to respect
/// [skillsSystemSectionBudget]; the name/description rows survive.
const skillsTruncationMarker = '[skill bodies truncated to fit context]';

/// The filesystem boundary behind [SkillsStore]. Unit tests inject an
/// in-memory fake; the app wires the real documents directory.
abstract class SkillFileHost {
  /// Base names (without the .md extension) of every stored skill file.
  Future<List<String>> list();

  /// Reads a skill file by base name.
  Future<String> read(String name);

  /// Creates or overwrites a skill file by base name. Names are already
  /// normalized by [SkillsStore].
  Future<void> write(String name, String content);

  /// Deletes a skill file by base name; a missing file is tolerated.
  Future<void> delete(String name);
}

/// Host that stores skills as `<documents>/skills/<name>.md` files, the
/// same documents-dir access pattern as the chat attachments folder.
class DirectorySkillFileHost implements SkillFileHost {
  DirectorySkillFileHost(Future<Directory> documentsDirectory)
    : _documentsDirectory = documentsDirectory;

  static const _skillsDirName = 'skills';
  static const _skillExtension = '.md';

  final Future<Directory> _documentsDirectory;

  Future<Directory> _resolveSkillsDir() async {
    final documents = await _documentsDirectory;
    final dir = Directory('${documents.path}/$_skillsDirName');
    await dir.create(recursive: true);
    return dir;
  }

  File _fileFor(Directory dir, String name) =>
      File('${dir.path}/$name$_skillExtension');

  @override
  Future<List<String>> list() async {
    final dir = await _resolveSkillsDir();
    final names = <String>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      if (!entity.path.endsWith(_skillExtension)) continue;
      final path = entity.path;
      final slash = path.lastIndexOf('/');
      final base = slash >= 0 ? path.substring(slash + 1) : path;
      names.add(base.substring(0, base.length - _skillExtension.length));
    }
    names.sort();
    return names;
  }

  @override
  Future<String> read(String name) async {
    final dir = await _resolveSkillsDir();
    return _fileFor(dir, name).readAsString();
  }

  @override
  Future<void> write(String name, String content) async {
    final dir = await _resolveSkillsDir();
    await _fileFor(dir, name).writeAsString(content, flush: true);
  }

  @override
  Future<void> delete(String name) async {
    final dir = await _resolveSkillsDir();
    final file = _fileFor(dir, name);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

/// The skill store: pure CRUD + frontmatter logic against a
/// [SkillFileHost]. The provider layer mirrors results in memory so the
/// system-builder never blocks on IO.
class SkillsStore {
  SkillsStore(this._host);

  final SkillFileHost _host;

  static final RegExp _frontmatterPattern = RegExp(
    r'^---\r?\n(.*?)\r?\n---\r?\n?(.*)$',
    dotAll: true,
  );

  static final RegExp _namePattern = RegExp(r'^[a-z0-9_]{1,48}$');

  /// Longest accepted skill name.
  static const int maxNameLength = 48;

  /// Lists, reads and parses every stored skill, sorted by name.
  Future<List<SkillEntry>> refresh() async {
    final names = await _host.list();
    final entries = <SkillEntry>[];
    for (final name in names) {
      final content = await _host.read(name);
      entries.add(parse('$name$_extension', content));
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    return entries;
  }

  static const _extension = '.md';

  /// Writes a new skill. The name is normalized first; an empty result is
  /// rejected and an existing skill clashes with a clear [ArgumentError].
  Future<void> add(SkillEntry entry) async {
    final name = normalizeName(entry.name);
    _requireValidName(entry.name);
    if (await _exists(name)) {
      throw ArgumentError('a skill named "$name" already exists');
    }
    await _host.write(name, serialize(entry.copyWith(name: name)));
  }

  /// Rewrites a skill, renaming the underlying file when the name changed.
  /// Renaming onto another existing skill is rejected.
  Future<void> update(String oldName, SkillEntry entry) async {
    final newName = normalizeName(entry.name);
    _requireValidName(entry.name);
    if (newName != oldName) {
      if (await _exists(newName)) {
        throw ArgumentError('a skill named "$newName" already exists');
      }
      await _host.write(newName, serialize(entry.copyWith(name: newName)));
      await _host.delete(oldName);
      return;
    }
    await _host.write(oldName, serialize(entry.copyWith(name: newName)));
  }

  /// Removes a skill file; deleting a missing skill is a no-op.
  Future<void> delete(String name) async {
    await _host.delete(name);
  }

  Future<bool> _exists(String name) async =>
      (await _host.list()).contains(name);

  static void _requireValidName(String raw) {
    if (!isValidName(normalizeName(raw))) {
      throw ArgumentError(
        'invalid skill name: "$raw" — lowercase letters, numbers and underscores',
      );
    }
  }

  /// Parses a skill file: `name`/`description` frontmatter plus the body
  /// after the closing marker. CRLF content is handled. Without
  /// frontmatter the whole content is the body and the name falls back to
  /// the (normalized) file name.
  static SkillEntry parse(String fileName, String content) {
    final match = _frontmatterPattern.firstMatch(content);
    if (match == null) {
      return SkillEntry(
        name: normalizeName(_baseName(fileName)),
        description: '',
        body: content,
      );
    }
    final frontmatter = match.group(1)!;
    final body = match.group(2) ?? '';
    String? name;
    var description = '';
    for (final line in frontmatter.split(RegExp(r'\r?\n'))) {
      final separator = line.indexOf(':');
      if (separator <= 0) continue;
      final key = line.substring(0, separator).trim().toLowerCase();
      final value = line.substring(separator + 1).trim();
      if (key == 'name' && name == null) {
        name = value;
      } else if (key == 'description') {
        description = value;
      }
    }
    return SkillEntry(
      name: name ?? normalizeName(_baseName(fileName)),
      description: description,
      body: body,
    );
  }

  /// Serializes a skill to the exact on-disk format; parse and serialize
  /// round-trip losslessly.
  static String serialize(SkillEntry entry) {
    return '---\nname: ${entry.name}\ndescription: ${entry.description}\n'
        '---\n${entry.body}';
  }

  /// Lowercases, turns whitespace runs into underscores, strips everything
  /// outside [a-z0-9_], collapses underscore runs and caps at 48 chars.
  static String normalizeName(String raw) {
    var name = raw.trim().toLowerCase();
    name = name.replaceAll(RegExp(r'\s+'), '_');
    name = name.replaceAll(RegExp(r'[^a-z0-9_]'), '');
    name = name.replaceAll(RegExp(r'_+'), '_');
    while (name.startsWith('_')) {
      name = name.substring(1);
    }
    while (name.endsWith('_')) {
      name = name.substring(0, name.length - 1);
    }
    if (name.length > maxNameLength) {
      name = name.substring(0, maxNameLength);
      while (name.endsWith('_')) {
        name = name.substring(0, name.length - 1);
      }
    }
    return name;
  }

  /// Whether [name] is a stored-ready skill name:
  /// `^[a-z0-9_]{1,48}$` ([SkillsStore.maxNameLength]).
  static bool isValidName(String name) => _namePattern.hasMatch(name);

  static String _baseName(String fileName) {
    var name = fileName;
    final slash = name.lastIndexOf('/');
    if (slash >= 0) name = name.substring(slash + 1);
    if (name.endsWith(_extension)) {
      name = name.substring(0, name.length - _extension.length);
    }
    return name;
  }
}

/// Builds the system-prompt section listing the given skills.
///
/// Format per entry: a `- name: description` row followed by the body
/// verbatim. The header and every name row are always kept; once the
/// accumulated section would exceed [skillsSystemSectionBudget] the
/// remaining bodies are dropped and [skillsTruncationMarker] appended.
/// An empty list yields an empty string (injection skipped).
String buildSkillsSystemSection(List<SkillEntry> entries) {
  if (entries.isEmpty) return '';
  final buffer = StringBuffer();
  buffer.writeln('# Skills');
  buffer.writeln(
    'The user maintains these skills. When relevant, follow them.',
  );
  var truncated = false;
  for (final entry in entries) {
    buffer.writeln();
    buffer.writeln('- ${entry.name}: ${entry.description}');
    if (truncated) continue;
    if (buffer.length + 1 + entry.body.length <= skillsSystemSectionBudget) {
      buffer.writeln(entry.body);
    } else {
      truncated = true;
    }
  }
  if (truncated) {
    buffer.writeln();
    buffer.writeln(skillsTruncationMarker);
  }
  return buffer.toString();
}
