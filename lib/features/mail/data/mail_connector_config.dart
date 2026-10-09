/// User-supplied connector configuration. OAuth client ids are public
/// app identities; the secret-free nature of public clients means the
/// security lives in consent + token exchange, so constants here are safe.
///
/// **Setup required from the user:**
/// - Gmail: a Google Cloud OAuth client (Android, package
///   pro.momin.localmind) bound to the app's signing-key SHA-1, if native
///   consent + Gmail scopes must work out of the box.
/// - Outlook: an Azure app registration (public client, consumer tenants
///   allowed) with the platform redirect URI (msauth scheme wrapping the
///   base64 package signature) and a compatible msal config asset.
class MailConnectorConfig {
  const MailConnectorConfig._();

  /// google_sign_in `serverClientId` (empty = rely on the Android default).
  static const String googleServerClientId = '';

  /// Azure public-client id; empty = Outlook connector not configured.
  static const String outlookClientId = '';
}

/// The Android redirect URI msal means to match in Azure. It encodes the
/// apps signature hash; the user's Azure portal registration defines it.
/// Left empty until a user registers + supplies it via this constant.
const String outlookAndroidRedirectUri = '';
