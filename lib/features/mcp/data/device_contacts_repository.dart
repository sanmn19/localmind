import '../../../core/services/device_tools_service.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';

/// Raised by [DeviceContactsRepository] when the READ_CONTACTS runtime
/// permission could not be obtained. The device server renders it as a
/// deliberate settings-guidance result line — never a raw plugin failure —
/// mirroring the STT mic-permission client shape.
class ContactsPermissionDenied implements Exception {
  const ContactsPermissionDenied();

  @override
  String toString() =>
      'contacts permission needed — grant it in system settings';
}

/// Owns the READ_CONTACTS runtime permission decision. Abstracted so tests
/// substitute a stub; shape mirrors [MicPermissionClient].
///
/// [isPermanentlyDenied] stays in the contract for settings-surface parity —
/// the repository itself reports one pinned rejection line regardless of
/// which denied state the OS reports.
abstract class ContactsPermissionClient {
  Future<bool> isGranted();

  Future<bool> isPermanentlyDenied();

  Future<bool> request();
}

class ContactsPermissionClientImpl implements ContactsPermissionClient {
  const ContactsPermissionClientImpl();

  @override
  Future<bool> isGranted() {
    return Permission.contacts.isGranted;
  }

  @override
  Future<bool> isPermanentlyDenied() {
    return Permission.contacts.isPermanentlyDenied;
  }

  @override
  Future<bool> request() {
    return Permission.contacts.request().then((status) => status.isGranted);
  }
}

/// One normalized row fetched out of the contacts store.
class ContactsPluginRow {
  const ContactsPluginRow({
    required this.name,
    required this.emails,
    required this.phones,
  });

  final String name;
  final List<String> emails;
  final List<String> phones;
}

/// Seam over the flutter_contacts plugin so unit tests never bind the real
/// plugin (same rationale as [CalendarService] keeping platform model classes
/// out of the layer: plain Dart rows only).
abstract class ContactsPluginClient {
  Future<List<ContactsPluginRow>> fetch();
}

/// Fetches the full book — name/email/phone properties only — and hands it
/// back as plain rows; everything else (filter/dedupe/cap) happens client-side.
class FlutterContactsPluginClient implements ContactsPluginClient {
  const FlutterContactsPluginClient();

  @override
  Future<List<ContactsPluginRow>> fetch() async {
    final contacts = await FlutterContacts.getAll(
      properties: {
        ContactProperty.name,
        ContactProperty.phone,
        ContactProperty.email,
      },
    );
    return [
      for (final contact in contacts)
        ContactsPluginRow(
          name: (contact.displayName ?? '').trim(),
          emails: [for (final email in contact.emails) email.address],
          phones: [for (final phone in contact.phones) phone.number],
        ),
    ];
  }
}

/// Real contacts look-up behind the `contacts.*` device tools. Implements
/// the Task-1 [DeviceContactsService] contract directly over the
/// flutter_contacts plugin — no method channel — with the READ_CONTACTS
/// runtime permission gated before the first query.
class DeviceContactsRepository implements DeviceContactsService {
  const DeviceContactsRepository({
    this.permissionClient = const ContactsPermissionClientImpl(),
    this.pluginClient = const FlutterContactsPluginClient(),
  });

  final ContactsPermissionClient permissionClient;
  final ContactsPluginClient pluginClient;

  /// List-shaped lookups clip to keep the tool result readable; the device
  /// server's 6000-char truncation catches long fields beyond the count cap.
  static const resultLimit = 30;

  @override
  Future<List<ContactSummary>> search(String query) => _run(_Scope.all, query);

  @override
  Future<List<ContactSummary>> byEmail(String email) =>
      _run(_Scope.email, email);

  @override
  Future<List<ContactSummary>> byPhone(String phone) =>
      _run(_Scope.phone, phone);

  Future<List<ContactSummary>> _run(_Scope scope, String input) async {
    if (input.trim().isEmpty) return const [];
    try {
      if (!await _granted()) throw const ContactsPermissionDenied();
      final rows = await pluginClient.fetch();
      return _select(rows, scope, input.trim().toLowerCase());
    } on ContactsPermissionDenied {
      rethrow;
    } on DeviceChannelUnavailable {
      rethrow;
    } catch (e) {
      throw DeviceChannelUnavailable(e.toString());
    }
  }

  /// Mirrors the STT `_obtainMicPermission` flow: ask, request when needed,
  /// and treat any broken permission channel as unavailable instead of crash.
  Future<bool> _granted() async {
    bool granted;
    try {
      granted = await permissionClient.isGranted();
      if (!granted) granted = await permissionClient.request();
    } catch (e) {
      throw DeviceChannelUnavailable('contacts permission check failed: $e');
    }
    return granted;
  }

  /// Sorts by name (case-insensitive), dedupes same name/primary email
  /// rows, then clips to [resultLimit].
  static List<ContactSummary> _select(
    List<ContactsPluginRow> rows,
    _Scope scope,
    String needle,
  ) {
    final candidates = <ContactSummary>[];
    for (final row in rows) {
      final emails = _normalized(row.emails);
      final phones = _normalized(row.phones);
      final name = row.name.trim();
      if (!_matches(name, emails, phones, scope, needle)) continue;
      candidates.add(
        ContactSummary(name: name, emails: emails, phones: phones),
      );
    }
    candidates.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    final seen = <String>{};
    final result = <ContactSummary>[];
    for (final contact in candidates) {
      if (result.length >= resultLimit) break;
      final key =
          '${contact.name.toLowerCase()}|'
          '${contact.emails.isEmpty ? '' : contact.emails.first.toLowerCase()}';
      if (seen.add(key)) result.add(contact);
    }
    return result;
  }

  static bool _matches(
    String name,
    List<String> emails,
    List<String> phones,
    _Scope scope,
    String needle,
  ) {
    switch (scope) {
      case _Scope.all:
        return name.toLowerCase().contains(needle) ||
            emails.any((e) => e.toLowerCase().contains(needle)) ||
            phones.any((p) => p.toLowerCase().contains(needle));
      case _Scope.email:
        return emails.any(
          (e) =>
              e.toLowerCase() == needle || e.toLowerCase().startsWith(needle),
        );
      case _Scope.phone:
        return phones.any((p) => _phoneDigitsMatch(p, needle));
    }
  }

  /// Digits-only comparison: strip non-digits on BOTH sides, then match on
  /// full equality, full containment (either way), or equality of the last
  /// ten digits (country-code variants).
  static bool _phoneDigitsMatch(String stored, String query) {
    final needleDigits = _digits(query);
    if (needleDigits.isEmpty) return false;
    final digits = _digits(stored);
    if (digits.isEmpty) return false;
    if (digits == needleDigits) return true;
    if (digits.contains(needleDigits) || needleDigits.contains(digits)) {
      return true;
    }
    return _lastTen(digits) == _lastTen(needleDigits);
  }

  static String _digits(String raw) => raw.replaceAll(_nonDigit, '');

  static String _lastTen(String digits) =>
      digits.length <= 10 ? digits : digits.substring(digits.length - 10);

  static List<String> _normalized(List<String> raw) {
    final result = <String>[];
    final seen = <String>{};
    for (final item in raw) {
      final value = item.trim();
      if (value.isEmpty) continue;
      if (seen.add(value.toLowerCase())) result.add(value);
    }
    return result;
  }
}

enum _Scope { all, email, phone }

final _nonDigit = RegExp(r'\D');
