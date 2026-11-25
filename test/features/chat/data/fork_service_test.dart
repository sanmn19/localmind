import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/chat_background_service_provider.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/services/chat_background_service.dart';
import 'package:localmind/core/storage/entities.dart';
import 'package:localmind/core/storage/objectbox_store.dart';
import 'package:localmind/objectbox.g.dart';
import 'package:localmind/features/chat/data/fork_service.dart';
import 'package:localmind/features/chat/data/models/chat_parameters.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/providers/chat_mcp_providers.dart';
import 'package:localmind/features/chat/providers/chat_notifier.dart';
import 'package:localmind/features/chat/providers/chat_params_providers.dart';
import 'package:localmind/features/chat/providers/model_selection_providers.dart';
import 'package:localmind/features/conversations/data/message_search_service.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart'
    as conv;
import 'package:localmind/features/servers/data/models/server.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:localmind/features/voice_mode/providers/voice_mode_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Task 2 of the selection-fork-chats feature: ForkService behavior
// (context assembly + quoting contract), the public slice points
// ChatNotifier exposes to fork consumers, and the exclusions that keep
// hidden fork conversations out of history and message search.
//
// ObjectBox-backed CRUD runs against the native libobjectbox.so, which the
// host unit-test toolchain does not ship (probe verified) — the mapping
// round-trip CRUD relies on is covered by fork_anchor_test.dart (Task 1).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ForkService.buildForkContextMessages', () {
    final anchoredHistory = <Message>[
      Message(
        id: 'sys-1',
        conversationId: 'c-main',
        role: MessageRole.system,
        content: 'sys',
        createdAt: DateTime.utc(2026, 10, 8, 10),
        status: MessageStatus.complete,
      ),
      Message(
        id: 'u-1',
        conversationId: 'c-main',
        role: MessageRole.user,
        content: 'who?',
        createdAt: DateTime.utc(2026, 10, 8, 10, 1),
        status: MessageStatus.complete,
      ),
      Message(
        id: 'a-1',
        conversationId: 'c-main',
        role: MessageRole.assistant,
        content: 'Ada Lovelace wrote it',
        createdAt: DateTime.utc(2026, 10, 8, 10, 2),
        status: MessageStatus.complete,
      ),
    ];

    test('first fork turn quotes the selection, anchored history intact', () {
      final ctx = ForkService().buildForkContextMessages(
        mainTimelineUpToAnchor: anchoredHistory,
        forkTurns: const [],
        question: 'who wrote it?',
        selectedText: 'Ada Lovelace wrote it',
      );

      // system + anchored history (anchor inclusive) + 1 fork turn. The
      // brief sketch's `expect(ctx.length, 3)` does not add up for the very
      // 3-row input its snippet seeds; the locked spec keeps the anchor row
      // in context, so 3 + 1 = 4.
      expect(ctx.length, anchoredHistory.length + 1);
      expect(ctx.first.id, 'sys-1');
      expect(ctx[1].content, 'who?');
      expect(ctx[2].content, 'Ada Lovelace wrote it');
      expect(ctx.last.role, MessageRole.user);
      expect(
        ctx.last.content,
        contains('Selected: "Ada Lovelace wrote it"\n\nwho wrote it?'),
      );
    });

    test('follow-up fork turns pass through without re-quoting', () {
      final priorTurn = Message(
        id: 'fk-1',
        conversationId: 'c-fork',
        role: MessageRole.user,
        content: 'first question',
        createdAt: DateTime.utc(2026, 10, 8, 11),
        status: MessageStatus.complete,
      );

      final ctx = ForkService().buildForkContextMessages(
        mainTimelineUpToAnchor: anchoredHistory,
        forkTurns: [priorTurn],
        question: 'second question',
        selectedText: 'Ada Lovelace wrote it',
      );

      expect(ctx.length, anchoredHistory.length + 2);
      expect(ctx.last.role, MessageRole.user);
      expect(ctx.last.content, 'second question');
    });
  });

  group('ForkService.createFork', () {
    test('inserts a hidden fork without touching the parent row', () async {
      final main = ConversationEntity.fromDomain(
        Conversation(
          id: 'main-1',
          title: 'Main chat',
          createdAt: DateTime.utc(2026, 10, 8),
          updatedAt: DateTime.utc(2026, 10, 8),
          isArchived: true,
          folderId: 'folder-1',
        ),
      );
      final conversations = _RecordingConversationBox([main]);
      final anchors = _RecordingAnchorBox();
      final store = _RecordingCrudStore({
        ConversationEntity: conversations,
        MessageEntity: _RecordingMessageBox(),
        ForkAnchorEntity: anchors,
      });

      final anchor = await ForkService(_FakeObjectBoxStore(store)).createFork(
        mainConversationId: main.id,
        anchorMessageId: 'a-1',
        selectedText: 'Ada Lovelace wrote it',
      );

      // The parent row is still exactly the same object — a fork must never
      // overwrite the chat it was created from.
      final parent = conversations.items.firstWhere((c) => c.id == main.id);
      expect(parent.title, 'Main chat');
      expect(parent.isFork, isFalse);
      expect(parent.isArchived, isTrue);
      expect(parent.folderId, 'folder-1');

      final fork = conversations.items.firstWhere(
        (c) => c.id == anchor.forkConversationId,
      );
      expect(conversations.items, hasLength(2));
      expect(fork.isFork, isTrue);
      expect(fork.forkOfMessageId, 'a-1');
      expect(fork.isArchived, isTrue);
      expect(fork.folderId, 'folder-1');
      expect(anchors.items.single.forkConversationId, fork.id);
    });
  });

  group('ForkService.repairForkConversations', () {
    test('splits a fork collapsed into its parent row', () async {
      final collapsed = ConversationEntity(
        id: 'collapsed-1',
        title: 'Fork — Main chat',
        createdAt: DateTime.utc(2026, 10, 8),
        updatedAt: DateTime.utc(2026, 10, 8),
      )..internalId = 1;
      MessageEntity row(
        String id,
        MessageRole role,
        String content,
        int minute,
      ) => MessageEntity(
        id: id,
        conversationUid: collapsed.id,
        roleIndex: role.index,
        content: content,
        createdAt: DateTime.utc(2026, 10, 8, 10, minute),
        statusIndex: MessageStatus.complete.index,
      );
      final messages = _RecordingMessageBox([
        row('m0', MessageRole.user, 'hello', 0),
        row('m1', MessageRole.assistant, 'hi', 1),
        row('m2', MessageRole.user, 'Selected: "hi"\n\nwhy?', 2),
        row('m3', MessageRole.assistant, 'because', 3),
      ]);
      final conversations = _RecordingConversationBox([collapsed]);
      final anchors = _RecordingAnchorBox([
        ForkAnchorEntity(
          id: 'anchor-1',
          mainConversationId: collapsed.id,
          anchorMessageId: 'm1',
          selectedText: 'hi',
          forkConversationId: collapsed.id,
          createdAt: DateTime.utc(2026, 10, 8, 10, 1),
        ),
      ]);
      final store = _RecordingCrudStore({
        ConversationEntity: conversations,
        MessageEntity: messages,
        ForkAnchorEntity: anchors,
      });

      await ForkService(
        _FakeObjectBoxStore(store),
      ).repairForkConversations();

      expect(conversations.items, hasLength(2));
      final parent = conversations.items.firstWhere(
        (c) => c.id == collapsed.id,
      );
      expect(parent.title, 'Main chat');
      expect(parent.isFork, isFalse);
      expect(parent.messageCount, 2);

      final fork = conversations.items.firstWhere(
        (c) => c.id != collapsed.id,
      );
      expect(fork.isFork, isTrue);
      expect(fork.forkOfMessageId, 'm1');
      expect(fork.messageCount, 2);
      expect(
        messages.items.firstWhere((m) => m.id == 'm2').conversationUid,
        fork.id,
      );
      expect(anchors.items.single.forkConversationId, fork.id);
    });
  });

  group('ChatNotifier.mainTimelineUpTo / messageById', () {
    test(
      'cuts at the anchor inclusive; post-anchor rows never enter the fork context',
      () async {
        final container = await _forkTestContainer(
          extraRows: [
            Message(
              id: 'u-2',
              conversationId: 'c-main',
              role: MessageRole.user,
              content: 'post-anchor question',
              createdAt: DateTime.utc(2026, 10, 8, 10, 3),
              status: MessageStatus.complete,
              variantGroupId: 'g-3',
              variantIndex: 0,
              threadOrder: 2,
              isActiveVariant: true,
              parentMessageId: 'a-1',
            ),
          ],
        );
        addTearDown(container.dispose);

        await container
            .read(chatProvider.notifier)
            .loadConversation(_forkChatConversation);
        await _drain();

        final notifier = container.read(chatProvider.notifier);
        final slice = notifier.mainTimelineUpTo('a-1');
        expect(slice, isNotNull);

        final ids = slice!
            .map((m) => m.id)
            .where((id) => !id.startsWith('system-'))
            .toList();
        expect(ids, ['u-1', 'a-1']);
        expect(ids.contains('u-2'), isFalse);

        // The anchored pre-tail stays newest-first at the cut edge and the
        // composed system row leads.
        expect(slice.first.role, MessageRole.system);
        expect(slice.last.id, 'a-1');

        // messageById surfaces rows for the open conversation only.
        expect(notifier.messageById('a-1', _forkChatConversation.id)?.id,
            'a-1');
        expect(notifier.messageById('a-1', 'other-conv'), isNull);
        expect(notifier.messageById('missing', _forkChatConversation.id),
            isNull);
      },
    );

    test('returns null when the anchor is unknown', () async {
      final container = await _forkTestContainer();
      addTearDown(container.dispose);

      await container
          .read(chatProvider.notifier)
          .loadConversation(_forkChatConversation);
      await _drain();

      expect(
        container.read(chatProvider.notifier).mainTimelineUpTo('nope'),
        isNull,
      );
    });
  });

  group('fork exclusions', () {
    test('filteredConversationsProvider hides fork rows', () async {
      SharedPreferences.setMockInitialValues({});
      final rows = [
        _conversation('keep-1'),
        _conversation('fork-1', isFork: true),
        _conversation('temp-1', isTemporary: true),
      ];
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          conv.conversationsProvider.overrideWith(
            () => _SeededConversations(rows),
          ),
        ],
      );
      addTearDown(container.dispose);

      // Dependencies of filteredConversationsProvider must resolve first:
      // the provider surfaces AsyncValue, and on a first synchronous read
      // the list is still AsyncLoading.
      await container.read(conv.conversationsProvider.future);
      final filteredAsync = container.read(conv.filteredConversationsProvider);
      final filtered = filteredAsync.value!;
      expect(filtered.map((c) => c.id), ['keep-1']);
    });

    test(
      'filteredConversationsProvider hides a fork identified only by its anchor',
      () async {
        SharedPreferences.setMockInitialValues({});
        final rows = [
          _conversation('keep-1'),
          _conversation('fork-1'),
        ];
        final container = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(
              await SharedPreferences.getInstance(),
            ),
            conv.conversationsProvider.overrideWith(
              () => _SeededConversations(rows),
            ),
            databaseProvider.overrideWithValue(
              _FakeAnchorStore([
                ForkAnchorEntity(
                  id: 'anchor-1',
                  mainConversationId: 'keep-1',
                  anchorMessageId: 'a-1',
                  selectedText: 'Ada',
                  forkConversationId: 'fork-1',
                  createdAt: DateTime.utc(2026, 10, 8),
                ),
              ]),
            ),
          ],
        );
        addTearDown(container.dispose);

        await container.read(conv.conversationsProvider.future);
        final filtered = container.read(conv.filteredConversationsProvider).value!;
        expect(filtered.map((c) => c.id), ['keep-1']);
      },
    );

    test('message search skips hits from excluded fork conversations', () {
      final db = _FakeSearchStore([
        MessageEntity(
          id: 'm-fork',
          conversationUid: 'fork-1',
          roleIndex: MessageRole.user.index,
          content: 'secret fork needle',
          createdAt: DateTime.utc(2026, 10, 8, 12),
          statusIndex: 1,
        ),
        MessageEntity(
          id: 'm-main',
          conversationUid: 'c-normal',
          roleIndex: MessageRole.user.index,
          content: 'main needle',
          createdAt: DateTime.utc(2026, 10, 8, 12, 1),
          statusIndex: 1,
        ),
      ]);

      final hits = MessageSearchService().searchMessages(
        db,
        query: 'needle',
        excludedConversationIds: {'fork-1'},
      );
      expect(hits, hasLength(1));
      expect(hits.single.conversationId, 'c-normal');
      expect(hits.single.conversationTitle, 'Test conv');

      // Without the exclusion the fork row would surface — proving the
      // exclusion is what keeps the fork panel's turns out of history.
      final unfiltered = MessageSearchService().searchMessages(
        db,
        query: 'needle',
      );
      expect(unfiltered.map((h) => h.conversationId).toSet(), {
        'fork-1',
        'c-normal',
      });
    });
  });
}

