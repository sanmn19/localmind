import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/mcp/data/web/html_reader.dart';

void main() {
  const scriptHeavy = '''
<!doctype html><html><head><title>Sample &amp; Title</title>
<style>.k { display:none }</style></head>
<body>
  <script>alert("nope")</script>
  <h1>Main Heading</h1>
  <p>First paragraph with &mdash; dash and &quot;quotes&quot;.</p>
  <ul><li>alpha</li><li>beta</li></ul>
  <noscript>enable js</noscript>
</body></html>''';

  test('extracts readable text without scripts/styles/entities', () {
    final text = htmlToReadableText(scriptHeavy);
    expect(text, contains('Main Heading'));
    expect(text, contains('alpha'));
    expect(text, contains('beta'));
    expect(text, isNot(contains('alert')));
    expect(text, isNot(contains('display:none')));
    expect(text, isNot(contains('enable js')));
    expect(text, contains('Sample & Title'));
    expect(text, contains('First paragraph with — dash and "quotes".'));
  });

  test('truncates with a marker', () {
    final text = htmlToReadableText(scriptHeavy, maxChars: 40);
    expect(text, contains('[truncated after 40 characters]'));
  });

  test('collapses runs of spaces and newlines', () {
    final text = htmlToReadableText('<p>a   b</p><p>c</p><p>d</p>');
    expect(text, contains('a b'));
    expect(text, isNot(contains('  ')));
    expect(text, isNot(contains('\n\n\n')));
  });

  test('title helper', () {
    expect(extractHtmlTitle('<title>Doc</title><body>hi</body>'), 'Doc');
    expect(extractHtmlTitle('not html'), isNull);
  });
}
