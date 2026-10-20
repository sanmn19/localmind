import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../objectbox.g.dart';
import 'entities.dart';

class ObjectBoxStore {
  late final Store store;

  late final Box<ServerEntity> serverBox;
  late final Box<PersonaEntity> personaBox;
  late final Box<ConversationEntity> conversationBox;
  late final Box<MessageEntity> messageBox;
  late final Box<ConversationFolderEntity> conversationFolderBox;
  late final Box<SavedMessageEntity> savedMessageBox;
  late final Box<SavedMessageFolderEntity> savedMessageFolderBox;
  late final Box<ManualModelEntity> manualModelBox;
  late final Box<MemoryEntity> memoryBox;
  late final Box<MemoryRelationEntity> memoryRelationBox;
  late final Box<MemoryEmbeddingEntity> memoryEmbeddingBox;

  ObjectBoxStore.fromStore(this.store) {
    serverBox = Box<ServerEntity>(store);
    personaBox = Box<PersonaEntity>(store);
    conversationBox = Box<ConversationEntity>(store);
    messageBox = Box<MessageEntity>(store);
    conversationFolderBox = Box<ConversationFolderEntity>(store);
    savedMessageBox = Box<SavedMessageEntity>(store);
    savedMessageFolderBox = Box<SavedMessageFolderEntity>(store);
    manualModelBox = Box<ManualModelEntity>(store);
    memoryBox = Box<MemoryEntity>(store);
    memoryRelationBox = Box<MemoryRelationEntity>(store);
    memoryEmbeddingBox = Box<MemoryEmbeddingEntity>(store);
  }

  /// Create an instance of ObjectBox storage.
  static Future<ObjectBoxStore> create() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final store = await openStore(directory: _storeDirectory(docsDir).path);
    return ObjectBoxStore.fromStore(store);
  }

  static Directory _storeDirectory(Directory docsDir) {
    return Directory(p.join(docsDir.path, objectBoxStoreDirectoryName));
  }

  /// Re-attach the app store from a SECOND isolate (foreground-service
  /// engine). ObjectBox multi-isolate contract: [Store.attach] must be used
  /// on the same directory opened by [create]; every isolate ends up with
  /// its own Store instance over the same underlying native store.
  static Future<ObjectBoxStore> attachAsSecondaryIsolate() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final storeDir = _storeDirectory(docsDir);
    if (!await storeDir.exists()) {
      await storeDir.create(recursive: true);
    }
    final store = Store.attach(getObjectBoxModel(), storeDir.path);
    return ObjectBoxStore.fromStore(store);
  }

  /// Attach variant for isolates without path-provider channels (the Ask
  /// Local card engine): the directory is HANDED OVER by the hosting
  /// engine in its bootstrap payload instead of resolved plugin-side. The
  /// card's directory never exists check happens in [create]'s process.
  static Future<ObjectBoxStore> attachAsSecondaryIsolateAt(
    String storeDirPath,
  ) async {
    final store = Store.attach(getObjectBoxModel(), storeDirPath);
    return ObjectBoxStore.fromStore(store);
  }
}

/// Directory name under the app documents dir holding the ObjectBox store.
const objectBoxStoreDirectoryName = 'localmind_objectbox';