Future<void> _drain([int iterations = 40]) async {
  for (var i = 0; i < iterations; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Conversation _conversation(
  String id, {
  bool isFork = false,
  bool isTemporary = false,
}) {
  return Conversation(
    id: id,
    title: 'c-$id',
    createdAt: DateTime.utc(2026, 10, 8, 10),
    updatedAt: DateTime.utc(2026, 10, 8, 10),
    forkOfMessageId: isFork ? 'a-1' : null,
    forkSpan: isFork ? '{"text":"Ada Lovelace wrote it"}' : null,
    isFork: isFork,
    isTemporary: isTemporary,
  );
}

final _remoteServer = Server(
  id: 'remote',
  name: 'Remote',
  type: ServerType.ollama,
  host: '127.0.0.1',
  port: 11434,
  createdAt: DateTime.utc(2026, 10, 5),
  lastConnectedAt: DateTime.utc(2026, 10, 5),
  status: ConnectionStatus.connected,
);

final _forkChatConversation = _conversation('c-main');

Future<ProviderContainer> _forkTestContainer({
  List<Message> extraRows = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  return ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(
        await SharedPreferences.getInstance(),
      ),
      activeChatTargetProvider.overrideWithValue(
        ActiveChatTarget(
          server: _remoteServer,
          selectedModel: null,
          effectiveModelId: 'model',
          modelLabel: 'Model',
        ),
      ),
      chatParamsProvider.overrideWithValue(ChatParameters.defaults()),
      chatMcpConfigProvider.overrideWith(_DisabledMcpNotifier.new),
      chatBackgroundServiceProvider.overrideWithValue(
        _TestChatBackgroundService(),
      ),
      settingsProvider.overrideWith(_TestSettingsNotifier.new),
      voiceModeProvider.overrideWith(_IdleVoiceModeNotifier.new),
      conv.conversationsProvider.overrideWith(_TestConversationsNotifier.new),
      chatProvider.overrideWith(
        () => _ForkTimelineChatNotifier(seed: _seedTimeline(extraRows)),
      ),
    ],
  );
}

List<Message> _seedTimeline(List<Message> extraRows) {
  // Recorded-chats shape: one variant group per turn, threadOrder
  // increasing a step per turn, parentMessageId chaining the prior row —
  // the structure resolveActiveTimeline walks to a single active path.
  final u1 = Message(
    id: 'u-1',
    conversationId: _forkChatConversation.id,
    role: MessageRole.user,
    content: 'who?',
    createdAt: DateTime.utc(2026, 10, 8, 10, 1),
    status: MessageStatus.complete,
    variantGroupId: 'g-1',
    variantIndex: 0,
    threadOrder: 0,
    isActiveVariant: true,
  );
  final a1 = Message(
    id: 'a-1',
    conversationId: _forkChatConversation.id,
    role: MessageRole.assistant,
    content: 'Ada Lovelace wrote it',
    createdAt: DateTime.utc(2026, 10, 8, 10, 2),
    status: MessageStatus.complete,
    variantGroupId: 'g-2',
    variantIndex: 0,
    threadOrder: 1,
    isActiveVariant: true,
    parentMessageId: 'u-1',
  );
  return [u1, a1, ...extraRows];
}

class _ForkTimelineChatNotifier extends ChatNotifier {
  _ForkTimelineChatNotifier({required this.seed});

  final List<Message> seed;

  @override
  ChatState build() => const ChatState();

  @override
  Future<List<Message>> loadConversationMessages(String conversationId) async =>
      List.of(seed);

  @override
  Future<void> persistMessage(Message message) async {}
}

class _SeededConversations extends conv.ConversationsNotifier {
  _SeededConversations(this.rows);

  final List<Conversation> rows;

  @override
  Future<List<Conversation>> build() async => rows;

  @override
  Future<void> syncConversationStats(
    String id, {
    required int messageCount,
    required int characterCount,
    String? preview,
  }) async {}

  @override
  Future<void> updateTokenCount(String id, int totalTokenCount) async {}
}

class _TestConversationsNotifier extends conv.ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => [_forkChatConversation];

  @override
  Future<void> syncConversationStats(
    String id, {
    required int messageCount,
    required int characterCount,
    String? preview,
  }) async {}

  @override
  Future<void> updateTokenCount(String id, int totalTokenCount) async {}
}

