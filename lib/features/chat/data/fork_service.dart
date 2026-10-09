import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/enums.dart';
import '../../../core/providers/storage_providers.dart';
import '../../../core/storage/entities.dart';
import '../../../core/storage/objectbox_store.dart';
import '../../../core/utils/uuid.dart';
import '../../../objectbox.g.dart';
import '../../conversations/data/models/conversation.dart';
import 'models/fork_anchor.dart';
import 'models/message.dart';

/// Anchor CRUD + request-context assembly for selection-anchored fork chats
/// (docs/specs/2026-10-08-selection-fork-chats.md).
///
/// A "fork" is a hidden [Conversation] row (`isFork: true`) carrying
/// `forkOfMessageId`/`forkSpan`, pointing back at the anchored message of
/// its parent chat. Anchors live in the `ForkAnchorEntity` box; the fork's
/// own turns are persisted as [MessageEntity] rows inside the fork
/// conversation, so forks survive restarts (spec Q1).
///
/// Per-request context shape (spec Q2): composed system (+ skills index) +
/// main timeline up to AND INCLUDING the anchor + the fork's own turns;
/// post-anchor main rows are excluded. [ChatNotifier.mainTimelineUpTo]
/// produces the main part through the same assembly routine sends use.
class ForkService {
  /// [_db] may be omitted when only the pure fork-context assembly is used
  /// (unit tests); anchor operations then throw [StateError].
  ForkService([this._db]);

  final ObjectBoxStore? _db;

  ObjectBoxStore get _database {
    final db = _db;
    if (db == null) {
      throw StateError(
        'ForkService anchor operations require a database — construct via '
        'forkServiceProvider.',
      );
    }
    return db;
  }

