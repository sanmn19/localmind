import '../../../../core/services/device_tools_service.dart';

const deviceMcpServerLabel = 'Device';
const deviceMcpServerUrl = 'local://device';

/// Character cap shared by the device server's list-shaped tool outputs.
const deviceMaxChars = 6000;

/// Backing services for the in-process `local://device` MCP server. The
/// bundle travels with the services so re-registration (settings change)
/// always refreshes it; the interfaces stay injectable so tests (and the
/// not-yet-native channels) can pass fakes.
class DeviceServices {
  const DeviceServices({
    required this.contacts,
    required this.launcher,
    required this.screenshot,
  });
  final DeviceContactsService contacts;
  final DeviceAppLauncher launcher;
  final DeviceScreenshotService screenshot;
}

/// Pure intent builder: the mailto: URI the mail app receives. `to` stays
/// verbatim in the URI path (addr-specs carry no spaces); every query value
/// is percent-encoded and the segments are joined with `&`. The cc list is
/// encoded per address and comma-joined (literal commas separate addrs).
String composeEmailIntent({
  required String to,
  required String subject,
  required String body,
  List<String>? cc,
}) {
  final segments = <String>[
    'subject=${Uri.encodeComponent(subject)}',
    'body=${Uri.encodeComponent(body)}',
    if (cc != null && cc.isNotEmpty)
      'cc=${cc.map((addr) => Uri.encodeComponent(addr.trim())).join(',')}',
  ];
  return 'mailto:$to?${segments.join('&')}';
}

/// True when [target] may be handed to the OS launcher: either a package
/// name (`^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$`) or a deep link — a URI with a
/// scheme and no whitespace (https / localmind:// etc.).
bool isValidOpenTarget(String target) {
  if (target.contains(' ')) return false;
  const packageRegex = r'^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$';
  if (RegExp(packageRegex).hasMatch(target)) return true;
  final uri = Uri.tryParse(target);
  return uri != null && uri.scheme.isNotEmpty;
}

/// Model-readable rendering shared by the manager's device dispatch:
/// everything is plain text, never thrown, and list-shaped payloads are
/// truncated with an explicit `[truncated]` marker.
String truncateDeviceOutput(String output, {int maxChars = deviceMaxChars}) {
  if (output.length <= maxChars) return output;
  return '${output.substring(0, maxChars)}\n[truncated]';
}

String formatDeviceAppList(List<DeviceAppEntry> apps) {
  if (apps.isEmpty) return 'No installed apps reported.';
  final lines = [for (final app in apps) '- ${app.label} (${app.package})'];
  return truncateDeviceOutput(lines.join('\n'));
}

String formatContactSummaries(List<ContactSummary> contacts) {
  if (contacts.isEmpty) return 'No matching contacts found.';
  final lines = <String>[];
  for (final contact in contacts) {
    final detail = [
      if (contact.emails.isNotEmpty) 'emails: ${contact.emails.join(', ')}',
      if (contact.phones.isNotEmpty) 'phones: ${contact.phones.join(', ')}',
    ].join('; ');
    lines.add(
      detail.isEmpty ? '- ${contact.name}' : '- ${contact.name} — $detail',
    );
  }
  return truncateDeviceOutput(lines.join('\n'));
}

final _screenshotPathPattern = RegExp(r'\[path=([^\]]+)\]');

/// Extracts the `[path=<abs path>]` marker the `apps.screenshot` result
/// embeds. The chat layer uses the (absolute, existing) path to attach the
/// screenshot image to the follow-up request; null when the result carries
/// no marker (e.g. an error line).
String? parseScreenshotAttachPath(String result) {
  return _screenshotPathPattern.firstMatch(result)?.group(1);
}