class _DisabledMcpNotifier extends ChatMcpConfigNotifier {
  @override
  ChatMcpConfig build() => const ChatMcpConfig(enabled: false);
}

class _TestChatBackgroundService extends ChatBackgroundService {
  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

class _TestSettingsNotifier extends SettingsNotifier {
  @override
  AppSettings build() => AppSettings(
    resumeLastChat: false,
    autoGenerateTitle: false,
    // Compose the fallback system row so the slice layout (system leading)
    // is exercised, mirroring default UI sends.
    showSystemMessages: true,
  );
}

class _IdleVoiceModeNotifier extends VoiceModeNotifier {
  @override
  VoiceModeState build() => const VoiceModeState();
}

class _FakeObjectBoxStore extends Fake implements ObjectBoxStore {
  _FakeObjectBoxStore(this.store);

  @override
  final Store store;
}

class _RecordingCrudStore extends Fake implements Store {
  _RecordingCrudStore(this.boxes);

  final Map<Type, Object> boxes;

  @override
  Box<T> box<T>() => boxes[T]! as Box<T>;

  @override
  Future<R> runInTransactionAsync<R, P>(
    TxMode mode,
    R Function(Store, P) callback,
    P param,
  ) async => callback(this, param);
}

class _RecordingConversationBox extends Fake
    implements Box<ConversationEntity> {
  _RecordingConversationBox(this.items);

  final List<ConversationEntity> items;

  @override
  List<ConversationEntity> getAll() => List<ConversationEntity>.from(items);

  @override
  QueryBuilder<ConversationEntity> query([
    Condition<ConversationEntity>? qc,
  ]) => _FakeQueryBuilder(items);

  @override
  ConversationEntity? get(int id) =>
      items.where((item) => item.internalId == id).firstOrNull;

  @override
  int put(ConversationEntity entity, {PutMode mode = PutMode.put}) {
    final index = items.indexWhere((item) => item.id == entity.id);
    if (index >= 0) {
      items[index] = entity;
    } else {
      if (entity.internalId == 0) entity.internalId = items.length + 1;
      items.add(entity);
    }
    return entity.internalId;
  }
}

class _RecordingMessageBox extends Fake implements Box<MessageEntity> {
  _RecordingMessageBox([Iterable<MessageEntity> items = const []]) {
    this.items.addAll(items);
  }

