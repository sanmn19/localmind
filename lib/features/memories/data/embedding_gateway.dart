import 'package:dio/dio.dart';

/// Embeddings seam: providers that support embeddings embed; the no-op keeps
/// retrieval working (keyword + graph) everywhere else.
abstract class EmbeddingGateway {
  bool get isAvailable;

  String get modelId;

  Future<List<double>?> embed(String text);
}

class NoopEmbeddingGateway implements EmbeddingGateway {
  const NoopEmbeddingGateway();

  @override
  bool get isAvailable => false;

  @override
  String get modelId => 'none';

  @override
  Future<List<double>?> embed(String text) async => null;
}

/// OpenAI-compatible `POST /v1/embeddings`.
class OpenAiCompatibleEmbeddingGateway implements EmbeddingGateway {
  OpenAiCompatibleEmbeddingGateway({
    required this.dio,
    required this.baseUrl,
    required this.model,
    this.apiKey,
    this.timeout = const Duration(seconds: 10),
  });

  final Dio dio;
  final String baseUrl;
  final String model;
  final String? apiKey;
  final Duration timeout;

  @override
  bool get isAvailable => true;

  @override
  String get modelId => model;

  @override
  Future<List<double>?> embed(String text) async {
    try {
      final response = await dio.post<Map<String, dynamic>>(
        '$baseUrl/embeddings',
        data: {
          'model': model,
          'input': text,
        },
        options: Options(
          headers: {
            if (apiKey != null && apiKey!.isNotEmpty)
              'Authorization': 'Bearer $apiKey',
          },
          receiveTimeout: timeout,
          sendTimeout: timeout,
        ),
      );
      final data = response.data?['data'];
      if (data is! List || data.isEmpty) return null;
      final embedding = data.first['embedding'];
      if (embedding is! List) return null;
      return embedding.whereType<num>().map((value) => value.toDouble()).toList();
    } catch (_) {
      return null;
    }
  }
}

/// Ollama `POST /api/embeddings`.
class OllamaEmbeddingGateway implements EmbeddingGateway {
  OllamaEmbeddingGateway({
    required this.dio,
    required this.baseUrl,
    required this.model,
    this.timeout = const Duration(seconds: 10),
  });

  final Dio dio;
  final String baseUrl;
  final String model;
  final Duration timeout;

  @override
  bool get isAvailable => true;

  @override
  String get modelId => model;

  @override
  Future<List<double>?> embed(String text) async {
    try {
      final response = await dio.post<Map<String, dynamic>>(
        '$baseUrl/embeddings',
        data: {
          'model': model,
          'prompt': text,
        },
        options: Options(
          receiveTimeout: timeout,
          sendTimeout: timeout,
        ),
      );
      final embedding = response.data?['embedding'];
      if (embedding is! List) return null;
      return embedding.whereType<num>().map((value) => value.toDouble()).toList();
    } catch (_) {
      return null;
    }
  }
}
