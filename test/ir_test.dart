import 'package:docx_to_markdown/src/ir.dart';
import 'package:test/test.dart';

void main() {
  group('IR equality', () {
    test('meta is excluded from equality', () {
      final a = ParagraphBlock(
        [const TextInline('Hi')],
        meta: NodeMeta(
          location: const SourceLocation(part: 'p', path: '1'),
        ),
      );
      final b = ParagraphBlock(
        [const TextInline('Hi')],
        meta: NodeMeta(
          location: const SourceLocation(part: 'p', path: '2'),
        ),
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('HighlightInline and ColorInline equality reflects color', () {
      final yellow = HighlightInline([const TextInline('x')], color: 'yellow');
      expect(
        yellow == HighlightInline([const TextInline('x')], color: 'green'),
        isFalse,
      );
      expect(
        yellow,
        equals(HighlightInline([const TextInline('x')], color: 'yellow')),
      );

      final red = ColorInline([const TextInline('x')], color: 'FF0000');
      expect(
        red == ColorInline([const TextInline('x')], color: '00FF00'),
        isFalse,
      );
      expect(
        red,
        equals(ColorInline([const TextInline('x')], color: 'FF0000')),
      );
    });

    test('PageBreakBlock equals itself and differs from a horizontal rule', () {
      expect(const PageBreakBlock(), equals(const PageBreakBlock()));
      expect(const PageBreakBlock() == const HorizontalRuleBlock(), isFalse);
    });

    test('Document equality ignores footnote map order', () {
      final fn1 = FootnoteDefinition(
        id: '1',
        blocks: [
          ParagraphBlock([const TextInline('a')]),
        ],
      );
      final fn2 = FootnoteDefinition(
        id: '2',
        blocks: [
          ParagraphBlock([const TextInline('b')]),
        ],
      );

      final docA = Document(
        blocks: [
          ParagraphBlock([const TextInline('body')]),
        ],
        footnotes: {'1': fn1, '2': fn2},
      );
      final docB = Document(
        blocks: [
          ParagraphBlock([const TextInline('body')]),
        ],
        footnotes: {'2': fn2, '1': fn1},
      );

      expect(docA, equals(docB));
    });

    test('ListBlock equality reflects numberFormat', () {
      ListItem item() => ListItem(
        blocks: [
          ParagraphBlock([const TextInline('x')]),
        ],
      );
      final decimal = ListBlock(ordered: true, items: [item()]);
      final roman = ListBlock(
        ordered: true,
        items: [item()],
        numberFormat: ListNumberFormat.upperRoman,
      );
      expect(decimal == roman, isFalse);
      expect(decimal, equals(ListBlock(ordered: true, items: [item()])));
    });
  });

  group('DocumentMetadata', () {
    test('empty metadata is stable and isEmpty', () {
      expect(DocumentMetadata.empty.isEmpty, isTrue);
      expect(DocumentMetadata.empty.isNotEmpty, isFalse);
      expect(DocumentMetadata(), equals(DocumentMetadata.empty));
      expect(DocumentMetadata().hashCode, DocumentMetadata.empty.hashCode);
    });

    test('any single field makes metadata non-empty', () {
      expect(DocumentMetadata(title: 'T').isEmpty, isFalse);
      expect(DocumentMetadata(created: '2025').isEmpty, isFalse);
      expect(DocumentMetadata(keywords: const ['k']).isEmpty, isFalse);
      expect(DocumentMetadata(custom: const {'a': 'b'}).isEmpty, isFalse);
      expect(DocumentMetadata(extra: const {'x': 'y'}).isEmpty, isFalse);
    });

    test('value equality covers all fields', () {
      DocumentMetadata make() => DocumentMetadata(
        title: 'T',
        creator: 'C',
        subject: 'S',
        description: 'D',
        keywords: const ['k1', 'k2'],
        language: 'en',
        category: 'G',
        created: 'c',
        modified: 'm',
        lastModifiedBy: 'L',
        revision: 'R',
        custom: const {'a': '1'},
        extra: const {'e': '2'},
      );
      expect(make(), equals(make()));
      expect(make().hashCode, make().hashCode);
      expect(make() == make().copyWith(title: 'X'), isFalse);
      expect(make() == make().copyWith(keywords: const ['k1']), isFalse);
      expect(make() == make().copyWith(custom: const {'a': '2'}), isFalse);
    });

    test('keywords, custom and extra are unmodifiable', () {
      final m = DocumentMetadata(
        keywords: ['k'],
        custom: {'a': 'b'},
        extra: {'x': 'y'},
      );
      expect(() => m.keywords.add('z'), throwsUnsupportedError);
      expect(() => m.custom['c'] = 'd', throwsUnsupportedError);
      expect(() => m.extra['z'] = 'w', throwsUnsupportedError);
    });

    test('copyWith replaces only the given fields', () {
      final base = DocumentMetadata(title: 'T', creator: 'C');
      final copy = base.copyWith(creator: 'C2', subject: 'S');
      expect(copy.title, 'T');
      expect(copy.creator, 'C2');
      expect(copy.subject, 'S');
    });

    test('Document carries empty metadata by default', () {
      final doc = Document(blocks: const []);
      expect(doc.metadata, equals(DocumentMetadata.empty));
    });

    test('Document semantic equality reflects metadata', () {
      Document make(DocumentMetadata meta) => Document(
        blocks: [
          ParagraphBlock([const TextInline('body')]),
        ],
        metadata: meta,
      );
      expect(make(DocumentMetadata.empty), equals(make(DocumentMetadata())));
      expect(
        make(DocumentMetadata(title: 'A')) ==
            make(DocumentMetadata(title: 'B')),
        isFalse,
      );
    });
  });

  group('InlinePlainText', () {
    test('extracts text from nested inlines', () {
      final inlines = <Inline>[
        const TextInline('Hello'),
        const TextInline(' '),
        EmphInline([const TextInline('world')]),
        const TextInline(' '),
        LinkInline(url: 'https://x', children: [const TextInline('link')]),
        const TextInline(' '),
        const ImageInline(src: 'img.png', alt: 'alt'),
        const TextInline(' '),
        const FootnoteRefInline('1'),
      ];

      expect(inlines.toPlainText(), 'Hello world link alt ^');
    });
  });

  group('TableGrid', () {
    test('detects complexity', () {
      final simple = TableGrid(
        rows: [
          TableRow(
            cells: [
              TableCell(blocks: const []),
              TableCell(blocks: const []),
            ],
          ),
          TableRow(
            cells: [
              TableCell(blocks: const []),
              TableCell(blocks: const []),
            ],
          ),
        ],
      );
      expect(simple.isComplex, isFalse);

      final complex = TableGrid(
        rows: [
          TableRow(cells: [TableCell(blocks: const [], colSpan: 2)]),
          TableRow(
            cells: [
              TableCell(blocks: const []),
              TableCell(blocks: const []),
            ],
          ),
        ],
      );
      expect(complex.isComplex, isTrue);
    });
  });
}
