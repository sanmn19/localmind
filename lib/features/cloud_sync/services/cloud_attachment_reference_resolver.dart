import 'dart:convert';

import 'package:path/path.dart' as p;

/// Filesystem-safe local name for a materialized cloud attachment.
///
/// The cloud identifier and the original file name can each be long enough that
/// `identifier-name.ext` exceeds the 255-byte limit (observed as
/// `File name too long, errno = 36`). Keep a stable short hash for uniqueness
/// and a truncated readable stem for the extension/preview.
String cloudAttachmentLocalName(String identifier, String decodedName) {
  final extension = p.extension(decodedName);
  final stem = p.basenameWithoutExtension(decodedName);
  final readable = stem.length > 40 ? stem.substring(0, 40) : stem;
  return '${_stableShortHash('$identifier/$decodedName')}_$readable$extension';
}

String _stableShortHash(String value) {
  // FNV-1a 64-bit: deterministic across runs, unlike String.hashCode.
  var hash = 0xcbf29ce484222325;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

class CloudAttachmentReferenceResolver {
  const CloudAttachmentReferenceResolver();

  String? findPreviousReference({
    required List<String> previousReferences,
    required String localPath,
    required int index,
  }) {
    final localName = p.basename(localPath);
    for (final candidate in previousReferences) {
      try {
        final encodedName = Uri.parse(candidate).pathSegments.last;
        final padded = encodedName.padRight(
          encodedName.length + ((4 - encodedName.length % 4) % 4),
          '=',
        );
        if (utf8.decode(base64Url.decode(padded)) == localName) {
          return candidate;
        }
      } catch (_) {}
    }
    return index < previousReferences.length ? previousReferences[index] : null;
  }
}
