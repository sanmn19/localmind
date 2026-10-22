import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/enums.dart';
import '../../chat/providers/model_selection_providers.dart';
import '../../servers/providers/server_providers.dart';
import '../data/embedding_gateway.dart';
import '../data/memory_retriever.dart';
import 'memory_providers.dart';

/// The embedding gateway for the active provider. Chat models rarely embed, so a
/// failure simply returns null and retrieval falls back to keywords.
final memoryEmbeddingGatewayProvider = Provider<EmbeddingGateway>((ref) {
  final server = ref.watch(activeServerProvider);
  if (server == null) return const NoopEmbeddingGateway();
  final modelId = ref.watch(selectedModelProvider)?.id ?? '';
  if (modelId.isEmpty) return const NoopEmbeddingGateway();
  final dio = Dio(
    BaseOptions(connectTimeout: const Duration(seconds: 5)),
  );
  switch (server.type) {
    case ServerType.ollama:
      return OllamaEmbeddingGateway(
        dio: dio,
        baseUrl: server.baseUrl,
        model: modelId,
      );
    case ServerType.openAICompatible:
    case ServerType.openRouter:
    case ServerType.requesty:
      final prefix = server.apiPathPrefix.isEmpty
          ? '/v1'
          : (server.apiPathPrefix.endsWith('/v1')
                ? server.apiPathPrefix
                : '${server.apiPathPrefix}/v1');
      return OpenAiCompatibleEmbeddingGateway(
        dio: dio,
        baseUrl: '${server.baseUrl}$prefix',
        model: modelId,
        apiKey: server.apiKey,
      );
    case ServerType.lmStudio:
    case ServerType.ollamaCloud:
    case ServerType.onDevice:
      return const NoopEmbeddingGateway();
  }
});

final memoryRetrieverProvider = Provider<MemoryRetriever>((ref) {
  return MemoryRetriever(
    store: ref.watch(memoryStoreProvider),
    repository: ref.watch(memoryRepositoryProvider),
    embeddings: ref.watch(memoryEmbeddingGatewayProvider),
  );
});