  final List<MessageEntity> items = [];

  @override
  List<MessageEntity> getAll() => List<MessageEntity>.from(items);

  @override
  QueryBuilder<MessageEntity> query([Condition<MessageEntity>? qc]) =>
      _FakeQueryBuilder(items);

  @override
  int put(MessageEntity entity, {PutMode mode = PutMode.put}) {
    final index = items.indexWhere((item) => item.id == entity.id);
    if (index >= 0) {
      items[index] = entity;
    } else {
      if (entity.internalId == 0) entity.internalId = items.length + 1;
      items.add(entity);
    }
    return entity.internalId;
  }
}

class _RecordingAnchorBox extends Fake implements Box<ForkAnchorEntity> {
  _RecordingAnchorBox([Iterable<ForkAnchorEntity> items = const []]) {
    this.items.addAll(items);
  }

  final List<ForkAnchorEntity> items = [];

  @override
  List<ForkAnchorEntity> getAll() => List<ForkAnchorEntity>.from(items);

  @override
  int put(ForkAnchorEntity entity, {PutMode mode = PutMode.put}) {
    final index = items.indexWhere((item) => item.id == entity.id);
    if (index >= 0) {
      items[index] = entity;
    } else {
      if (entity.internalId == 0) entity.internalId = items.length + 1;
      items.add(entity);
    }
    return entity.internalId;
  }
}

class _FakeAnchorStore extends Fake implements ObjectBoxStore {
  _FakeAnchorStore(this.anchors);

