import 'dart:async';

import '../../features/chat/data/models/message.dart';
import '../../objectbox.g.dart';
import '../logger/app_logger.dart';
import '../storage/entities.dart';
import '../storage/objectbox_store.dart';

/// Batches [Message] saves and flushes them off the UI thread using
/// ObjectBox's [Store.runInTransactionAsync].
///
/// Call [enqueue] from the streaming listener (fire-and-forget).
/// Call [flush] when the stream ends or is cancelled to ensure the
/// final message state is persisted before updating UI state.
class MessageSaveService {
  final ObjectBoxStore _db;

  final List<Message> _queue = [];
  Timer? _flushTimer;
  bool _disposed = false;
  bool _isFlushing = false;
  bool _flushAgain = false;
  Completer<void>? _activeFlushCompleter;

  MessageSaveService(this._db);

  /// Enqueues [message] for a background save. Never blocks the caller.
  ///
  /// If the same message ID is already in the queue it is replaced
  /// (streaming updates supersede the previous checkpoint).
  void enqueue(Message message) {
    if (_disposed) return;
    final checkpoint = message.copyWith(updatedAt: DateTime.now());
    final idx = _queue.indexWhere((m) => m.id == checkpoint.id);
    if (idx != -1) {
      _queue[idx] = checkpoint;
    } else {
      _queue.add(checkpoint);
    }
    // Start a periodic flush timer on the first enqueue.
    _flushTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => _doFlush(),
    );
  }

  /// Drains the queue immediately. Awaiting this guarantees persistence
  /// before the caller updates final UI state.
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _doFlush();
  }

  Future<void> _doFlush() async {
    if (_isFlushing) {
      _flushAgain = true;
      await _activeFlushCompleter?.future;
      return;
    }

    _isFlushing = true;
    _activeFlushCompleter = Completer<void>();
    try {
      do {
        _flushAgain = false;
        if (_queue.isEmpty) break;

        final batch = List<Message>.from(_queue);
        _queue.clear();

        try {
          await _db.store.runInTransactionAsync(
            TxMode.write,
            _writeBatch,
            batch,
          );
        } catch (e) {
          Log.error('MessageSaveService flush error: $e');
        }
      } while (_flushAgain || _queue.isNotEmpty);
    } finally {
      _isFlushing = false;
      _activeFlushCompleter?.complete();
      _activeFlushCompleter = null;
    }
  }

  /// Runs inside a background isolate provided by ObjectBox.
  static void _writeBatch(Store store, List<Message> messages) {
    final box = store.box<MessageEntity>();
    final convBox = store.box<ConversationEntity>();

    for (final message in messages) {
      // Look up existing entity so we preserve the ObjectBox internal ID.
      final query = box.query(MessageEntity_.id.equals(message.id)).build();
      final existing = query.findFirst();
      query.close();

      final entity = MessageEntity.fromDomain(message);
      if (existing != null) {
        entity.internalId = existing.internalId;
      }

      // Re-establish the ToOne relation to the parent conversation.
      final convQuery = convBox
          .query(ConversationEntity_.id.equals(message.conversationId))
          .build();
      final convEntity = convQuery.findFirst();
      convQuery.close();

      if (convEntity != null) {
        entity.conversation.target = convEntity;
        entity.conversationUid = convEntity.id;
      } else {
        entity.conversationUid = message.conversationId;
      }

      box.put(entity);
    }
  }

  void dispose() {
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    _queue.clear();
  }
}
