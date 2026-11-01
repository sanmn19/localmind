import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/memories/data/screen_privacy_filter.dart';

void main() {
  test('a Luhn-valid card number is detected', () {
    expect(
      ScreenPrivacyFilter.containsSensitiveData(
        'Card 4111 1111 1111 1111 on file',
      ),
      isTrue,
    );
    expect(
      ScreenPrivacyFilter.containsSensitiveData('4111111111111111'),
      isTrue,
    );
  });

  test('a standalone OTP near its label is detected', () {
    expect(
      ScreenPrivacyFilter.containsSensitiveData(
        'Your verification code is 482913',
      ),
      isTrue,
    );
    expect(ScreenPrivacyFilter.containsSensitiveData('OTP: 7304'), isTrue);
  });

  test('card expiry and CVV patterns are detected', () {
    expect(
      ScreenPrivacyFilter.containsSensitiveData('Card expires 12/28'),
      isTrue,
    );
    expect(ScreenPrivacyFilter.containsSensitiveData('CVV 123'), isTrue);
  });

  test('a normal phone number passes', () {
    expect(
      ScreenPrivacyFilter.containsSensitiveData('Call me at +1 555 123 4567'),
      isFalse,
    );
    expect(
      ScreenPrivacyFilter.containsSensitiveData('Call 555-123-4567'),
      isFalse,
    );
  });

  test('ordinary screen text passes', () {
    expect(
      ScreenPrivacyFilter.containsSensitiveData(
        'Standup moved to 10:30 on 2026-10-21',
      ),
      isFalse,
    );
  });
}
