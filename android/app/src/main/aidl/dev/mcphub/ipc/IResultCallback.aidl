package dev.mcphub.ipc;

import android.os.ParcelFileDescriptor;

interface IResultCallback {
  void onResult(String callId, String resultJson, in ParcelFileDescriptor body);
  void onProgress(String callId, String progressJson);
  void onError(String callId, int code, String message);
}
