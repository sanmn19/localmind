import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/platform_support.dart';

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

  ObjectBoxStore.fromStore(this.store) {
    serverBox = Box<ServerEntity>(store);
    personaBox = Box<PersonaEntity>(store);
    conversationBox = Box<ConversationEntity>(store);
    messageBox = Box<MessageEntity>(store);
    conversationFolderBox = Box<ConversationFolderEntity>(store);
    savedMessageBox = Box<SavedMessageEntity>(store);
    savedMessageFolderBox = Box<SavedMessageFolderEntity>(store);
  }

  static ObjectBoxStore? _instance;

  /// Create an instance of ObjectBox storage.
  ///
  /// A second call in the same isolate (for example after "Try again" on the
  /// crash screen) reuses the open store: ObjectBox refuses to open the same
  /// directory twice in one isolate.
  static Future<ObjectBoxStore> create() async {
    final existing = _instance;
    if (existing != null) return existing;
    final baseDir = await _baseDirectory();
    final store = await openStore(
      directory: _storeDirectory(baseDir).path,
      // Sandboxed macOS apps must prefix ObjectBox's POSIX semaphores with an
      // application group; without it the store open fails with EPERM.
      macosApplicationGroup: isMacDesktop ? macosApplicationGroupId : null,
    );
    return _instance = ObjectBoxStore.fromStore(store);
  }

  /// macOS keeps the store in Application Support: it is inside the sandbox
  /// container and free of the Documents TCC prompt, which denies ObjectBox's
  /// memory-mapped data file on macOS 26. Mobile keeps Documents so the store
  /// stays in the user-visible app data it already used.
  static Future<Directory> _baseDirectory() async {
    if (isMacDesktop) return getApplicationSupportDirectory();
    return getApplicationDocumentsDirectory();
  }

  static Directory _storeDirectory(Directory docsDir) {
    return Directory(p.join(docsDir.path, objectBoxStoreDirectoryName));
  }

  /// Re-attach the app store from a SECOND isolate (foreground-service
  /// engine). ObjectBox multi-isolate contract: [Store.attach] must be used
  /// on the same directory opened by [create]; every isolate ends up with
  /// its own Store instance over the same underlying native store.
  static Future<ObjectBoxStore> attachAsSecondaryIsolate() async {
    final baseDir = await _baseDirectory();
    final storeDir = _storeDirectory(baseDir);
    if (!await storeDir.exists()) {
      await storeDir.create(recursive: true);
    }
    final store = Store.attach(getObjectBoxModel(), storeDir.path);
    return ObjectBoxStore.fromStore(store);
  }
}

/// Application group the macOS sandbox uses for ObjectBox's semaphores.
/// Must match `com.apple.security.application-groups` in both entitlements files.
const macosApplicationGroupId = 'pro.momin.localmind';

/// Directory name under the app documents dir holding the ObjectBox store.
const objectBoxStoreDirectoryName = 'localmind_objectbox';
