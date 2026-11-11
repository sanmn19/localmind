import 'package:permission_handler/permission_handler.dart';

import '../utils/platform_support.dart';

/// Owns the RECORD_AUDIO runtime permission decision. Abstracted so tests
/// can substitute a stub and so device-specific quirks (e.g. Samsung One UI
/// recognizers reporting permission errors after a granted dialog) can be
/// resolved against the real permission state instead of plugin guesses.
abstract class MicPermissionClient {
  Future<bool> isGranted();

  Future<bool> isPermanentlyDenied();

  Future<bool> request();
}

class MicPermissionClientImpl implements MicPermissionClient {
  const MicPermissionClientImpl();

  @override
  Future<bool> isGranted() async {
    // macOS has no permission_handler microphone status: the OS TCC prompt
    // fires on the first record, so the plugin path is always "granted" here.
    if (!supportsMicPermissionPlugin) return true;
    return Permission.microphone.isGranted;
  }

  @override
  Future<bool> isPermanentlyDenied() {
    return Permission.microphone.isPermanentlyDenied;
  }

  @override
  Future<bool> request() async {
    if (!supportsMicPermissionPlugin) return true;
    final status = await Permission.microphone.request();
    return status.isGranted;
  }
}