  /// Creates the hidden fork conversation and the anchor row for a
  /// selection pointing at [anchorMessageId] inside [mainConversationId].
  ///
  /// The stored `selectedText` is trimmed exactly once here (the write
  /// site); everything downstream — transcript, wire context, highlight
  /// band — reads it verbatim afterwards.
  Future<ForkAnchor> createFork({
    required String mainConversationId,
    required String anchorMessageId,
    required String selectedText,
  }) async {
    final trimmed = selectedText.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        selectedText,
        'selectedText',
        'must contain non-whitespace text to anchor a fork',
      );
    }
    final db = _database;
    final input = _CreateForkInput(
      mainConversationId: mainConversationId,
      anchorMessageId: anchorMessageId,
      selectedText: trimmed,
      forkConversationId: generateUuidV4(),
      anchorId: generateUuidV4(),
      createdAt: DateTime.now(),
    );
    return db.store.runInTransactionAsync(
      TxMode.write,
      _createForkInBackground,
      input,
    );
  }

  /// All anchors recorded for [mainConversationId], oldest first.
  Future<List<ForkAnchor>> anchorsFor(String mainConversationId) async {
    final db = _database;
    return db.store.runInTransactionAsync(
      TxMode.read,
      _anchorsForInBackground,
      mainConversationId,
    );
  }

  /// Removes an anchor plus its fork conversation and the fork's message
  /// rows. Returns false when [anchorId] matches no anchor; an anchor whose
  /// fork conversation row is already gone still deletes cleanly.
  Future<bool> deleteFork(String anchorId) async {
    final db = _database;
    return db.store.runInTransactionAsync(
      TxMode.write,
      _deleteForkInBackground,
      anchorId,
    );
  }

  /// The fork request context: [mainTimelineUpToAnchor] (already composed
  /// with system + skills, and already filtered through
  /// [shouldIncludeMessageInChatContext] by the notifier) + [forkTurns] +
  /// one new user turn. The marked-quote contract puts the selection
  /// verbatim into the fork's FIRST user turn; follow-up questions pass
  /// through plain.
  ///
  /// [forkTurns] is filtered through the SAME wire predicate the main path
  /// applies before mark the fork wire: a persisted empty-content
  /// assistant error row stays visible in the panel transcript but is
  /// excluded from the request, so a restart-reopened fork never sends
  /// wire-poisoning empty turns to strict OpenAI-compatible backends.
  List<Message> buildForkContextMessages({
    required List<Message> mainTimelineUpToAnchor,
    required List<Message> forkTurns,
    required String question,
    required String selectedText,
  }) {
    final content = forkTurns.isEmpty
        ? 'Selected: "$selectedText"\n\n$question'
        : question;
    final wireTurns = forkTurns
        .where(shouldIncludeMessageInChatContext)
        .toList(growable: false);
    return [
      ...mainTimelineUpToAnchor,
      ...wireTurns,
      Message(
        id: generateUuidV4(),
        conversationId: '',
        role: MessageRole.user,
        content: content,
        createdAt: DateTime.now(),
        status: MessageStatus.complete,
      ),
    ];
  }

  static ForkAnchor _createForkInBackground(
    Store store,
    _CreateForkInput input,
  ) {
    final convBox = store.box<ConversationEntity>();
    final anchorBox = store.box<ForkAnchorEntity>();

    final mainQuery = convBox
        .query(ConversationEntity_.id.equals(input.mainConversationId))
        .build();
    final mainEntity = mainQuery.findFirst();
    mainQuery.close();

    convBox.put(
      ConversationEntity(
        id: input.forkConversationId,
        title: 'Fork — ${mainEntity?.title ?? input.mainConversationId}',
        createdAt: input.createdAt,
        updatedAt: input.createdAt,
        forkOfMessageId: input.anchorMessageId,
        // Documented forkSpan shape: {"text": <display text>, "occurrence":
        // <note>} — occurrence resolution is the renderer's concern (Task 4
        // verbatim-match band logic), so only text is known at write time.
        forkSpan: jsonEncode({'text': input.selectedText}),
        isFork: true,
      ),
    );

    final anchor = ForkAnchor(
      id: input.anchorId,
      mainConversationId: input.mainConversationId,
      anchorMessageId: input.anchorMessageId,
      selectedText: input.selectedText,
      forkConversationId: input.forkConversationId,
      createdAt: input.createdAt,
    );
    anchorBox.put(ForkAnchorEntity.fromDomain(anchor));
    return anchor;
  }

  static List<ForkAnchor> _anchorsForInBackground(
    Store store,
    String mainConversationId,
  ) {
    final anchorBox = store.box<ForkAnchorEntity>();
    final query = anchorBox
        .query(ForkAnchorEntity_.mainConversationId.equals(mainConversationId))
        .build();
    final entities = query.find();
    query.close();

    final anchors = entities.map((entity) => entity.toDomain()).toList()
      ..sort((a, b) {
        final byDate = a.createdAt.compareTo(b.createdAt);
        if (byDate != 0) return byDate;
        return a.id.compareTo(b.id);
      });
    return anchors;
  }

  static bool _deleteForkInBackground(Store store, String anchorId) {
    final anchorBox = store.box<ForkAnchorEntity>();
    final convBox = store.box<ConversationEntity>();
    final messageBox = store.box<MessageEntity>();

    final query = anchorBox.query(ForkAnchorEntity_.id.equals(anchorId)).build();
    final entity = query.findFirst();
    query.close();
    if (entity == null) return false;

    final forkQuery = convBox
        .query(ConversationEntity_.id.equals(entity.forkConversationId))
        .build();
    final forkEntity = forkQuery.findFirst();
    forkQuery.close();
    if (forkEntity != null) {
      final messagesQuery = messageBox
          .query(
            MessageEntity_.conversationUid.equals(entity.forkConversationId),
          )
          .build();
      final forkMessages = messagesQuery.find();
      messagesQuery.close();
      if (forkMessages.isNotEmpty) {
        messageBox.removeMany(
          forkMessages.map((message) => message.internalId).toList(),
        );
      }
      convBox.remove(forkEntity.internalId);
    }

    anchorBox.remove(entity.internalId);
    return true;
  }
}

/// Db-wired [ForkService] for the app. Construct a bare `ForkService()`
/// only for the pure fork-context assembly (tests).
final forkServiceProvider = Provider<ForkService>((ref) {
  return ForkService(ref.watch(databaseProvider));
});

/// All anchors whose fork hangs off a conversation — Task 4 renders
/// highlight bands from it (multiple forks per message are allowed, spec
/// Q3, hence the list).
final forkAnchorsForConversationProvider =
    FutureProvider.family<List<ForkAnchor>, String>((ref, conversationId) {
      return ref.watch(forkServiceProvider).anchorsFor(conversationId);
    });

class _CreateForkInput {
  _CreateForkInput({
    required this.mainConversationId,
    required this.anchorMessageId,
    required this.selectedText,
    required this.forkConversationId,
    required this.anchorId,
    required this.createdAt,
  });

  final String mainConversationId;
  final String anchorMessageId;
  final String selectedText;
  final String forkConversationId;
  final String anchorId;
  final DateTime createdAt;
}
