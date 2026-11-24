package dev.mcphub.ipc;

import dev.mcphub.ipc.IResultCallback;

interface IPublisherCallback {
  String listTools();
  void invokeTool(String callId, String toolName, String argumentsJson, IResultCallback callback);
  void cancel(String callId);
}
