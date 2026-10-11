import 'package:docx_to_markdown/docx_to_markdown.dart';
import 'package:docx_to_markdown/src/markdown_renderer.dart';
import 'package:test/test.dart';

import 'utils/docx_fixture.dart';

void main() {
  group('Code span fidelity', () {
    const cases = {
      '`x': '`` `x ``',
      'x`': '`` x` ``',
      '`': '`` ` ``',
      '``': '``` `` ```',
      'x``y': '```x``y```',
      '   ': '`   `',
      ' x ': '`  x  `',
      ' x': '`  x `',
      'x ': '` x  `',
    };

    for (final entry in cases.entries) {
      test('preserves ${entry.key}', () {
        final markdown = MarkdownRenderer(config: DocxToMarkdownConfig.defaults)
            .render(
              Document(
                blocks: [
                  ParagraphBlock([CodeInline(entry.key)]),
                ],
              ),
            );
        expect(markdown, entry.value);
      });
    }

    test('preserves backtick runs longer than 99 characters', () {
      final code = '`' * 100;
      final fence = '`' * 101;
      final markdown = MarkdownRenderer(config: DocxToMarkdownConfig.defaults)
          .render(
            Document(
              blocks: [
                ParagraphBlock([CodeInline(code)]),
              ],
            ),
          );
      expect(markdown, '$fence $code $fence');
    });

    test('block fences enclose backtick runs longer than 99 characters', () {
      final code = '`' * 100;
      final fence = '`' * 101;
      final markdown = MarkdownRenderer(config: DocxToMarkdownConfig.defaults)
          .render(Document(blocks: [CodeBlock(text: code)]));
      expect(markdown, '$fence\n$code\n$fence');
    });
  });

  group('Suppressed paragraph numbering', () {
    test('numId zero keeps an ordinary paragraph', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Plain', numId: '0')),
      );
      expect(await DocxConverter(bytes).convert(), 'Plain');
    });

    test('direct numId zero removes style-inherited numbering', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(
          wP(text: 'Plain', styleId: 'ListStyle', numId: '0'),
        ),
        stylesXml:
            '<w:styles xmlns:w="http://schemas.openxmlformats.org/'
            'wordprocessingml/2006/main">'
            '<w:style w:type="paragraph" w:styleId="ListStyle">'
            '<w:pPr><w:numPr><w:numId w:val="1"/>'
            '</w:numPr></w:pPr></w:style></w:styles>',
        numberingXml: numberingXml(numId: '1', numFmt: 'decimal'),
      );
      expect(await DocxConverter(bytes).convert(), 'Plain');
    });

    test('numId zero preserves heading semantics', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(
          wP(text: 'Heading', styleId: 'Heading1', numId: '0'),
        ),
        stylesXml: stylesXml(
          styleId: 'Heading1',
          styleName: 'Heading 1',
          outlineLevel: 0,
        ),
      );
      expect(await DocxConverter(bytes).convert(), '# Heading');
    });
  });

  group('Independent endnote selection', () {
    test('endnotes retain definitions when footnotes are disabled', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(
          '<w:p><w:r><w:t>Body</w:t><w:footnoteReference w:id="1"/>'
          '<w:endnoteReference w:id="2"/></w:r></w:p>',
        ),
        footnotesXml:
            '<w:footnotes xmlns:w="http://schemas.openxmlformats.org/'
            'wordprocessingml/2006/main"><w:footnote w:id="1">'
            '<w:p><w:r><w:t>Footnote</w:t></w:r></w:p>'
            '</w:footnote></w:footnotes>',
        endnotesXml:
            '<w:endnotes xmlns:w="http://schemas.openxmlformats.org/'
            'wordprocessingml/2006/main"><w:endnote w:id="2">'
            '<w:p><w:r><w:t>Endnote</w:t></w:r></w:p>'
            '</w:endnote></w:endnotes>',
      );
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          includeFootnotes: false,
          includeEndnotes: true,
        ),
      ).convert();
      expect(markdown, 'Body[^endnote:2]\n\n---\n\n[^endnote:2]: Endnote');
    });

    test('renderer selects endnote definitions independently', () {
      final document = Document(
        blocks: [
          ParagraphBlock([const TextInline('Body')]),
        ],
        footnotes: {
          '1': FootnoteDefinition(
            id: '1',
            blocks: [
              ParagraphBlock([const TextInline('Footnote')]),
            ],
          ),
          'endnote:2': FootnoteDefinition(
            id: 'endnote:2',
            blocks: [
              ParagraphBlock([const TextInline('Endnote')]),
            ],
          ),
        },
      );
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig(
          includeFootnotes: false,
          includeEndnotes: true,
        ),
      ).render(document);
      expect(markdown, 'Body\n\n---\n\n[^endnote:2]: Endnote');
    });
  });

  for (final strict in [false, true]) {
    test('disabled comments skip malformed XML with strict=$strict', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Body')),
        commentsXml: '<w:comments>',
      );
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(strict: strict),
      ).convert();
      expect(markdown, 'Body');
    });
  }

  group('Tracked moves', () {
    const expected = {
      TrackChangesMode.acceptAll: 'BeforeBetweenMovedAfter',
      TrackChangesMode.rejectChanges: 'BeforeMovedBetweenAfter',
      TrackChangesMode.showDeletionsAsStrikethrough:
          'Before~~Moved~~BetweenMovedAfter',
    };
    for (final entry in expected.entries) {
      test('respects ${entry.key.name}', () async {
        final bytes = buildDocxBytes(
          documentXml: docXmlWithBody(
            '<w:p><w:r><w:t>Before</w:t></w:r>'
            '<w:moveFrom w:id="1"><w:r><w:t>Moved</w:t></w:r>'
            '</w:moveFrom><w:r><w:t>Between</w:t></w:r>'
            '<w:moveTo w:id="2"><w:r><w:t>Moved</w:t></w:r></w:moveTo>'
            '<w:r><w:t>After</w:t></w:r></w:p>',
          ),
        );
        final markdown = await DocxConverter(
          bytes,
          config: DocxToMarkdownConfig(trackChangesMode: entry.key),
        ).convert();
        expect(markdown, entry.value);
      });
    }
  });
}
