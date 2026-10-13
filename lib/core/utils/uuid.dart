import 'dart:math';

/// RFC-4122 v4 pseudorandom id shared by the main chat path and the
/// selection-fork path (single source of truth; never reimplement locally —
/// a drift between id generators is untestable at runtime).
String generateUuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  return [
    bytes.sublist(0, 4),
    bytes.sublist(4, 6),
    bytes.sublist(6, 8),
    bytes.sublist(8, 10),
    bytes.sublist(10, 16),
  ]
      .map((b) => b.map((e) => e.toRadixString(16).padLeft(2, '0')).join())
      .join('-');
}
