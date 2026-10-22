import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hugeicons/hugeicons.dart';

import 'package:localmind/features/chat/providers/chat_notifier.dart';
import 'package:localmind/features/chat/views/chat_screen.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart'
    as conv;
import 'package:localmind/l10n/app_localizations.dart';

/// One floating chat window, bound to a single conversation.
///
/// The window owns a nested [ProviderScope] so its [ChatScreen] reads its own
/// [ChatNotifier] instead of the app-wide one. Two windows therefore keep
/// independent drafts, streams and message lists, and loading a window's
/// conversation never changes the global active conversation.
class DesktopChatWindow extends ConsumerWidget {
  const DesktopChatWindow({super.key, required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(conv.conversationsProvider)
        .when(
          data: (conversations) {
            final conversation = conversations
                .where((candidate) => candidate.id == conversationId)
                .firstOrNull;
            if (conversation == null) {
              return const _MissingConversationState();
            }
            return ProviderScope(
              // A window keeps one session per conversation; a different
              // conversation in the same slot gets a fresh notifier.
              key: ValueKey(conversation.id),
              overrides: [
                chatProvider.overrideWith(
                  () => ChatNotifier(resumeLastChat: false),
                ),
                conv.activeConversationProvider.overrideWith(
                  () => _FixedActiveConversationNotifier(conversation),
                ),
              ],
              child: _ConversationLoader(conversation: conversation),
            );
          },
          loading: () =>
              const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          error: (error, stackTrace) => const _MissingConversationState(),
        );
  }
}

/// Loads the window's conversation into its own [ChatNotifier] once.
class _ConversationLoader extends ConsumerStatefulWidget {
  const _ConversationLoader({required this.conversation});

  final Conversation conversation;

  @override
  ConsumerState<_ConversationLoader> createState() =>
      _ConversationLoaderState();
}

class _ConversationLoaderState extends ConsumerState<_ConversationLoader> {
  String? _loadedConversationId;
  bool _isReady = false;

  @override
  void initState() {
    super.initState();
    _scheduleLoad();
  }

  @override
  void didUpdateWidget(covariant _ConversationLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_loadedConversationId != widget.conversation.id) {
      _isReady = false;
      _scheduleLoad();
    }
  }

  void _scheduleLoad() {
    final id = widget.conversation.id;
    if (_loadedConversationId == id) return;
    _loadedConversationId = id;
    // Provider state can't be written while the tree is building, so the load
    // starts after the first frame. `activate: false` keeps the app-wide active
    // conversation untouched: opening a second window must not steal the first
    // one's active chat.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await ref
          .read(chatProvider.notifier)
          .loadConversation(widget.conversation, activate: false);
      if (!mounted) return;
      setState(() => _isReady = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isReady) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return const ChatScreen();
  }
}

/// The window's active conversation, fixed to the one it was opened for.
class _FixedActiveConversationNotifier extends conv.ActiveConversationNotifier {
  _FixedActiveConversationNotifier(this.conversation);

  final Conversation conversation;

  @override
  Conversation? build() {
    // Resolve the latest copy of the fixed conversation so renames and other
    // metadata edits made elsewhere reach this window's app bar too.
    final conversations =
        ref.watch(conv.conversationsProvider).value ?? const [];
    return conversations
        .where((candidate) => candidate.id == conversation.id)
        .firstOrNull;
  }

  @override
  void setActiveConversation(Conversation? conversation) {
    // Only this window's own view changes; the global active conversation
    // belongs to whichever window the user last worked in.
    state = conversation;
  }
}

class _MissingConversationState extends StatelessWidget {
  const _MissingConversationState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    return Center(
      key: const ValueKey('desktop-chat-missing'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          HugeIcon(
            icon: HugeIcons.strokeRoundedAiChat01,
            size: 32,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.history_missing_title,
            style: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}
