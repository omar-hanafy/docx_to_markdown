import 'dart:typed_data';

import 'package:docx_to_markdown/docx_to_markdown.dart';
import 'package:docx_to_markdown/src/ooxml_package.dart';
import 'package:docx_to_markdown/src/parser.dart';
import 'package:docx_to_markdown/src/styles.dart';
import 'package:test/test.dart';

import 'utils/docx_fixture.dart';

Future<Document> parseDocument(
  Uint8List bytes, {
  DocxToMarkdownConfig? config,
}) async {
  final cfg = config ?? DocxToMarkdownConfig.defaults;
  final pkg = DocxPackage.openBytes(bytes);
  try {
    final styles = StyleRegistry();
    styles.setMonospaceFonts(cfg.monospaceFonts);
    styles.load(pkg.stylesXml);
    if (cfg.codeBlockStyleName.isNotEmpty) {
      styles.addCodeStyleName(cfg.codeBlockStyleName);
    }
    final parser = DocxParser(
      package: pkg,
      styles: styles,
      config: cfg,
      mediaMap: const {},
      onWarning: (_) {},
    );
    return parser.parseMainDocument();
  } finally {
    await pkg.close();
  }
}

void main() {
  group('DocxConverter input validation', () {
    test('empty bytes throws DocxPackageException', () async {
      final converter = DocxConverter(Uint8List(0));
      expect(converter.convert(), throwsA(isA<DocxPackageException>()));
    });

    test('invalid signature throws DocxPackageException', () async {
      final converter = DocxConverter(Uint8List.fromList([0x00, 0x01, 0x02]));
      expect(converter.convert(), throwsA(isA<DocxPackageException>()));
    });

    test('corrupt zip throws DocxPackageException', () async {
      final converter = DocxConverter(
        Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, 0x00]),
      );
      expect(converter.convert(), throwsA(isA<DocxPackageException>()));
    });
  });

  group('Parser + Renderer integration', () {
    test('renders simple paragraph', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Hello')),
      );
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), 'Hello');
    });

    test('renders heading via styles.xml', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(
          wP(
            styleId: 'Heading1',
            innerXml: wR(text: 'Title'),
          ),
        ),
        stylesXml: stylesXml(
          styleId: 'Heading1',
          styleName: 'Heading 1',
          outlineLevel: 0,
        ),
      );
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '# Title');
    });

    test('coalesces code style paragraphs into fenced code block', () async {
      final body = [
        wP(
          styleId: 'Code',
          innerXml: wR(text: 'line1'),
        ),
        wP(
          styleId: 'Code',
          innerXml: wR(text: 'line2'),
        ),
      ].join();
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        stylesXml: stylesXml(
          styleId: 'Code',
          styleName: 'Code',
          outlineLevel: null,
        ),
      );
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '```\nline1\nline2\n```');
    });

    test('parses ordered lists with numbering', () async {
      final body = [
        wP(
          numId: '1',
          ilvl: 0,
          innerXml: wR(text: 'A'),
        ),
        wP(
          numId: '1',
          ilvl: 0,
          innerXml: wR(text: 'B'),
        ),
      ].join();
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        numberingXml: numberingXml(numId: '1', numFmt: 'decimal', start: null),
      );
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          orderedListNumbering: OrderedListNumbering.keep,
        ),
      ).convert();
      expect(markdown.trim(), '1. A\n2. B');
    });

    test('parses list numbering from style-based numPr', () async {
      final styles = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:styleId="ListStyle">
    <w:pPr>
      <w:numPr>
        <w:numId w:val="1"/>
        <w:ilvl w:val="0"/>
      </w:numPr>
    </w:pPr>
  </w:style>
</w:styles>''';
      final body = [
        wP(
          styleId: 'ListStyle',
          innerXml: wR(text: 'A'),
        ),
        wP(
          styleId: 'ListStyle',
          innerXml: wR(text: 'B'),
        ),
      ].join();
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        stylesXml: styles,
        numberingXml: numberingXml(numId: '1', numFmt: 'decimal', start: null),
      );
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          orderedListNumbering: OrderedListNumbering.keep,
        ),
      ).convert();
      expect(markdown.trim(), '1. A\n2. B');
    });

    test('orderedListNumbering alwaysOne forces numbering', () async {
      final body = [
        wP(
          numId: '1',
          ilvl: 0,
          innerXml: wR(text: 'A'),
        ),
        wP(
          numId: '1',
          ilvl: 0,
          innerXml: wR(text: 'B'),
        ),
      ].join();
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        numberingXml: numberingXml(numId: '1', numFmt: 'decimal', start: null),
      );
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          orderedListNumbering: OrderedListNumbering.alwaysOne,
        ),
      ).convert();
      expect(markdown.trim(), '1. A\n1. B');
    });

    test('continues list item when paragraph is indented', () async {
      final body = [
        wP(
          numId: '1',
          ilvl: 0,
          innerXml: wR(text: 'Item'),
        ),
        '<w:p><w:pPr><w:ind w:left="720"/></w:pPr>${wR(text: "Continuation")}</w:p>',
      ].join();
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        numberingXml: numberingXml(numId: '1', numFmt: 'decimal', start: null),
      );
      final doc = await parseDocument(bytes);
      expect(doc.blocks.length, 1);
      final list = doc.blocks.first as ListBlock;
      expect(list.items.first.blocks.length, 2);
    });

    test('honors list start override', () async {
      final body = wP(
        numId: '1',
        ilvl: 0,
        innerXml: wR(text: 'A'),
      );
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        numberingXml: numberingXml(
          numId: '1',
          numFmt: 'decimal',
          start: null,
          startOverride: 3,
        ),
      );
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          orderedListNumbering: OrderedListNumbering.keep,
        ),
      ).convert();
      expect(markdown.trim(), '3. A');
    });

    test('groups consecutive same-numId items into one list', () async {
      // Regression: the abstract w:start must not split a continuing list.
      final body = [
        wP(
          numId: '1',
          ilvl: 0,
          innerXml: wR(text: 'Foo'),
        ),
        wP(
          numId: '1',
          ilvl: 0,
          innerXml: wR(text: 'Bar'),
        ),
        wP(
          numId: '1',
          ilvl: 0,
          innerXml: wR(text: 'Baz'),
        ),
      ].join();
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        numberingXml: numberingXml(numId: '1', numFmt: 'decimal', start: 1),
      );
      final doc = await parseDocument(bytes);
      expect(doc.blocks.length, 1);
      final list = doc.blocks.first as ListBlock;
      expect(list.items.length, 3);
    });

    test('a non-list paragraph splits adjacent same-numId lists', () async {
      final body = [
        wP(
          numId: '1',
          ilvl: 0,
          innerXml: wR(text: 'A'),
        ),
        wP(text: 'Interruption'),
        wP(
          numId: '1',
          ilvl: 0,
          innerXml: wR(text: 'B'),
        ),
      ].join();
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        numberingXml: numberingXml(numId: '1', numFmt: 'decimal', start: 1),
      );
      final doc = await parseDocument(bytes);
      expect(doc.blocks.length, 3);
      expect(doc.blocks.whereType<ListBlock>().length, 2);
    });

    test('different numIds stay separate lists', () async {
      const twoNums = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:abstractNum w:abstractNumId="1">
    <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/></w:lvl>
  </w:abstractNum>
  <w:abstractNum w:abstractNumId="2">
    <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/></w:lvl>
  </w:abstractNum>
  <w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>
  <w:num w:numId="2"><w:abstractNumId w:val="2"/></w:num>
</w:numbering>''';
      final body = [
        wP(
          numId: '1',
          ilvl: 0,
          innerXml: wR(text: 'A'),
        ),
        wP(
          numId: '2',
          ilvl: 0,
          innerXml: wR(text: 'B'),
        ),
      ].join();
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        numberingXml: twoNums,
      );
      final doc = await parseDocument(bytes);
      expect(doc.blocks.whereType<ListBlock>().length, 2);
    });

    test('instance startOverride wins over abstract start', () async {
      final body = wP(
        numId: '1',
        ilvl: 0,
        innerXml: wR(text: 'A'),
      );
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        numberingXml: numberingXml(
          numId: '1',
          numFmt: 'decimal',
          start: 5,
          startOverride: 3,
        ),
      );
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          orderedListNumbering: OrderedListNumbering.keep,
        ),
      ).convert();
      expect(markdown.trim(), '3. A');
    });

    test('abstract start is used when there is no override', () async {
      final body = wP(
        numId: '1',
        ilvl: 0,
        innerXml: wR(text: 'A'),
      );
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        numberingXml: numberingXml(numId: '1', numFmt: 'decimal', start: 5),
      );
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          orderedListNumbering: OrderedListNumbering.keep,
        ),
      ).convert();
      expect(markdown.trim(), '5. A');
    });

    test('parses hyperlinks via relationships', () async {
      final body = wP(
        innerXml: wHyperlink(
          rid: 'rId1',
          innerXml: wR(text: 'Link'),
        ),
      );
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        documentRels: const [
          DocxRel(
            id: 'rId1',
            type: DocxRelTypes.hyperlink,
            target: 'https://example.com',
            external: true,
          ),
        ],
      );
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '[Link](https://example.com)');
    });

    test('parses drawings as images', () async {
      final body = wP(
        innerXml: wR(
          innerXml: wDrawingImage(embedId: 'rId2', descr: 'AltText'),
        ),
      );
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        documentRels: const [
          DocxRel(
            id: 'rId2',
            type: DocxRelTypes.image,
            target: 'media/image1.png',
          ),
        ],
      );
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '![Image](image1.png)');
    });

    test('reads image title from docPr', () async {
      final body = wP(
        innerXml: wR(
          innerXml: wDrawingImage(
            embedId: 'rId2',
            descr: 'AltText',
            title: 'My Title',
          ),
        ),
      );
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        documentRels: const [
          DocxRel(
            id: 'rId2',
            type: DocxRelTypes.image,
            target: 'media/image1.png',
          ),
        ],
      );
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '![Image](image1.png "My Title")');
    });

    test('parses w:highlight and renders as mark when enabled', () async {
      final body = wP(
        innerXml: wR(text: 'x', rPrXml: '<w:highlight w:val="yellow"/>'),
      );
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(highlightMode: HighlightMode.mark),
      ).convert();
      expect(markdown.trim(), '<mark>x</mark>');
    });

    test('drops highlight by default', () async {
      final body = wP(
        innerXml: wR(text: 'x', rPrXml: '<w:highlight w:val="yellow"/>'),
      );
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), 'x');
    });

    test('parses w:color and renders as span when enabled', () async {
      final body = wP(
        innerXml: wR(text: 'x', rPrXml: '<w:color w:val="FF0000"/>'),
      );
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(textColorMode: TextColorMode.htmlSpan),
      ).convert();
      expect(markdown.trim(), '<span style="color:#FF0000">x</span>');
    });

    test('shaded run takes code precedence over highlight', () async {
      final body = wP(
        innerXml: wR(
          text: 'x',
          rPrXml:
              '<w:highlight w:val="yellow"/>'
              '<w:shd w:val="clear" w:fill="DDDDDD"/>',
        ),
      );
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          highlightMode: HighlightMode.mark,
          treatShadedRunsAsCode: true,
        ),
      ).convert();
      expect(markdown.trim(), '`x`');
    });

    test(
      'page-break-only paragraph becomes a page break when enabled',
      () async {
        final body = [
          wP(text: 'before'),
          wP(innerXml: '<w:r><w:br w:type="page"/></w:r>'),
          wP(text: 'after'),
        ].join();
        final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
        final markdown = await DocxConverter(
          bytes,
          config: DocxToMarkdownConfig(
            pageBreakMode: PageBreakMode.thematicBreak,
          ),
        ).convert();
        expect(markdown.trim(), 'before\n\n---\n\nafter');
      },
    );

    test('page breaks are ignored by default', () async {
      final body = [
        wP(text: 'before'),
        wP(innerXml: '<w:r><w:br w:type="page"/></w:r>'),
        wP(text: 'after'),
      ].join();
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown, isNot(contains('---')));
      expect(markdown.trim(), 'before\n\nafter');
    });

    test('drawing with missing rel falls back to text', () async {
      final body = wP(
        innerXml: wR(innerXml: wDrawingImage(embedId: 'rId404')),
      );
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '');
    });

    test('parses VML images', () async {
      final body = wP(innerXml: wR(innerXml: vmlImage('rId5')));
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        documentRels: const [
          DocxRel(
            id: 'rId5',
            type: DocxRelTypes.image,
            target: 'media/vml.png',
          ),
        ],
      );
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '![Image](vml.png)');
    });

    test('VML image with missing rel is ignored', () async {
      final body = wP(innerXml: wR(innerXml: vmlImage('rId404')));
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '');
    });

    test('flattens textbox content into inline text', () async {
      final body = wP(
        innerXml: wR(innerXml: wDrawingTextBox(['First', 'Second'])),
      );
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(lineBreakStyle: LineBreakStyle.newline),
      ).convert();
      expect(markdown.contains('First\n\nSecond'), isTrue);
    });

    test('parses fldSimple hyperlinks', () async {
      final body = wP(
        innerXml: wFldSimple(
          instr: 'HYPERLINK "https://example.com"',
          innerXml: wR(text: 'Click'),
        ),
      );
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '[Click](https://example.com)');
    });

    test('parses fldSimple anchor hyperlinks', () async {
      final body = wP(
        innerXml: wFldSimple(
          instr: 'HYPERLINK \\l "Section1"',
          innerXml: wR(text: 'Anchor'),
        ),
      );
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '[Anchor](#Section1)');
    });

    test('parses complex field hyperlinks', () async {
      final body = wP(
        innerXml: [
          '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
          '<w:r><w:instrText xml:space="preserve">HYPERLINK "https://example.com"</w:instrText></w:r>',
          '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
          '<w:r><w:t>Link</w:t></w:r>',
          '<w:r><w:fldChar w:fldCharType="end"/></w:r>',
        ].join(),
      );
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '[Link](https://example.com)');
    });

    test('parses REF cross-reference field as anchor link', () async {
      final body = wP(
        innerXml: [
          '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
          '<w:r><w:instrText xml:space="preserve">REF _Ref12345 \\h</w:instrText></w:r>',
          '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
          '<w:r><w:t>See section</w:t></w:r>',
          '<w:r><w:fldChar w:fldCharType="end"/></w:r>',
        ].join(),
      );
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '[See section](#_Ref12345)');
    });

    test('parses fldSimple REF as anchor link', () async {
      final body = wP(
        innerXml: wFldSimple(
          instr: 'REF _Ref99 \\h',
          innerXml: wR(text: 'X'),
        ),
      );
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '[X](#_Ref99)');
    });

    test('parses fldSimple PAGEREF as anchor link', () async {
      final body = wP(
        innerXml: wFldSimple(
          instr: 'PAGEREF _Ref77 \\h',
          innerXml: wR(text: '7'),
        ),
      );
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '[7](#_Ref77)');
    });

    test('PAGE field falls back to display text', () async {
      final body = wP(
        innerXml: wFldSimple(
          instr: 'PAGE',
          innerXml: wR(text: '7'),
        ),
      );
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '7');
    });

    test('navigable underscore bookmark emits anchor', () async {
      final body =
          '<w:p><w:bookmarkStart w:name="_Ref12345"/>'
          '<w:r><w:t>Target</w:t></w:r></w:p>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.contains('<a id="_Ref12345"></a>'), isTrue);
    });

    test('renders footnotes when enabled', () async {
      final body = wP(
        innerXml:
            '${wR(text: "Note")}\n<w:r><w:footnoteReference w:id="1"/></w:r>',
      );
      final footnotes =
          '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:footnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:footnote w:id="1">
    <w:p><w:r><w:t>Footnote text</w:t></w:r></w:p>
  </w:footnote>
</w:footnotes>''';
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        footnotesXml: footnotes,
      );
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.contains('[^1]'), isTrue);
      expect(markdown.contains('Footnote text'), isTrue);
    });

    test('renders endnotes when enabled', () async {
      final body = wP(
        innerXml:
            '${wR(text: "End")}\n<w:r><w:endnoteReference w:id="2"/></w:r>',
      );
      final endnotes =
          '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:endnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:endnote w:id="2">
    <w:p><w:r><w:t>Endnote text</w:t></w:r></w:p>
  </w:endnote>
</w:endnotes>''';
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        endnotesXml: endnotes,
      );
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(includeEndnotes: true),
      ).convert();
      expect(markdown.contains('endnote:2'), isTrue);
      expect(markdown.contains('Endnote text'), isTrue);
    });

    test('emits comments when includeComments is true', () async {
      final body =
          '<w:commentRangeStart w:id="1"/>'
          '${wR(text: "Text")}'
          '<w:commentRangeEnd w:id="1"/>';
      final comments =
          '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:comments xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:comment w:id="1" w:author="Alice">
    <w:p><w:r><w:t>Note</w:t></w:r></w:p>
  </w:comment>
</w:comments>''';
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(innerXml: body)),
        commentsXml: comments,
      );
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(includeComments: true),
      ).convert();
      expect(markdown.contains('^[Alice: Note]'), isTrue);
    });

    test('unknown element policy keepHtml emits comment', () async {
      final body = '<w:customUnknown>Inner</w:customUnknown>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          unknownElementPolicy: UnknownElementPolicy.keepHtml,
        ),
      ).convert();
      expect(markdown.contains('Unsupported'), isTrue);
    });

    test('unknown inline keepHtml emits HTML comment', () async {
      final body = '<w:p><w:customInline>Inline</w:customInline></w:p>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          unknownElementPolicy: UnknownElementPolicy.keepHtml,
        ),
      ).convert();
      expect(markdown.contains('<!--'), isTrue);
    });

    test('unknown element policy keepText retains inner text', () async {
      final body = '<w:customUnknown>Inner</w:customUnknown>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          unknownElementPolicy: UnknownElementPolicy.keepText,
        ),
      ).convert();
      expect(markdown.trim(), 'Inner');
    });

    test('unknown element policy drop removes content', () async {
      final body = '<w:customUnknown>Inner</w:customUnknown>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          unknownElementPolicy: UnknownElementPolicy.drop,
        ),
      ).convert();
      expect(markdown.trim(), '');
    });

    test('unknown inline keepText retains inner text', () async {
      final body = '<w:p><w:customInline>Inline</w:customInline></w:p>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          unknownElementPolicy: UnknownElementPolicy.keepText,
        ),
      ).convert();
      expect(markdown.trim(), 'Inline');
    });

    test('unknown inline drop removes content', () async {
      final body = '<w:p><w:customInline>Inline</w:customInline></w:p>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          unknownElementPolicy: UnknownElementPolicy.drop,
        ),
      ).convert();
      expect(markdown.trim(), '');
    });

    test('complex tables render as HTML with spans', () async {
      final table = '''<w:tbl>
  <w:tr>
    <w:tc>
      <w:tcPr><w:vMerge w:val="restart"/></w:tcPr>
      <w:p><w:r><w:t>A</w:t></w:r></w:p>
    </w:tc>
    <w:tc>
      <w:tcPr><w:gridSpan w:val="2"/></w:tcPr>
      <w:p><w:r><w:t>B</w:t></w:r></w:p>
    </w:tc>
  </w:tr>
  <w:tr>
    <w:tc>
      <w:tcPr><w:vMerge/></w:tcPr>
      <w:p><w:r><w:t>Skip</w:t></w:r></w:p>
    </w:tc>
    <w:tc>
      <w:p><w:r><w:t>C</w:t></w:r></w:p>
    </w:tc>
    <w:tc>
      <w:p><w:r><w:t>D</w:t></w:r></w:p>
    </w:tc>
  </w:tr>
</w:tbl>''';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(table));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.contains('<table>'), isTrue);
      expect(markdown.contains('rowspan="2"'), isTrue);
      expect(markdown.contains('colspan="2"'), isTrue);
    });

    test('list with roman numbering is ordered', () async {
      final body = [
        wP(
          numId: '1',
          ilvl: 0,
          innerXml: wR(text: 'A'),
        ),
        wP(
          numId: '1',
          ilvl: 0,
          innerXml: wR(text: 'B'),
        ),
      ].join();
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        numberingXml: numberingXml(
          numId: '1',
          numFmt: 'lowerRoman',
          start: null,
        ),
      );
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          orderedListNumbering: OrderedListNumbering.keep,
        ),
      ).convert();
      expect(markdown.trim(), '1. A\n2. B');
    });

    test('ordered list preserves source number format in the IR', () async {
      final body = wP(
        numId: '1',
        ilvl: 0,
        innerXml: wR(text: 'A'),
      );
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        numberingXml: numberingXml(
          numId: '1',
          numFmt: 'upperRoman',
          start: null,
        ),
      );
      final doc = await parseDocument(bytes);
      final list = doc.blocks.first as ListBlock;
      expect(list.numberFormat, ListNumberFormat.upperRoman);
    });

    test('preserveFormat renders upper roman markers with wide gap', () async {
      final body = [
        wP(
          numId: '1',
          ilvl: 0,
          innerXml: wR(text: 'A'),
        ),
        wP(
          numId: '1',
          ilvl: 0,
          innerXml: wR(text: 'B'),
        ),
      ].join();
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        numberingXml: numberingXml(
          numId: '1',
          numFmt: 'upperRoman',
          start: null,
        ),
      );
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          orderedListMarker: OrderedListMarker.preserveFormat,
          orderedListNumbering: OrderedListNumbering.keep,
        ),
      ).convert();
      // 'I.' is a single capital marker -> two spaces; 'II.' -> one space.
      expect(markdown.trim(), 'I.  A\nII. B');
    });

    test('preserveFormat renders lower alpha markers', () async {
      final body = [
        wP(
          numId: '1',
          ilvl: 0,
          innerXml: wR(text: 'A'),
        ),
        wP(
          numId: '1',
          ilvl: 0,
          innerXml: wR(text: 'B'),
        ),
      ].join();
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        numberingXml: numberingXml(
          numId: '1',
          numFmt: 'lowerLetter',
          start: null,
        ),
      );
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          orderedListMarker: OrderedListMarker.preserveFormat,
          orderedListNumbering: OrderedListNumbering.keep,
        ),
      ).convert();
      expect(markdown.trim(), 'a. A\nb. B');
    });

    test('default marker stays decimal for an upper roman source', () async {
      final body = [
        wP(
          numId: '1',
          ilvl: 0,
          innerXml: wR(text: 'A'),
        ),
        wP(
          numId: '1',
          ilvl: 0,
          innerXml: wR(text: 'B'),
        ),
      ].join();
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        numberingXml: numberingXml(
          numId: '1',
          numFmt: 'upperRoman',
          start: null,
        ),
      );
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          orderedListNumbering: OrderedListNumbering.keep,
        ),
      ).convert();
      expect(markdown.trim(), '1. A\n2. B');
    });

    test('tableMode htmlOnly renders HTML even for simple tables', () async {
      final table = '''<w:tbl>
  <w:tr>
    <w:tc><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc>
  </w:tr>
</w:tbl>''';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(table));
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(tableMode: TableMode.htmlOnly),
      ).convert();
      expect(markdown.trim().startsWith('<table>'), isTrue);
    });

    test('table alignments reflect jc in first row', () async {
      final table = '''<w:tbl>
  <w:tr>
    <w:tc>
      <w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:t>A</w:t></w:r></w:p>
    </w:tc>
    <w:tc>
      <w:p><w:pPr><w:jc w:val="right"/></w:pPr><w:r><w:t>B</w:t></w:r></w:p>
    </w:tc>
  </w:tr>
  <w:tr>
    <w:tc><w:p><w:r><w:t>1</w:t></w:r></w:p></w:tc>
    <w:tc><w:p><w:r><w:t>2</w:t></w:r></w:p></w:tc>
  </w:tr>
</w:tbl>''';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(table));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.contains('|:---:|---:|'), isTrue);
    });

    test('ignores comments when includeComments is false', () async {
      final body =
          '<w:commentRangeStart w:id="1"/>'
          '${wR(text: "Text")}'
          '<w:commentRangeEnd w:id="1"/>';
      final comments =
          '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:comments xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:comment w:id="1" w:author="Alice">
    <w:p><w:r><w:t>Note</w:t></w:r></w:p>
  </w:comment>
</w:comments>''';
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(innerXml: body)),
        commentsXml: comments,
      );
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.contains('^[Alice'), isFalse);
    });

    test('ignores footnotes when includeFootnotes is false', () async {
      final body = wP(
        innerXml:
            '${wR(text: "Note")}\n<w:r><w:footnoteReference w:id="1"/></w:r>',
      );
      final footnotes =
          '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:footnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:footnote w:id="1">
    <w:p><w:r><w:t>Footnote text</w:t></w:r></w:p>
  </w:footnote>
</w:footnotes>''';
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        footnotesXml: footnotes,
      );
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(includeFootnotes: false),
      ).convert();
      expect(markdown.contains('[^1]'), isFalse);
    });

    test('ignores endnotes when includeEndnotes is false', () async {
      final body = wP(
        innerXml:
            '${wR(text: "End")}\n<w:r><w:endnoteReference w:id="2"/></w:r>',
      );
      final endnotes =
          '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:endnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:endnote w:id="2">
    <w:p><w:r><w:t>Endnote text</w:t></w:r></w:p>
  </w:endnote>
</w:endnotes>''';
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        endnotesXml: endnotes,
      );
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.contains('endnote:2'), isFalse);
    });

    test(
      'treatShadedRunsAsCode=false disables inline code detection',
      () async {
        final body =
            '<w:p><w:r><w:rPr><w:shd/></w:rPr><w:t>Shade</w:t></w:r></w:p>';
        final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
        final markdown = await DocxConverter(
          bytes,
          config: DocxToMarkdownConfig(treatShadedRunsAsCode: false),
        ).convert();
        expect(markdown.trim(), 'Shade');
      },
    );

    test('horizontal rule detected by paragraph border', () async {
      final body = wP(horizontalRule: true);
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '---');
    });

    test('track changes deletion produces warning', () async {
      final body = '<w:p><w:del><w:r><w:t>Removed</w:t></w:r></w:del></w:p>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final doc = await parseDocument(bytes);
      expect(
        doc.warnings.any((w) => w.code == 'trackChanges.deletionDropped'),
        isTrue,
      );
    });

    test('showDeletionsAsStrikethrough renders deleted text struck', () async {
      final body =
          '<w:p><w:del><w:r><w:delText>Removed</w:delText></w:r></w:del></w:p>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          trackChangesMode: TrackChangesMode.showDeletionsAsStrikethrough,
        ),
      ).convert();
      expect(markdown.trim(), '~~Removed~~');
    });

    test('rejectChanges restores deleted text as plain text', () async {
      final body =
          '<w:p><w:del><w:r><w:delText>Removed</w:delText></w:r></w:del></w:p>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          trackChangesMode: TrackChangesMode.rejectChanges,
        ),
      ).convert();
      expect(markdown.trim(), 'Removed');
    });

    test('rejectChanges drops inserted text', () async {
      final body = '<w:p><w:ins><w:r><w:t>Added</w:t></w:r></w:ins></w:p>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          trackChangesMode: TrackChangesMode.rejectChanges,
        ),
      ).convert();
      expect(markdown.trim(), '');
    });

    test('acceptAll keeps inserted text', () async {
      final body = '<w:p><w:ins><w:r><w:t>Added</w:t></w:r></w:ins></w:p>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), 'Added');
    });

    test('preserveEmptyParagraphs keeps empty paragraph', () async {
      final body = wP(innerXml: '');
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final doc = await parseDocument(
        bytes,
        config: DocxToMarkdownConfig(preserveEmptyParagraphs: true),
      );
      expect(doc.blocks.length, 1);
      expect(doc.blocks.first is ParagraphBlock, isTrue);
    });

    test('shaded run triggers inline code when enabled', () async {
      final body =
          '<w:p><w:r><w:rPr><w:shd/></w:rPr><w:t>Shade</w:t></w:r></w:p>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '`Shade`');
    });

    test('inline formatting combos', () async {
      final run = wR(
        innerXml: wT('Text'),
        rPrXml:
            '<w:b/><w:i/><w:u/><w:strike/><w:vertAlign w:val="superscript"/>',
      );
      final body = wP(innerXml: run);
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '<sup>***~~<u>Text</u>~~***</sup>');
    });

    test('run formatting respects off values', () async {
      final run = wR(
        innerXml: wT('Text'),
        rPrXml:
            '<w:b w:val="0"/><w:i w:val="false"/><w:u w:val="none"/><w:strike w:val="off"/>',
      );
      final body = wP(innerXml: run);
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), 'Text');
    });

    test('complex script bold and italic are treated as formatting', () async {
      final run = wR(innerXml: wT('Text'), rPrXml: '<w:bCs/><w:iCs/>');
      final body = wP(innerXml: run);
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '***Text***');
    });

    test('horizontal rule detected by --- text', () async {
      final body = wP(text: '---');
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '---');
    });

    test('bookmarkStart inserts anchor', () async {
      final body =
          '<w:p><w:bookmarkStart w:name="Anchor"/>'
          '<w:r><w:t>Text</w:t></w:r></w:p>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.contains('<a id="Anchor"></a>'), isTrue);
    });

    test('code run detected by monospace font', () async {
      final body =
          '<w:p><w:r><w:rPr><w:rFonts w:ascii="Consolas"/></w:rPr><w:t>Code</w:t></w:r></w:p>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '`Code`');
    });

    test('inline math renders as dollar-latex', () async {
      final body =
          '<w:p><m:oMath xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math">'
          '<m:t>x</m:t></m:oMath></w:p>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.contains('\$x\$'), isTrue);
    });

    test('inline math renders OMML superscript fallback', () async {
      final body =
          '<w:p><m:oMath xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math">'
          '<m:sSup>'
          '<m:e><m:r><m:t>x</m:t></m:r></m:e>'
          '<m:sup><m:r><m:t>2</m:t></m:r></m:sup>'
          '</m:sSup>'
          '</m:oMath></w:p>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.contains(r'$x^{2}$'), isTrue);
    });

    test('inline math renders n-ary summation with limits', () async {
      final body =
          '<w:p><m:oMath xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math">'
          '<m:nary>'
          '<m:naryPr><m:chr m:val="∑"/></m:naryPr>'
          '<m:sub><m:r><m:t>i=0</m:t></m:r></m:sub>'
          '<m:sup><m:r><m:t>n</m:t></m:r></m:sup>'
          '<m:e><m:r><m:t>x</m:t></m:r></m:e>'
          '</m:nary>'
          '</m:oMath></w:p>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.contains(r'$\sum_{i=0}^{n}{x}$'), isTrue);
    });

    test('inline math renders delimiters', () async {
      final body =
          '<w:p><m:oMath xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math">'
          '<m:d><m:e><m:r><m:t>x</m:t></m:r></m:e></m:d>'
          '</m:oMath></w:p>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.contains(r'\left( x \right)'), isTrue);
    });

    test('inline math renders matrices', () async {
      final body =
          '<w:p><m:oMath xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math">'
          '<m:m>'
          '<m:mr><m:e><m:r><m:t>a</m:t></m:r></m:e>'
          '<m:e><m:r><m:t>b</m:t></m:r></m:e></m:mr>'
          '<m:mr><m:e><m:r><m:t>c</m:t></m:r></m:e>'
          '<m:e><m:r><m:t>d</m:t></m:r></m:e></m:mr>'
          '</m:m>'
          '</m:oMath></w:p>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(
        markdown.contains(r'\begin{matrix}a & b \\ c & d\end{matrix}'),
        isTrue,
      );
    });

    test('inline math renders accents with default hat', () async {
      final body =
          '<w:p><m:oMath xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math">'
          '<m:acc><m:e><m:r><m:t>x</m:t></m:r></m:e></m:acc>'
          '</m:oMath></w:p>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.contains(r'\hat{x}'), isTrue);
    });

    test('ommlToLatex hook overrides math conversion', () async {
      HookContext? seenContext;
      final body =
          '<m:oMath xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math">'
          '<m:t>x</m:t></m:oMath>';
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(body));
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          hooks: DocxToMarkdownHooks(
            ommlToLatex: (xml, [ctx]) {
              seenContext = ctx;
              return 'Y';
            },
          ),
        ),
      ).convert();
      expect(markdown.contains('\$\$'), isTrue);
      expect(markdown.contains('Y'), isTrue);
      expect(seenContext?.part, 'word/document.xml');
      expect(seenContext?.path, contains('document.xml:body'));
    });

    test('includes headers and footers when enabled', () async {
      final body = '''${wP(text: 'Body')}
<w:sectPr>
  <w:headerReference r:id="rId10"/>
  <w:footerReference r:id="rId11"/>
</w:sectPr>''';
      final headerXml =
          '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  ${wP(text: 'Header')}
</w:hdr>''';
      final footerXml =
          '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  ${wP(text: 'Footer')}
</w:ftr>''';
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(body),
        documentRels: const [
          DocxRel(
            id: 'rId10',
            type: DocxRelTypes.header,
            target: 'header1.xml',
          ),
          DocxRel(
            id: 'rId11',
            type: DocxRelTypes.footer,
            target: 'footer1.xml',
          ),
        ],
        extraXmlParts: {
          'word/header1.xml': headerXml,
          'word/footer1.xml': footerXml,
        },
      );

      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(includeHeadersFooters: true),
      ).convert();
      expect(markdown.contains('Header'), isTrue);
      expect(markdown.contains('Footer'), isTrue);
      expect(markdown.contains('---'), isTrue);
    });

    test('strict mode throws on missing body', () async {
      final xml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"></w:document>''';
      final bytes = buildDocxBytes(documentXml: xml);
      final converter = DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(strict: true),
      );
      expect(converter.convert(), throwsA(isA<DocxPackageException>()));
    });

    test('strict mode throws on missing document.xml', () async {
      final bytes = buildDocxBytes(includeDocumentXml: false);
      final converter = DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(strict: true),
      );
      expect(converter.convert(), throwsA(isA<DocxPackageException>()));
    });

    test('hooks can transform inlines', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Hello')),
      );
      final config = DocxToMarkdownConfig(
        hooks: DocxToMarkdownHooks(
          transformInline: (inlineNode, _) {
            if (inlineNode is TextInline) {
              return const TextInline('X');
            }
            return inlineNode;
          },
        ),
      );
      final markdown = await DocxConverter(bytes, config: config).convert();
      expect(markdown.trim(), 'X');
    });

    test('onWarning hook is invoked', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody('<w:customUnknown>Inner</w:customUnknown>'),
      );
      var warned = false;
      final config = DocxToMarkdownConfig(
        hooks: DocxToMarkdownHooks(
          onWarning: (_, _) {
            warned = true;
          },
        ),
      );
      await DocxConverter(bytes, config: config).convert();
      expect(warned, isTrue);
    });
  });

  group('Parser warnings', () {
    test('unknown elements produce warnings', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody('<w:customUnknown>Inner</w:customUnknown>'),
      );
      final doc = await parseDocument(bytes);
      expect(doc.warnings, isNotEmpty);
      expect(doc.warnings.first.code, 'unsupported.block');
    });
  });
}
