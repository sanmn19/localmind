// ignore_for_file: prefer_initializing_formals
import 'package:flutter/services.dart' show PlatformException;
import 'package:msal_auth/msal_auth.dart' as msal;

import '../../../core/logger/app_logger.dart';
import 'mail_connector_config.dart';
import 'mail_common.dart';
import 'mail_token_store.dart';

/// Outlook/Graph-side auth token handed to the repository.
class OutlookToken {
  const OutlookToken({
    required this.accessToken,
    required this.email,
    required this.expiry,
  });

  final String accessToken;
  final String email;
  final DateTime expiry;
}

/// The boundary the office repository consumes; the real implementation
/// wraps msal_auth's public-client application and its platform caches.
abstract class OutlookAuthGateway {
  Future<OutlookToken?> signIn();

  Future<OutlookToken?> silentToken();

  Future<void> signOut();
}

/// msal-backed gateway. Empty/missing client id yields a structured
/// misconfiguration exception (the setup path is documented in
/// [MailConnectorConfig]).
class MsalOutlookAuthGateway implements OutlookAuthGateway {
  MsalOutlookAuthGateway({required MailTokenStore tokens, String? clientId})
    : _clientId = clientId,
      store = tokens;

  final String? _clientId;
  final MailTokenStore store;

  static const _graphDefaultScope = 'https://graph.microsoft.com/.default';

  msal.SingleAccountPca? _pca;
  bool _pcaTried = false;

  Future<void> _requireConfigured() async {
    final id = _clientId ?? '';
    if (id.trim().isEmpty) {
      throw const MailConnectorException(
        mailConnectorMisconfiguredCode,
        'Outlook connector is not configured for this build. Register the '
        'app in Azure (public client) and set its client id, then retry.',
      );
    }
  }

  @override
  Future<OutlookToken?> signIn() async {
    await _requireConfigured();
    try {
      final pca = await _pcaInstance();
      final result = await pca.acquireToken(scopes: [_graphDefaultScope]);
      final username = result.account.username;
      if (username == null || username.isEmpty) {
        throw const MailConnectorException(
          mailConnectorMisconfiguredCode,
          'The Microsoft account did not report an e-mail address.',
        );
      }
      await store.updateToken(
        MailProvider.outlook,
        username,
        result.accessToken,
        result.expiresOn,
      );
      return OutlookToken(
        accessToken: result.accessToken,
        email: username,
        expiry: result.expiresOn,
      );
    } on msal.MsalException catch (error) {
      throw _mapMsalError(error);
    } on PlatformException catch (error) {
      Log.error('MSAL platform failure: $error');
      throw MailConnectorException(
        mailRequestFailedCode,
        'Microsoft sign-in failed (${error.code}). Try again.',
      );
    }
  }

  @override
  Future<OutlookToken?> silentToken() async {
    try {
      final pca = await _pcaInstance();
      final result = await pca.acquireTokenSilent(scopes: [_graphDefaultScope]);
      final username = result.account.username;
      if (username == null || username.isEmpty) return null;
      await store.updateToken(
        MailProvider.outlook,
        username,
        result.accessToken,
        result.expiresOn,
      );
      return OutlookToken(
        accessToken: result.accessToken,
        email: username,
        expiry: result.expiresOn,
      );
    } on msal.MsalUiRequiredException {
      // Silent acquisition needs fresh consent or a re-sign-in.
      return null;
    } on msal.MsalException catch (error) {
      Log.error('MSAL silent acquisition failed: $error');
      return null;
    } on PlatformException catch (error) {
      Log.error('MSAL platform failure: $error');
      return null;
    }
  }

  @override
  Future<void> signOut() async {
    try {
      final pca = await _pcaInstance();
      await pca.signOut();
    } on msal.MsalException catch (error) {
      Log.error('MSAL sign-out failed: $error');
    }
  }

  /// Lazy single creation; msal_auth throws when the platform setup is
  /// missing (that surfaces as the misconfigured connector code).
  Future<msal.SingleAccountPca> _pcaInstance() async {
    if (_pca != null) return _pca!;
    if (_pcaTried) {
      throw const MailConnectorException(
        mailConnectorMisconfiguredCode,
        'Outlook connector failed to initialize. Verify the Azure '
        'registration and msal_config.json, then retry.',
      );
    }
    _pcaTried = true;
    try {
      final pca = await msal.SingleAccountPca.create(
        clientId: _clientId!,
        androidConfig: msal.AndroidConfig(
          configFilePath: 'assets/msal_config.json',
          redirectUri: outlookAndroidRedirectUri,
        ),
      );
      _pca = pca;
      return pca;
    } on msal.MsalException catch (error) {
      Log.error('MSAL PCA creation failed: $error');
      throw const MailConnectorException(
        mailConnectorMisconfiguredCode,
        'Outlook connector failed to initialize. Verify the Azure '
        'registration and msal_config.json, then retry.',
      );
    }
  }

  MailConnectorException _mapMsalError(msal.MsalException error) {
    if (error is msal.MsalUserCancelException) {
      return const MailConnectorException(
        mailNotAuthenticatedCode,
        'Microsoft sign-in was cancelled. Try again from the mail settings.',
      );
    }
    if (error is msal.MsalUiRequiredException) {
      return const MailConnectorException(
        mailNotAuthenticatedCode,
        'mail account is not connected — reconnect in the settings screen',
      );
    }
    return MailConnectorException(
      mailRequestFailedCode,
      'Microsoft sign-in failed: ${error.runtimeType}. Try again.',
    );
  }
}
