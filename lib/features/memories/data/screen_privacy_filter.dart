/// Best-effort text guard for screen samples and extracted memories.
///
/// Accessibility nodes expose card numbers and one-time codes as ordinary text,
/// and the sample queue plus the model prompt are both places where they must
/// never end up. This filter is deliberately conservative: a false positive only
/// drops one sample, while a false negative would store a financial secret.
abstract final class ScreenPrivacyFilter {
  /// 13-19 digits, optionally grouped with spaces or dashes.
  static final _groupedDigits = RegExp(r'\b\d(?:[ -]?\d){12,18}\b');

  /// A standalone 4-8 digit code, such as an OTP.
  static final _standaloneCode = RegExp(r'\b\d{4,8}\b');

  /// A standalone 3-4 digit code, such as a CVV.
  static final _shortCode = RegExp(r'\b\d{3,4}\b');

  static final _otpKeyword = RegExp(
    r'(otp|one[\s-]?time|verification code|security code|passcode|2fa|two[\s-]?factor)',
    caseSensitive: false,
  );

  static final _cvvKeyword = RegExp(
    r'(cvv2?|cvc2?|card verification|security code)',
    caseSensitive: false,
  );

  static final _expiryKeyword = RegExp(
    r'(card|credit|debit|expir\w*|valid (?:thru|through)|good thru)',
    caseSensitive: false,
  );

  static final _expiryDate = RegExp(
    r'\b(0[1-9]|1[0-2])\s*[/-]\s*(\d{2}|\d{4})\b',
  );

  /// True when [text] looks like it contains a card number, an OTP/CVV, or card
  /// expiry details. The caller should skip the whole sample or memory rather
  /// than try to redact a partial match.
  static bool containsSensitiveData(String text) {
    if (text.trim().isEmpty) return false;
    return _hasLuhnNumber(text) ||
        _hasCodeNear(text, _otpKeyword, _standaloneCode) ||
        _hasCodeNear(text, _cvvKeyword, _shortCode) ||
        _hasExpiryNear(text);
  }

  static bool _hasLuhnNumber(String text) {
    for (final match in _groupedDigits.allMatches(text)) {
      final digits = match.group(0)!.replaceAll(RegExp(r'\D'), '');
      if (digits.length >= 13 && digits.length <= 19 && _luhn(digits)) {
        return true;
      }
    }
    return false;
  }

  /// True when a code matching [code] sits within 30 characters of [keyword].
  static bool _hasCodeNear(String text, RegExp keyword, RegExp code) {
    for (final match in code.allMatches(text)) {
      if (keyword.hasMatch(_window(text, match.start, match.end))) return true;
    }
    return false;
  }

  static bool _hasExpiryNear(String text) {
    for (final match in _expiryDate.allMatches(text)) {
      if (_expiryKeyword.hasMatch(_window(text, match.start, match.end))) {
        return true;
      }
    }
    return false;
  }

  static String _window(String text, int start, int end) {
    final from = start - 30 < 0 ? 0 : start - 30;
    final to = end + 30 > text.length ? text.length : end + 30;
    return text.substring(from, to);
  }

  static bool _luhn(String digits) {
    var sum = 0;
    var double = false;
    for (var i = digits.length - 1; i >= 0; i--) {
      var value = digits.codeUnitAt(i) - 0x30;
      if (double) {
        value *= 2;
        if (value > 9) value -= 9;
      }
      sum += value;
      double = !double;
    }
    return sum % 10 == 0;
  }
}
