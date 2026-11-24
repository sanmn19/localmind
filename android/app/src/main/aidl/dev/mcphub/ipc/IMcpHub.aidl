package dev.mcphub.ipc;

import dev.mcphub.ipc.IPublisherCallback;
import dev.mcphub.ipc.IResultCallback;

interface IMcpHub {
  void registerPublisher(IPublisherCallback callback);
  void unregisterPublisher();
  String listTools();
  String callTool(String toolName, String argumentsJson, IResultCallback callback);
  void cancelCall(String callId);
  oneway void notifyToolsChanged();
}
