class ForkAnchor {
  final String id;
  final String mainConversationId;
  final String anchorMessageId;
  final String selectedText;
  final String forkConversationId;
  final DateTime createdAt;

  const ForkAnchor({
    required this.id,
    required this.mainConversationId,
    required this.anchorMessageId,
    required this.selectedText,
    required this.forkConversationId,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'mainConversationId': mainConversationId,
      'anchorMessageId': anchorMessageId,
      'selectedText': selectedText,
      'forkConversationId': forkConversationId,
      'createdAt': createdAt.millisecondsSinceEpoch,
    };
  }

  static ForkAnchor fromMap(Map<String, dynamic> m) {
    return ForkAnchor(
      id: m['id'] as String,
      mainConversationId: m['mainConversationId'] as String,
      anchorMessageId: m['anchorMessageId'] as String,
      selectedText: m['selectedText'] as String,
      forkConversationId: m['forkConversationId'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(m['createdAt'] as int),
    );
  }
}