  final List<ForkAnchorEntity> anchors;

  @override
  Store get store => _FakeAnchorBackingStore(anchors);
}

class _FakeAnchorBackingStore extends Fake implements Store {
  _FakeAnchorBackingStore(this.anchors);

  final List<ForkAnchorEntity> anchors;

  @override
  Box<T> box<T>() {
    if (T == ForkAnchorEntity) {
      return _FakeAnchorBox(anchors) as Box<T>;
    }
    throw UnimplementedError();
  }
}

class _FakeAnchorBox extends Fake implements Box<ForkAnchorEntity> {
  _FakeAnchorBox(this.anchors);

  final List<ForkAnchorEntity> anchors;

  @override
  List<ForkAnchorEntity> getAll() => List<ForkAnchorEntity>.from(anchors);
}

class _FakeSearchStore extends Fake implements ObjectBoxStore {
  _FakeSearchStore(this.messages);

  final List<MessageEntity> messages;

  @override
  Box<MessageEntity> get messageBox => _FakeMessageBox(messages);

  @override
  Box<ConversationEntity> get conversationBox =>
      _FakeConversationBox([
        ConversationEntity(
          id: 'c-normal',
          title: 'Test conv',
          createdAt: DateTime.utc(2026, 10, 8),
          updatedAt: DateTime.utc(2026, 10, 8),
        ),
      ]);
}

class _FakeMessageBox extends Fake implements Box<MessageEntity> {
  _FakeMessageBox(this.rows);

  final List<MessageEntity> rows;

  @override
  QueryBuilder<MessageEntity> query([Condition<MessageEntity>? qc]) =>
      _FakeQueryBuilder(rows);
}

class _FakeConversationBox extends Fake implements Box<ConversationEntity> {
  _FakeConversationBox(this.rows);

  final List<ConversationEntity> rows;

  @override
  QueryBuilder<ConversationEntity> query([Condition<ConversationEntity>? qc]) =>
      _FakeQueryBuilder(rows);
}

class _FakeQueryBuilder<T> extends Fake implements QueryBuilder<T> {
  _FakeQueryBuilder(this.rows);

  final List<T> rows;

  @override
  Query<T> build() => _FakeQuery<T>(rows);
}

class _FakeQuery<T> extends Fake implements Query<T> {
  _FakeQuery(this.rows);

  final List<T> rows;

  @override
  List<T> find() => List<T>.from(rows);

  @override
  T? findFirst() => rows.isEmpty ? null : rows.first;

  @override
  void close() {}
}
