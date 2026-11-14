import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/utils/json_safe.dart';

enum ToolApprovalDecision { deny, once, alwaysChat, alwaysGlobal }

/// Stable key for "this exact tool call with these exact arguments".
String toolApprovalSignature(String toolName, Map<String, dynamic> args) =>
    '$toolName|${jsonEncode(jsonSafe(args))}';

/// Per-chat and global "always approve" policies. Per-chat entries are keyed by
/// conversation id so two chats can make different choices for the same tool.
class ToolApprovalPolicy {
  ToolApprovalPolicy(this._prefs);

  final SharedPreferences _prefs;
  static const _globalKey = 'toolApprovalAlwaysGlobal';
  static String _chatKey(String conversationId) =>
      'toolApprovalAlwaysChat.$conversationId';

  bool isAlwaysApproved({
    required String conversationId,
    required String toolName,
    required Map<String, dynamic> args,
  }) {
    final signature = toolApprovalSignature(toolName, args);
    final global = _prefs.getStringList(_globalKey) ?? const [];
    if (global.contains(signature)) return true;
    final chat = _prefs.getStringList(_chatKey(conversationId)) ?? const [];
    return chat.contains(signature);
  }

  Future<void> remember({
    required ToolApprovalDecision decision,
    required String conversationId,
    required String toolName,
    required Map<String, dynamic> args,
  }) async {
    if (decision != ToolApprovalDecision.alwaysChat &&
        decision != ToolApprovalDecision.alwaysGlobal) {
      return;
    }
    final key = decision == ToolApprovalDecision.alwaysGlobal
        ? _globalKey
        : _chatKey(conversationId);
    final signature = toolApprovalSignature(toolName, args);
    final values = (_prefs.getStringList(key) ?? const []).toSet()
      ..add(signature);
    await _prefs.setStringList(key, values.toList());
  }

  Future<void> clearChat(String conversationId) async {
    await _prefs.remove(_chatKey(conversationId));
  }
}
