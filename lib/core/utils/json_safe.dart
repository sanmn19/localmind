/// Converts values that Dart's JSON encoder cannot represent (Dio
/// [ResponseBody] being the known offender) into strings. Tool arguments/results
/// are attacker/model/server supplied, so a single unexpected object must never
/// take down a chat turn or poison the persisted message row.
Object? jsonSafe(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is DateTime) return value.toIso8601String();
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key.toString(): jsonSafe(entry.value),
    };
  }
  if (value is Iterable) {
    return <Object?>[for (final item in value) jsonSafe(item)];
  }
  return value.toString();
}
