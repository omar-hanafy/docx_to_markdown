// Real-fixture metadata tests. Each expected front matter block below was
// derived by hand from the actual OOXML in the fixture's docProps/core.xml and
// docProps/custom.xml (see the docProps audit). The invariant
//   yamlOutput == frontMatter + "\n\n" + defaultOutput
// proves both the exact front matter and that the document body is byte-for-byte
// unchanged from the default (metadata-off) conversion.

import 'dart:io';

import 'package:docx_to_markdown/docx_to_markdown.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final String _goldenDir = p.join(Directory.current.path, 'test', 'docx_golden');

Future<String> convertFixture(String name, {MetadataMode? mode}) async {
  final bytes = File(p.join(_goldenDir, '$name.docx')).readAsBytesSync();
  final config = mode == null
      ? DocxToMarkdownConfig.defaults
      : DocxToMarkdownConfig(metadataMode: mode);
  return DocxConverter(bytes, config: config).convert();
}

void main() {
  group('document-properties.docx', () {
    // From docProps/core.xml + custom.xml: full core props (multiline
    // description with a decoded _x000d_), 11 vt:lpwstr custom properties.
    const expectedFrontMatter = r'''
---
title: Testing custom properties
author: A. M.
subject: This is the subject
description: |-
  Long description spanning several lines.
  This is á second line.
keywords:
  - keyword 1
  - keyword 2
lang: en-US
category: My Category
created: "2025-08-04T18:53:49Z"
modified: "2025-08-04T18:53:49Z"
custom:
  Company: My Company
  Second Custom Property: Second custom property value
  abstract: Quite a long description spanning several lines
  custom1: First custom property value
  custom3: "Escaping amp & ."
  custom4: "Escaping LT,GT < asdf > <"
  custom5: Escaping html asdf
  custom6: Escaping MD á a
  custom9: "Extended chars: € á é í ó ú $"
  nested-custom: ""
  subtitle: This is a subtitle
---''';

    test('yamlFrontMatter matches the OOXML and keeps the body', () async {
      final none = await convertFixture('document-properties');
      final yaml = await convertFixture(
        'document-properties',
        mode: MetadataMode.yamlFrontMatter,
      );
      expect(yaml, '${expectedFrontMatter.trimLeft()}\n\n$none');
    });

    test('default conversion emits no front matter', () async {
      final none = await convertFixture('document-properties');
      expect(none, isNot(startsWith('---')));
      expect(none, isNot(contains('author:')));
      expect(none, isNot(contains('nested-custom')));
    });
  });

  group('document-properties-short-desc.docx', () {
    // From docProps/core.xml: single-line description with an XML-entity amp;
    // custom.xml is empty (no custom block expected).
    const expectedFrontMatter = r'''
---
title: Testing custom properties
author: A. M.
subject: This is the subject
description: "Short description &."
keywords:
  - keyword 1
  - keyword 2
created: "2025-08-04T18:53:49Z"
modified: "2025-08-04T18:53:49Z"
---''';

    test('yamlFrontMatter matches the OOXML and keeps the body', () async {
      final none = await convertFixture('document-properties-short-desc');
      final yaml = await convertFixture(
        'document-properties-short-desc',
        mode: MetadataMode.yamlFrontMatter,
      );
      expect(yaml, '${expectedFrontMatter.trimLeft()}\n\n$none');
      expect(yaml, isNot(contains('custom:')));
    });

    test('default conversion emits no front matter', () async {
      final none = await convertFixture('document-properties-short-desc');
      expect(none, isNot(startsWith('---')));
      expect(none, isNot(contains('author:')));
    });
  });
}
