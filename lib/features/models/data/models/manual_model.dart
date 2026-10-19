class ManualModel {
  const ManualModel({
    required this.serverId,
    required this.modelId,
    this.displayName,
    required this.createdAt,
  });

  /// The provider the model belongs to.
  final String serverId;

  /// The id chat requests (the provider's `served_model_name` for rig models).
  final String modelId;

  /// Optional human label; the UI falls back to [modelId].
  final String? displayName;

  final DateTime createdAt;
}
