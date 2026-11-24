import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/services/google_sign_in_session.dart';

class _FakeAuthAdapter extends Fake implements GoogleAuthAdapter {
  int restoreCalls = 0;
  int signInCalls = 0;
  int signOutCalls = 0;
  bool? lastInteractive;
  GoogleAccount? restored;
  GoogleAccount account = const GoogleAccount(
    email: 'me@example.com',
    displayName: 'Me',
  );
  String? token;

  @override
  Future<void> initialize() async {}

  @override
  Future<GoogleAccount?> restore() async {
    restoreCalls++;
    return restored;
  }

  @override
  Future<GoogleAccount> signIn() async {
    signInCalls++;
    return account;
  }

  @override
  Future<String?> accessToken({bool interactive = false}) async {
    lastInteractive = interactive;
    return token;
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
  }
}

void main() {
  test('accessToken asks interactively when the token is missing', () async {
    final adapter = _FakeAuthAdapter();
    final session = GoogleSignInSession(adapter);

    final token = await session.accessToken(interactive: true);

    expect(token, isNull);
    expect(adapter.restoreCalls, 1);
    expect(adapter.lastInteractive, isTrue);
  });

  test('a restored account is reused by silent token requests', () async {
    final adapter = _FakeAuthAdapter()
      ..restored = const GoogleAccount(email: 'me@example.com')
      ..token = 'token-1';
    final session = GoogleSignInSession(adapter);

    expect(await session.accessToken(), 'token-1');

    expect(adapter.restoreCalls, 1);
    expect(adapter.lastInteractive, isFalse);
    expect(session.account?.email, 'me@example.com');
  });

  test('connect stores the account and disconnect signs it out', () async {
    final adapter = _FakeAuthAdapter();
    final session = GoogleSignInSession(adapter);

    final account = await session.connect();

    expect(account.email, 'me@example.com');
    expect(adapter.signInCalls, 1);
    expect(session.account?.email, 'me@example.com');

    await session.disconnect();

    expect(adapter.signOutCalls, 1);
    expect(session.account, isNull);
  });
}
