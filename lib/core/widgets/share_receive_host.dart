import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../logger/app_logger.dart';
import '../models/enums.dart';
import '../providers/app_providers.dart';
import '../providers/service_providers.dart';
import '../routes/app_routes.dart';
import '../routes/shell_back_scope.dart';
import '../services/share_receive_service.dart';
import '../../features/chat/providers/chat_providers.dart';
import '../../features/conversations/providers/conversation_providers.dart'
    as conv;
import '../../features/models/data/models/model_info.dart';
import '../../features/on_device/data/models/on_device_model.dart';
import '../../features/on_device/providers/on_device_providers.dart';
import '../../features/os_widget/providers/os_widget_providers.dart';
import '../../features/os_widget/views/components/model_loading_overlay.dart';
import '../../features/servers/providers/server_providers.dart';

/// Lands share-sheet content from other apps into LocalMind chats.
///
/// Mirrors [AndroidAssistantInvocationHost] (channel listening) and the
/// OS-widget host's new-chat flow (default-model prep + pending prompt):
/// - text payloads start a new chat and prefill the composer via
///   `widgetPendingPromptProvider`;
/// - file payloads prepare the default model, start a fresh thread and hand
///   the files to `sendMessage` like the assistant screenshot flow, then
///   delete the native share stash (the chat pipeline saves its own copies
///   through AttachmentHelpers).
class ShareReceiveHost extends ConsumerStatefulWidget {
  const ShareReceiveHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<ShareReceiveHost> createState() => _ShareReceiveHostState();
}

class _ShareReceiveHostState extends ConsumerState<ShareReceiveHost> {
  StreamSubscription<SharedPayload>? _subscription;

  bool _isLoadingModel = false;
  bool _isHandlingShare = false;
  String _loadingModelName = '';
  String? _loadingServerName;
  String _loadingStatusMessage = 'Loading model into memory...';
  bool _isCanceled = false;
  bool _isDisposed = false;

