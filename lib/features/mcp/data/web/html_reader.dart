import 'package:html/dom.dart';
import 'package:html/parser.dart' as parser;

const _blockTags = {
  'p',
  'div',
  'section',
  'article',
  'header',
  'footer',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'ul',
  'ol',
  'li',
  'table',
  'tr',
  'blockquote',
  'pre',
  'br',
  'hr',
  'figure',
  'figcaption',
  'address',
  'fieldset',
  'form',
  'main',
  'nav',
  'aside',
  'dl',
  'dt',
  'dd',
};

const _skipTags = {'script', 'style', 'noscript', 'template'};

String htmlToReadableText(String html, {int maxChars = 6000}) {
  final document = parser.parse(html);

  final buffer = StringBuffer();
  void walk(Node node) {
    if (node is Text) {
      final text = node.text.trim();
      if (text.isNotEmpty) {
        buffer
          ..write(text)
          ..write(' ');
      }
      return;
    }
    if (node is! Element) return;
    final name = node.localName;
    if (_skipTags.contains(name)) return;
    final isBlock = _blockTags.contains(name);
    if (isBlock && buffer.isNotEmpty) buffer.write('\n\n');
    if (name == 'li') buffer.write('- ');
    node.nodes.forEach(walk);
    if (isBlock && buffer.isNotEmpty) buffer.write('\n');
  }

  walk(document.documentElement ?? document);

  final text = buffer
      .toString()
      .replaceAllMapped(RegExp(r'[ \t]*\n[ \t]*'), (m) => '\n')
      .replaceAll(RegExp(r'[ ]{2,}'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  if (text.length <= maxChars) return text;
  return '${text.substring(0, maxChars)}\n\n[truncated after $maxChars characters]';
}

String? extractHtmlTitle(String html) {
  final document = parser.parse(html);
  final title = document.head?.querySelector('title')?.text.trim();
  if (title == null || title.isEmpty) return null;
  return title;
}
