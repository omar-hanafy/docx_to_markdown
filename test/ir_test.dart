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
