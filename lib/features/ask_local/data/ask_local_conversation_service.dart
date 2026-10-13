import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/storage_providers.dart';
import '../../../core/storage/entities.dart';
import '../../../core/storage/objectbox_store.dart';
import '../../../core/utils/uuid.dart';
import '../../../objectbox.g.dart';
import '../../conversations/data/models/conversation.dart';

/// The `specialKind` marker value stamped on the Ask Local conversation row.
const String askLocalConversationKind = 'ask_local';

/// The row title Ask Local conversations are identified by (also the title
/// every newly created Ask Local conversation carries).
const String askLocalConversationTitle = 'Ask Local';

/// Resolves — or creates — THE Ask Local conversation row
/// (docs/specs/2026-10-13-ask-local-overlay.md).
///
/// The overlay chat is a single, persistent, user-visible conversation
/// marked with [askLocalConversationKind] via
/// `ConversationEntity.specialKind`, titled [askLocalConversationTitle].
/// Legacy tolerance: conversations titled 'Ask Local' that predate the
/// marker (a null `specialKind`) get STAMPED rather than duplicated, so an
/// upgrade can never fan out multiple Ask Local rows.
///
/// ObjectBox-backed CRUD fakes cleanly at the persistence boundary: the
/// transaction static re-filters the fetched rows in Dart on top of the
/// pushed-down query condition, mirroring the condition-agnostic-fake
/// convention of background_task_service.dart.
class AskLocalConversationService {
  /// [_db] may be omitted when only pure marker handling is needed (unit
  /// tests); persistence operations then throw [StateError].
  AskLocalConversationService([this._db]);

  final ObjectBoxStore? _db;

  ObjectBoxStore get _database {
    final db = _db;
    if (db == null) {
      throw StateError(
        'AskLocalConversationService.ensure requires a database — construct '
        'via askLocalConversationServiceProvider.',
      );
    }
    return db;
  }

  /// First-wins resolve-or-create of the Ask Local conversation, entirely
  /// inside a single WRITE transaction: a marker-authoritative lookup, then
  /// the legacy-title stamp fallback, then create.
  Future<Conversation> ensure() async {
    final db = _database;
    return db.store.runInTransactionAsync(
      TxMode.write,
      _ensureInBackground,
      null,
    );
  }

  static Conversation _ensureInBackground(Store store, void _) {
    final box = store.box<ConversationEntity>();

    // 1. Marker-authoritative lookup: exactly one row tags
    //    [askLocalConversationKind]. The Dart re-filter keeps the
    //    condition-agnostic persistence fakes authoritative.
    final markedQuery = box
        .query(
          ConversationEntity_.specialKind.equals(askLocalConversationKind),
        )
        .build();
    final markedRows = markedQuery.find();
    markedQuery.close();
    final marked = markedRows
        .where((row) => row.specialKind == askLocalConversationKind)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (marked.isNotEmpty) {
      return marked.first.toDomain();
    }

    // 2. Legacy-title tolerance: rows titled 'Ask Local' that carry a null
    //    marker were created before the specialKind column existed — stamp
    //    the oldest one in place instead of creating a duplicate.
    final legacyQuery = box
        .query(ConversationEntity_.title.equals(askLocalConversationTitle))
        .build();
    final titledRows = legacyQuery.find();
    legacyQuery.close();
    final legacy = titledRows
        .where((row) =>
            row.title == askLocalConversationTitle && row.specialKind == null)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (legacy.isNotEmpty) {
      final stamped = legacy.first;
      stamped.specialKind = askLocalConversationKind;
      box.put(stamped);
      return stamped.toDomain();
    }

    // 3. Create. Archived stays false — the overlay must not hide from
    //    history lists that surface unarchived rows.
    final now = DateTime.now();
    final created = ConversationEntity(
      id: generateUuidV4(),
      title: askLocalConversationTitle,
      createdAt: now,
      updatedAt: now,
      specialKind: askLocalConversationKind,
    );
    box.put(created);
    return created.toDomain();
  }
}

/// Db-wired [AskLocalConversationService] for the app.
final askLocalConversationServiceProvider =
    Provider<AskLocalConversationService>((ref) {
  return AskLocalConversationService(ref.watch(databaseProvider));
});