  @override
  void initState() {
    super.initState();
    final service = ref.read(shareReceiveServiceProvider);
    if (!service.isSupportedPlatform) return;

    _subscription = service.payloads.listen(_handlePayload);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(service.initialize());
    });
  }

  void _handlePayload(SharedPayload payload) {
    if (_isDisposed) return;
    unawaited(_handleShare(payload));
  }

  Future<void> _handleShare(SharedPayload payload) async {
    if (!mounted || _isDisposed) return;

    if (!ref.read(settingsProvider).shareTargetEnabled) {
      // Toggle off: the app is still a share target (the OS list cannot be
      // turned off from inside the app) but LocalMind discards the payload
      // silently — the stashed copies go with it.
      _deleteStashedFiles(payload);
      return;
    }

    switch (payload.kind) {
      case SharePayloadKind.text:
        await _handleTextShare(payload);
      case SharePayloadKind.file:
      case SharePayloadKind.files:
        await _handleFileShare(payload);
      default:
        _deleteStashedFiles(payload);
    }
  }

  /// Text prefill needs no model target — the msg composer consumes the
  /// pending prompt either on the already-open chat screen or once the new
  /// chat (re)mounts it.
  Future<void> _handleTextShare(SharedPayload payload) async {
    if (!mounted || _isDisposed) return;
    final text = payload.text;
    if (text == null || text.isEmpty) return;

    _navigateToChat();
    ref
        .read(conv.activeConversationIdProvider.notifier)
        .setActiveConversationId(null);
    ref.read(widgetPendingPromptProvider.notifier).setPrompt(text);
  }

  Future<void> _handleFileShare(SharedPayload payload) async {
    if (!mounted || _isDisposed) return;
    if (_isHandlingShare) {
      // A share is already mid-flight; a concurrent one is dropped together
      // with its stash (the user can simply re-share).
      _deleteStashedFiles(payload);
      return;
    }
    final files = payload.stashedFilePaths.map(File.new).toList();
    if (files.isEmpty) return;

    final settings = ref.read(settingsProvider);
    final defaultModelId = settings.defaultModelId;
    final defaultModelServerId = settings.defaultModelServerId;

    if (defaultModelId == null ||
        defaultModelId.isEmpty ||
        defaultModelServerId == null ||
        defaultModelServerId.isEmpty) {
      if (mounted) {
        ShadToaster.of(context).show(
          ShadToast(
            title: const Text('Default Model Required'),
            description: const Text(
              'Please configure a default model in Settings to receive shares.',
            ),
          ),
        );
      }
      // Keep the stash: after a default model is configured the next share
      // works, and the next share's newest-wins cleanup releases this one.
      return;
    }

    final servers = await ref.read(serversProvider.future);
    if (!mounted || _isDisposed) return;
    final defaultServer = servers
        .where((s) => s.id == defaultModelServerId)
        .firstOrNull;

    if (defaultServer == null) {
      if (mounted) {
        ShadToaster.of(context).show(
          ShadToast.destructive(
            title: const Text('Server Not Found'),
            description: const Text(
              'The server configured for the default model is no longer available.',
            ),
          ),
        );
      }
      return;
    }

    String modelDisplayName = defaultModelId;
    if (defaultServer.type == ServerType.onDevice) {
      final curated = OnDeviceModel.curatedModels
          .where((m) => m.id == defaultModelId)
          .firstOrNull;
      if (curated != null) modelDisplayName = curated.name;
    }

    _isHandlingShare = true;
    _isCanceled = false;
    setState(() {
      _isLoadingModel = true;
      _loadingModelName = modelDisplayName;
      _loadingServerName = defaultServer.name;
      _loadingStatusMessage = 'Loading model into memory...';
    });

    var filesSent = false;
    try {
      ref.read(activeServerIdProvider.notifier).setActiveServer(defaultServer);

      if (defaultServer.type == ServerType.onDevice) {
        final engineNotifier = ref.read(onDeviceEngineProvider.notifier);
        final engineState = ref.read(onDeviceEngineProvider);
        if (engineState.loadedModelId != defaultModelId ||
            engineState.status != OnDeviceEngineStatus.loaded) {
          setState(() {
            _loadingStatusMessage = 'Initializing on-device engine...';
          });
          await engineNotifier.loadModel(
            defaultModelId,
            settings.preferredBackend,
          );
          if (_isCanceled || !mounted || _isDisposed) return;
        }
      } else if (defaultServer.type == ServerType.lmStudio) {
        final apiService = ref.read(serverApiServiceProvider);
        setState(() {
          _loadingStatusMessage = 'Checking LM Studio instance...';
        });
        final running = await apiService.fetchRunningModels(defaultServer);
        if (_isCanceled || !mounted || _isDisposed) return;
        if (!running.contains(defaultModelId)) {
          setState(() {
            _loadingStatusMessage = 'Loading model in LM Studio...';
          });
          if (settings.unloadModelsBeforeLoad) {
            final instances = await ref.read(
              loadedModelsProvider(defaultServer).future,
            );
            await apiService.unloadAllInstances(defaultServer, instances);
          }
          await apiService.loadModelWithInstanceId(
            defaultServer,
            defaultModelId,
            contextLength: ref.read(chatParamsProvider).contextLength,
          );
          if (_isCanceled || !mounted || _isDisposed) return;
        }
      }

      final available = await ref.read(
        availableModelsProvider(defaultServer.id).future,
      );
      if (_isCanceled || !mounted || _isDisposed) return;
      final targetModel =
          available.where((m) => m.id == defaultModelId).firstOrNull ??
          ModelInfo(
            id: defaultModelId,
            name: modelDisplayName,
            serverId: defaultServer.id,
            serverType: defaultServer.type,
          );
      ref.read(selectedModelProvider.notifier).setModel(targetModel);

      _navigateToChat();

      // The screenshot-share shape: a fresh thread so the shared media opens
      // its own conversation.
      await ref.read(chatProvider.notifier).startNewConversation();
      if (_isCanceled || !mounted || _isDisposed) return;
      await ref.read(chatProvider.notifier).sendMessage('', attachments: files);
      // The chat pipeline saved its own copies of every attachment; the
      // native share stash is disposable now.
      filesSent = true;
    } catch (e) {
      Log.error('Error handling shared content: $e');
      if (mounted && !_isDisposed) {
        ShadToaster.of(context).show(
          ShadToast.destructive(
            title: const Text('Share Handling Failed'),
            description: Text('Failed to attach shared content: $e'),
          ),
        );
      }
    } finally {
      if (filesSent) _deleteStashedFiles(payload);
      _isHandlingShare = false;
      if (mounted && !_isDisposed) {
        setState(() {
          _isLoadingModel = false;
        });
      }
    }
  }

  /// Shares always land on the chat screen; if the shell is somewhere else
  /// (settings, history, ...) navigate it home first. No-op in plain widget
  /// tests, where no router is above the host.
  void _navigateToChat() {
    if (!mounted) return;
    final router = GoRouter.maybeOf(context);
    router?.go(AppRoutes.home);
  }

  void _deleteStashedFiles(SharedPayload payload) {
    for (final path in payload.stashedFilePaths) {
      try {
        final file = File(path);
        if (file.existsSync()) file.deleteSync();
      } catch (e) {
        Log.error('Share stash cleanup failed for $path: $e');
      }
    }
  }

  void _cancelLoading() {
    _isCanceled = true;
    if (!mounted || _isDisposed) return;
    setState(() {
      _isLoadingModel = false;
    });
  }

  @override
  void dispose() {
    _isDisposed = true;
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ShellBackOverride(
          onBack: _isLoadingModel ? _cancelLoading : null,
          child: widget.child,
        ),
        if (_isLoadingModel)
          Positioned.fill(
            child: ModelLoadingOverlay(
              modelName: _loadingModelName,
              serverName: _loadingServerName,
              statusMessage: _loadingStatusMessage,
              onCancel: _cancelLoading,
            ),
          ),
      ],
    );
  }
}
