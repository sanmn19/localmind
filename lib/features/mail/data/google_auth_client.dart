// ignore_for_file: prefer_initializing_formals
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart' as gsi;

import '../../../core/logger/app_logger.dart';
import 'mail_common.dart';

/// A Google-side auth token handed to repositories.
class GoogleToken {
  const GoogleToken({
    required this.accessToken,
    required this.email,
    required this.expiry,
  });

  final String accessToken;
  final String email;
  final DateTime expiry;
}

/// The boundary repositories consume; the real implementation wraps
/// google_sign_in and its initialize-requires-config behavior. Kept
/// abstract so tests run on canned tokens and the app never pops a
/// consent sheet from a unit test.
abstract class GoogleAuthGateway {
  /// Interactive sign-in + scope consent. Returns null when the user
  /// backed out or the client is not configured.
  Future<GoogleToken?> signIn();

  /// Silent token re-provisioning; null when not possible without UI.
  Future<GoogleToken?> silentToken();

  Future<void> signOut();
}

const gmailReadScope = 'https://www.googleapis.com/auth/gmail.readonly';
const gmailSendScope = 'https://www.googleapis.com/auth/gmail.send';

/// Wraps google_sign_in 7.x: initialize() once, authenticate() for the
/// account, then authorization headers for the mail scopes. Misconfigured
/// client situations (a missing/invalid OAuth client for this signing key)
/// surface as [MailConnectorException] with the setup code so the UI can
/// guide the user through adding the SHA-1-bound client.
class GoogleMailAuthGateway implements GoogleAuthGateway {
  GoogleMailAuthGateway({String? serverClientId})
    : _serverClientId = serverClientId;

  final String? _serverClientId;
  bool _initialized = false;
  gsi.GoogleSignInAccount? _account;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    try {
      await gsi.GoogleSignIn.instance.initialize(
        serverClientId: _serverClientId,
      );
      _initialized = true;
    } on PlatformException catch (error) {
      Log.error('Google sign-in initialize failed: $error');
      throw const MailConnectorException(
        mailConnectorMisconfiguredCode,
        'Gmail connector is not configured for this build. Add the Google '
        'Cloud OAuth client for this app and its signing key, then try again.',
      );
    }
  }

  /// Maps google_sign_in failures into connector codes; unknown errors
  /// surface as not-connected so the UI can offer a reconnect.
  MailConnectorException _mapSignInError(Object error) {
    if (error is gsi.GoogleSignInException) {
      switch (error.code) {
        case gsi.GoogleSignInExceptionCode.canceled:
        case gsi.GoogleSignInExceptionCode.clientConfigurationError:
        case gsi.GoogleSignInExceptionCode.providerConfigurationError:
          // A backing OAuth client misconfiguration is what most
          // configuration-less installs hit here.
          return const MailConnectorException(
            mailConnectorMisconfiguredCode,
            'Gmail connector is not configured for this build. Add the '
            'Google Cloud OAuth client for this signing key and retry.',
          );

        default:
          return MailConnectorException(
            mailNotAuthenticatedCode,
            'Google sign-in failed: ${error.description ?? error.code.name}. '
            'Retry from the mail connector settings.',
          );
      }
    }
    return MailConnectorException(
      mailNotAuthenticatedCode,
      'Google sign-in failed: $error. Retry from the mail connector settings.',
    );
  }

  @override
  Future<GoogleToken?> signIn() async {
    await _ensureInitialized();
    try {
      final account = await gsi.GoogleSignIn.instance.authenticate(
        scopeHint: [gmailReadScope, gmailSendScope],
      );
      final client = account.authorizationClient;
      // Consent-bearing scope grant first, then read the authorization.
      final authorization = await client.authorizeScopes([
        gmailReadScope,
        gmailSendScope,
      ]);
      // Keep the account around for silent re-provisioning later.
      _account = account;
      return GoogleToken(
        accessToken: authorization.accessToken,
        email: account.email,
        expiry: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
    } on gsi.GoogleSignInException catch (error) {
      // authenticate() throws on cancellation/misconfiguration; map and
      // let the caller decide.
      throw _mapSignInError(error);
    } on PlatformException catch (error) {
      throw _mapSignInError(error);
    }
  }

  @override
  Future<GoogleToken?> silentToken() async {
    await _ensureInitialized();
    try {
      final client = _account?.authorizationClient;
      if (client == null) return null;
      final headers = await client.authorizationHeaders([
        gmailReadScope,
        gmailSendScope,
      ]);
      final bearer = headers?['Authorization'];
      if (bearer == null || !bearer.startsWith('Bearer ')) return null;
      final email = _account?.email;
      if (email == null || email.isEmpty) return null;
      return GoogleToken(
        accessToken: bearer.substring('Bearer '.length),
        email: email,
        expiry: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
    } on gsi.GoogleSignInException catch (error) {
      Log.error('Google silent token failed: $error');
      return null;
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await gsi.GoogleSignIn.instance.signOut();
      _account = null;
    } on gsi.GoogleSignInException catch (error) {
      Log.error('Google sign-out failed: $error');
    }
  }
}
