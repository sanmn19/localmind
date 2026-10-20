# Google Drive encrypted backup + safe rotation

Date: 2026-10-19 · Status: draft

## Intent

Localmind's only off-device backup today is S3 (encrypted, but users must own a
bucket and keys). Add one-tap **Google Drive** backup behind OAuth, keeping the
existing client-side encryption (Argon2id + AES-256-GCM), and make replacement
safe: before the remote state is overwritten, keep a **local copy and a cloud copy**
of the previous backup.

## Goals

1. Connect/disconnect Google Drive with OAuth 2.0 (PKCE, `drive.file` scope) and
   keep the authorization across restarts (silent restore, token refresh).
2. Upload the same encrypted envelope the S3 path uses — the Drive account only
   ever stores ciphertext.
3. Before replacing `v1/state.enc`, write the existing backup to
   `<appSupport>/cloud-backups/google-drive/<utc>.enc` (local copy) and
   `Localmind/backups/<utc>.enc` (cloud copy); keep the 3 newest of each.
4. Existing S3 sync keeps working unchanged.

## Non-goals

- Proton Drive (no public OAuth/Drive API for third-party apps; deferred).
- Multi-account or account switching.
- Background sync while the app is closed.
- Sharing or link creation.

## Anti-goals

- Never upload plaintext: every object is encrypted with the existing
  `CloudSyncCryptoService` before it leaves the device.
- Never overwrite the remote state without first creating both copies.
- Never store OAuth tokens in `SharedPreferences` or logs.
- Never delete a backup copy before its replacement copy is verified.

## Constraints

- Flutter 3.44.2 / Riverpod / existing `cloud_sync` feature slice.
- `google_sign_in ^7.2.0` (already a dependency) for OAuth; scope
  `drive.file` (only files the app creates).
- Drive REST API v3 over HTTPS (`www.googleapis.com/drive/v3`,
  `www.googleapis.com/upload/drive/v3`).
- `flutter_secure_storage` for any persisted provider metadata; tokens stay in the
  plugin's own store, never in prefs.
- The user supplies a Google Cloud OAuth **Android client ID** (build-time
  `GOOGLE_SERVER_CLIENT_ID`); the app cannot ship a usable client ID itself.

## Design

### Storage abstraction

`CloudSyncStorage` (new interface) with the existing S3 repository and a new
`GoogleDriveCloudSyncStorage`:

```dart
abstract class CloudSyncStorage {
  String get stateKey;                       // 'v1/state.enc'
  String attachmentKey(String identifier);    // 'v1/attachments/<id>.enc'
  String backupKey(DateTime at);              // 'backups/<utc>.enc'
  Future<void> testConnection();
  Future<CloudSyncRemoteState?> readState();
  Future<CloudSyncRemoteState?> readObject(String key);
  Future<String?> writeObject(String key, List<int> bytes);
  Future<void> deleteObject(String key);
}
```

`CloudSyncRemoteState.etag` is generalized in meaning to a per-backend version
string (S3 ETag; Drive `md5Checksum` with `modifiedTime` fallback).

Drive layout under an app-created `Localmind` folder:

```
Localmind/
  v1/state.enc
  v1/attachments/<identifier>.enc
  backups/<utc>.enc
```

### OAuth

`GoogleDriveOAuthService`:

- `connect()` — `GoogleSignIn.instance.authenticate(scopeHint: [driveFileScope])`;
  account email from `GoogleSignInAccount.email`.
- `restore()` — `attemptLightweightAuthentication()`; returns the account or null.
- `accessToken()` — `authorizationClient.authorizationForScopes([driveFileScope])`;
  the plugin refreshes expired access tokens; tokens are never written by us.
- `disconnect()` — `signOut()` + clear the saved account/provider choice.
- Startup: silent `restore()`; a connected account enables sync without a prompt.

### Rotation (the replacement contract)

In `CloudSyncController._performSync`, immediately before `writeState`:

1. Read the existing remote `state.enc`; if absent, nothing to rotate.
2. Write the local copy under `<appSupport>/cloud-backups/google-drive/`.
3. Upload the cloud copy as `backups/<utc>.enc`.
4. Verify both copies exist (local file length; remote `objectExists`), then prune
   to the 3 newest of each (local files by name, remote objects by name).
5. Only then write the new state. Any copy failure aborts the sync with a typed
   failure; the old state stays untouched.

`CloudSyncConfig` gains `provider` (`s3` | `googleDrive`) and `googleAccount`;
S3 fields stay for the S3 provider. The local repository keeps
`cloudSync.config.v2` with a v1→v2 migration defaulting to `s3`.

### UI

Cloud Sync screen gains a provider selector. Google Drive shows the account row
(`Connect Google Drive` / `Connected as <email>` + Disconnect); S3 keeps its
existing fields. The passphrase, sync-now, status, and journal behavior are shared.

## Testing

- Fake OAuth + fake Drive HTTP: connect/restore/token refresh, upload, download.
- Rotation: existing state → both copies created before the new write; prune to 3;
  abort when either copy fails (the old state remains).
- Encryption: the fake Drive never receives plaintext; a tampered payload fails
  decryption with the typed failure.
- UI: provider selector, connected account row, disconnect.

## Resolved during review (my calls)

- **Rotation cadence:** rotation runs at most once per hour per provider
  (`lastBackupAt`), plus always on an explicit "Back up now"; the normal 5 s
  debounced sync therefore does not create a backup every few seconds.
- **Restore from rotated copies is a non-goal:** copies are for manual recovery
  (local folder / Drive app); no list/restore UI this iteration.
- **Drive concurrency:** Drive has no usable `If-Match` for media content, so the
  sync takes a per-device lease (`v1/lease.json`: deviceId + heartbeat, 10 min
  TTL). A live foreign lease stops sync with a typed conflict instead of
  last-write-wins.
- **Google Sign-In ownership:** one shared core `GoogleSignInSession` initialized
  once per launch; Mail and Drive share it. Disconnecting Drive signs the account
  out (Mail sees the signed-out state too). The build-time ID is the **web**
  client ID (`GOOGLE_SERVER_CLIENT_ID`); the Android client is bound by
  package + SHA-1, not by code.
- **Per-provider secrets:** config, master key and salt are stored per provider,
  so S3 ↔ Drive switching is reversible and never re-keys the other backend.
- **Rotation is shared:** S3 gets the same `backups/` + local-copy guarantee.
- **Platform scope:** Android-first; the Drive provider is hidden on iOS until an
  iOS client ID + URL scheme are configured.
- **Account email:** non-secret account metadata stored in config (prefs) with the
  provider flag; tokens stay in the plugin's own store.

