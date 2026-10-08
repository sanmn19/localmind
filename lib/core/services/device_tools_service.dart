import 'package:flutter/services.dart';

/// Dart-side contract for the `local://device` MCP server's backing services.
///
/// TASK-SPAN NOTE: the launcher methods (compose/open/list) answer native
/// handlers on Android (MainActivity.kt, channel proven below). The contacts
/// methods are Task 3 scope — until they exist the No handler case surfaces
/// to the model via [DeviceChannelUnavailable], never a crash.

/// Method channel the native device-tools host answers on.
const deviceToolsChannel = MethodChannel('localmind/device_tools');

const deviceToolsMethodNameComposeEmail = 'composeEmail';
const deviceToolsMethodNameOpenApp = 'openApp';
const deviceToolsMethodNameListInstalledApps = 'listInstalledApps';
const deviceToolsMethodNameSearchContacts = 'searchContacts';
const deviceToolsMethodNameContactByEmail = 'contactByEmail';
const deviceToolsMethodNameContactByPhone = 'contactByPhone';

/// Native error codes the device_tools host raises. Every one of them
/// surfaces through [DeviceChannelUnavailable] with the code as the reason;
/// the server renders the generic `ERROR: device channel unavailable` line
/// for the model regardless of the code.
const deviceToolsErrorNoMailApp = 'no_mail_app';
const deviceToolsErrorAppNotInstalled = 'app_not_installed';
const deviceToolsErrorSecurityException = 'security_exception';

/// Raised by the channel-backed device services when the platform has no
/// handler for a device-tools call (or the call errors natively). The device
/// MCP server maps it to a readable `ERROR: ...` tool result for the model.
class DeviceChannelUnavailable implements Exception {
  const DeviceChannelUnavailable([this.reason]);

  final String? reason;

  @override
  String toString() => 'DeviceChannelUnavailable: device channel unavailable';
}

/// Channel-backed launcher over the intent channels MainActivity.kt hosts.
/// The native side answers `true`-or-throws; the readable result lines below
/// are what the device server renders for the model.
class MethodChannelDeviceAppLauncher implements DeviceAppLauncher {
  const MethodChannelDeviceAppLauncher();

  @override
  Future<String> composeEmail({
    required String to,
    required String subject,
    required String body,
    List<String>? cc,
  }) async {
    // The URI build itself lives native-side (the mail app receives the
    // Android intent); the fields travel under this contract.
    await _invokeDeviceTools(deviceToolsMethodNameComposeEmail, {
      'to': to,
      'subject': subject,
      'body': body,
      if (cc != null && cc.isNotEmpty) 'cc': cc,
    });
    return 'Opened your mail app with a message to $to';
  }

  @override
  Future<String> open(String target) async {
    await _invokeDeviceTools(deviceToolsMethodNameOpenApp, {'target': target});
    return 'Opened $target';
  }

  @override
  Future<List<DeviceAppEntry>> listInstalled() async {
    final payload = await _invokeDeviceTools(
      deviceToolsMethodNameListInstalledApps,
      const {},
    );
    return [
      for (final row in payload is List ? payload : const [])
        if (row is Map)
          DeviceAppEntry(
            label: row['label']?.toString() ?? '',
            package: row['package']?.toString() ?? '',
          ),
    ];
  }
}

/// Channel-backed contacts look-up. Task 3 swaps this for the real
/// flutter_contacts-backed repository under the same interface.
class MethodChannelDeviceContactsService implements DeviceContactsService {
  const MethodChannelDeviceContactsService();

  @override
  Future<List<ContactSummary>> search(String query) =>
      _contactsQuery(deviceToolsMethodNameSearchContacts, {'query': query});

  @override
  Future<List<ContactSummary>> byEmail(String email) =>
      _contactsQuery(deviceToolsMethodNameContactByEmail, {'email': email});

  @override
  Future<List<ContactSummary>> byPhone(String phone) =>
      _contactsQuery(deviceToolsMethodNameContactByPhone, {'phone': phone});

  Future<List<ContactSummary>> _contactsQuery(
    String method,
    Map<String, Object?> args,
  ) async {
    final payload = await _invokeDeviceTools(method, args);
    return [
      for (final row in payload is List ? payload : const [])
        if (row is Map)
          ContactSummary(
            name: row['name']?.toString() ?? '',
            emails: _stringList(row['emails']),
            phones: _stringList(row['phones']),
          ),
    ];
  }
}

Future<Object?> _invokeDeviceTools(
  String method,
  Map<String, Object?> args,
) async {
  try {
    return await deviceToolsChannel.invokeMethod<Object?>(method, args);
  } on PlatformException catch (e) {
    throw DeviceChannelUnavailable(e.code);
  } on MissingPluginException catch (e) {
    throw DeviceChannelUnavailable(e.message);
  }
}

List<String> _stringList(dynamic raw) => [
  if (raw is List)
    for (final item in raw)
      if (item is String) item,
];

/// Launcher seam behind the `apps.*` tools. Production wires the method
/// channel implementation; tests fake it and record the calls.
abstract class DeviceAppLauncher {
  /// Opens the device mail app pre-filled with the message. Returns a
  /// user-readable result line (the mail app itself is the send gate).
  Future<String> composeEmail({
    required String to,
    required String subject,
    required String body,
    List<String>? cc,
  });

  /// Launches an app by package name or a deep link URI.
  Future<String> open(String target);

  /// Installed apps (label + package) for `apps.list_installed`.
  Future<List<DeviceAppEntry>> listInstalled();
}

/// Contacts seam behind the `contacts.*` tools. Task 3 binds the real
/// flutter_contacts-backed repository; tests fake it with fixture rows.
abstract class DeviceContactsService {
  Future<List<ContactSummary>> search(String query);
  Future<List<ContactSummary>> byEmail(String email);
  Future<List<ContactSummary>> byPhone(String phone);
}

class DeviceAppEntry {
  const DeviceAppEntry({required this.label, required this.package});

  final String label;
  final String package;
}

class ContactSummary {
  const ContactSummary({
    required this.name,
    required this.emails,
    required this.phones,
  });

  final String name;
  final List<String> emails;
  final List<String> phones;
}
