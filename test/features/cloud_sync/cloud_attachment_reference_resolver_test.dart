import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/cloud_sync/services/cloud_attachment_reference_resolver.dart';

void main() {
  test('local attachment names stay under the filesystem limit', () {
    final identifier = 'a' * 200;
    final decoded = '${'b' * 200}.pdf';
    final name = cloudAttachmentLocalName(identifier, decoded);
    expect(name.length, lessThanOrEqualTo(80));
    expect(name.endsWith('.pdf'), isTrue);
    expect(
      cloudAttachmentLocalName(identifier, decoded),
      name,
      reason: 'the name must be stable across syncs',
    );
  });

  const resolver = CloudAttachmentReferenceResolver();

  String reference(String id, String name) =>
      'cloud://$id/${base64UrlEncode(utf8.encode(name)).replaceAll('=', '')}';

  test(
    'preserves the prior reference by filename when a local file is missing',
    () {
      final first = reference('first', 'one.txt');
      final second = reference('second', 'two.png');

      expect(
        resolver.findPreviousReference(
          previousReferences: [first, second],
          localPath: '/missing/two.png',
          index: 0,
        ),
        second,
      );
    },
  );

  test(
    'falls back to stable attachment order and never invents a reference',
    () {
      final previous = reference('first', 'old-name.txt');
      expect(
        resolver.findPreviousReference(
          previousReferences: [previous],
          localPath: '/missing/renamed.txt',
          index: 0,
        ),
        previous,
      );
      expect(
        resolver.findPreviousReference(
          previousReferences: const [],
          localPath: '/missing/new.txt',
          index: 0,
        ),
        isNull,
      );
    },
  );
}
