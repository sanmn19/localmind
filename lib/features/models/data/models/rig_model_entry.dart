/// One entry of the rig model switcher's roster (`GET /v1/list`).
class RigModelEntry {
  const RigModelEntry({
    required this.name,
    required this.label,
    required this.servedModelName,
    required this.enabled,
    required this.active,
  });

  /// The switcher target (`POST /v1/switch/{name}`).
  final String name;

  final String label;

  /// The id the provider serves once this entry is loaded.
  final String servedModelName;

  final bool enabled;

  final bool active;
}
