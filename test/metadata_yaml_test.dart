import 'package:docx_to_markdown/src/ir.dart';
import 'package:docx_to_markdown/src/metadata_yaml.dart';
import 'package:test/test.dart';

void main() {
  group('yamlEncodeScalar quoting', () {
    test('leaves simple values plain', () {
      expect(yamlEncodeScalar('Hello'), 'Hello');
      expect(yamlEncodeScalar('A. M.'), 'A. M.');
      expect(yamlEncodeScalar('en-US'), 'en-US');
      expect(yamlEncodeScalar('keyword 1'), 'keyword 1');
      // Non-ASCII letters are not a quoting trigger.
      expect(yamlEncodeScalar('Escaping MD á a'), 'Escaping MD á a');
      expect(yamlEncodeScalar('Extended € é í ó ú'), 'Extended € é í ó ú');
    });

    test('quotes empty and whitespace-padded values', () {
      expect(yamlEncodeScalar(''), '""');
      expect(yamlEncodeScalar(' x'), '" x"');
      expect(yamlEncodeScalar('x '), '"x "');
      expect(yamlEncodeScalar('\tx'), '"\\tx"');
    });

    test('quotes values with structural punctuation', () {
      expect(yamlEncodeScalar('a: b'), '"a: b"');
      expect(yamlEncodeScalar('a & b'), '"a & b"');
      expect(yamlEncodeScalar('a < b > c'), '"a < b > c"');
      expect(yamlEncodeScalar('a # b'), '"a # b"');
      expect(yamlEncodeScalar('[x]'), '"[x]"');
      expect(yamlEncodeScalar('{x}'), '"{x}"');
      expect(
        yamlEncodeScalar('2025-08-04T18:53:49Z'),
        '"2025-08-04T18:53:49Z"',
      );
    });

    test('quotes leading-indicator values', () {
      expect(yamlEncodeScalar('- item'), '"- item"');
      expect(yamlEncodeScalar('? q'), '"? q"');
      expect(yamlEncodeScalar('*ref'), '"*ref"');
      expect(yamlEncodeScalar('@at'), '"@at"');
      expect(yamlEncodeScalar('%pct'), '"%pct"');
    });

    test('quotes YAML reserved words and numbers (as strings)', () {
      for (final v in [
        'true',
        'False',
        'NULL',
        'yes',
        'no',
        'on',
        'off',
        '~',
      ]) {
        expect(yamlEncodeScalar(v), '"$v"', reason: v);
      }
      expect(yamlEncodeScalar('42'), '"42"');
      expect(yamlEncodeScalar('007'), '"007"');
      expect(yamlEncodeScalar('3.14'), '"3.14"');
      expect(yamlEncodeScalar('-5'), '"-5"');
      expect(yamlEncodeScalar('1e6'), '"1e6"');
    });

    test('escapes backslashes and quotes inside double quotes', () {
      expect(yamlEncodeScalar(r'a\b'), r'"a\\b"');
      expect(yamlEncodeScalar('say "hi"'), r'"say \"hi\""');
    });
  });

  group('renderMetadataFrontMatter', () {
    test('returns empty string for empty metadata', () {
      expect(renderMetadataFrontMatter(DocumentMetadata.empty), '');
    });

    test('renders a full Pandoc-friendly block deterministically', () {
      final m = DocumentMetadata(
        title: 'My Title',
        creator: 'A. M.',
        subject: 'The subject',
        description: 'Line one.\nLine two.',
        keywords: const ['alpha', 'beta'],
        language: 'en-US',
        category: 'Reports',
        created: '2025-08-04T18:53:49Z',
        modified: '2025-08-05T09:00:00Z',
        custom: const {'beta': 'second', 'Alpha': 'first'},
      );
      expect(renderMetadataFrontMatter(m), '''
---
title: My Title
author: A. M.
subject: The subject
description: |-
  Line one.
  Line two.
keywords:
  - alpha
  - beta
lang: en-US
category: Reports
created: "2025-08-04T18:53:49Z"
modified: "2025-08-05T09:00:00Z"
custom:
  Alpha: first
  beta: second
---''');
    });

    test('omits absent fields and empty collections', () {
      final m = DocumentMetadata(title: 'Only Title');
      expect(renderMetadataFrontMatter(m), '---\ntitle: Only Title\n---');
    });

    test('renders a single keyword as a one-item list', () {
      final m = DocumentMetadata(keywords: const ['solo']);
      expect(renderMetadataFrontMatter(m), '---\nkeywords:\n  - solo\n---');
    });

    test('renders lastModifiedBy, revision and sorted extra props', () {
      final m = DocumentMetadata(
        lastModifiedBy: 'Bob',
        revision: '3',
        extra: const {'contentStatus': 'Final', 'identifier': 'X-1'},
      );
      expect(renderMetadataFrontMatter(m), '''
---
lastModifiedBy: Bob
revision: "3"
contentStatus: Final
identifier: X-1
---''');
    });

    test('quotes custom keys and values that need it', () {
      final m = DocumentMetadata(
        custom: const {'has:colon': 'v', 'plain': 'a & b', 'empty': ''},
      );
      expect(renderMetadataFrontMatter(m), '''
---
custom:
  empty: ""
  "has:colon": v
  plain: "a & b"
---''');
    });

    test('uses a clip block scalar when a value ends with a newline', () {
      final m = DocumentMetadata(description: 'a\nb\n');
      expect(
        renderMetadataFrontMatter(m),
        '---\ndescription: |\n  a\n  b\n---',
      );
    });

    test('a later indented line stays a block scalar', () {
      // Only a leading space on the FIRST line is ambiguous; deeper indentation
      // on later lines is valid block-scalar content.
      final m = DocumentMetadata(description: 'a\n  indented');
      expect(
        renderMetadataFrontMatter(m),
        '---\ndescription: |-\n  a\n    indented\n---',
      );
    });

    test('falls back to a quoted scalar when the first line starts with a '
        'space', () {
      final m = DocumentMetadata(description: '  lead\nsecond');
      expect(
        renderMetadataFrontMatter(m),
        '---\ndescription: "  lead\\nsecond"\n---',
      );
    });
  });
}
