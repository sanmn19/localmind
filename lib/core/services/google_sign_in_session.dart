import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

class GoogleAccount {
  const GoogleAccount({required this.email, this.displayName});

  final String email;

  final String? displayName;
}

/// The plugin surface, split out so the session is testable without Google.
abstract class GoogleAuthAdapter {
  Future<void> initialize();

  Future<GoogleAccount?> restore();

  Future<GoogleAccount> signIn();

  Future<String?> accessToken({bool interactive = false});

  Future<void> signOut();
}

class GoogleSignInAdapter implements GoogleAuthAdapter {
  static const driveFileScope =
      'https://www.googleapis.com/auth/drive.file';

  static const serverClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
  );

  bool _initialized = false;
  GoogleSignInAccount? _account;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    await GoogleSignIn.instance.initialize(
      serverClientId: serverClientId.isEmpty ? null : serverClientId,
    );
  }

  @override
  Future<GoogleAccount?> restore() async {
    await initialize();
    final account =
        await GoogleSignIn.instance.attemptLightweightAuthentication();
    if (account == null) return null;
    _account = account;
    return _map(account);
  }

  @override
  Future<GoogleAccount> signIn() async {
    await initialize();
    final account = await GoogleSignIn.instance.authenticate(
      scopeHint: const [driveFileScope],
    );
    _account = account;
    return _map(account);
  }

  @override
  Future<String?> accessToken({bool interactive = false}) async {
    final account = _account;
    if (account == null) return null;
    final client = account.authorizationClient;
    final authorization = interactive
        ? await client.authorizeScopes(const [driveFileScope])
        : await client.authorizationForScopes(const [driveFileScope]);
    return authorization?.accessToken;
  }

  @override
  Future<void> signOut() async {
    await GoogleSignIn.instance.signOut();
    _account = null;
  }

  GoogleAccount _map(GoogleSignInAccount account) => GoogleAccount(
        email: account.email,
        displayName: account.displayName,
      );
}

/// One initialized Google Sign-In for the whole app: Mail and Drive share it,
/// because the plugin requires [initialize] exactly once per launch.
class GoogleSignInSession {
  GoogleSignInSession(this._adapter);

  final GoogleAuthAdapter _adapter;

  GoogleAccount? _account;

  GoogleAccount? get account => _account;

  /// Silent restore after a restart; null when there is no usable session.
  Future<GoogleAccount?> restore() async {
    try {
      final account = await _adapter.restore();
      _account = account;
      return account;
    } catch (_) {
      return null;
    }
  }

  Future<GoogleAccount> connect() async {
    final account = await _adapter.signIn();
    _account = account;
    return account;
  }

  /// Refreshes silently by default; [interactive] may prompt.
  Future<String?> accessToken({bool interactive = false}) =>
      _adapter.accessToken(interactive: interactive);

  Future<void> disconnect() async {
    await _adapter.signOut();
    _account = null;
  }
}

final googleSignInSessionProvider = Provider<GoogleSignInSession>((ref) {
  return GoogleSignInSession(GoogleSignInAdapter());
});
