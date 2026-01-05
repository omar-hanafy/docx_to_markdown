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
