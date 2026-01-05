import 'package:docx_to_markdown/src/styles.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

void main() {
  group('StyleRegistry', () {
    XmlDocument makeStyles() {
      final xml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:styleId="Heading1">
    <w:name w:val="Heading 1"/>
    <w:pPr><w:outlineLvl w:val="0"/></w:pPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="CodeStyle">
    <w:name w:val="Code"/>
    <w:rPr><w:rFonts w:ascii="Consolas"/><w:shd/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="QuoteStyle">
    <w:name w:val="Intense Quote"/>
  </w:style>
  <w:style w:type="paragraph" w:styleId="ListBase">
    <w:name w:val="List Base"/>
    <w:pPr>
      <w:numPr>
        <w:numId w:val="5"/>
        <w:ilvl w:val="1"/>
      </w:numPr>
    </w:pPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="ListChild">
    <w:name w:val="List Child"/>
    <w:basedOn w:val="ListBase"/>
  </w:style>
</w:styles>''';
      return XmlDocument.parse(xml);
    }

    test('analyzes heading, code, and quote styles', () {
      final reg = StyleRegistry();
      reg.load(makeStyles());

      final heading = reg.analyzeParagraphStyle('Heading1');
      expect(heading.isHeading, isTrue);
      expect(heading.headingLevel, 1);

      final code = reg.analyzeParagraphStyle('CodeStyle');
      expect(code.isCodeBlock, isTrue);

      final quote = reg.analyzeParagraphStyle('QuoteStyle');
      expect(quote.isQuote, isTrue);
    });

    test('resolves numbering via basedOn chain', () {
      final reg = StyleRegistry();
      reg.load(makeStyles());
      final numbering = reg.resolveNumberingForStyle('ListChild');
      expect(numbering?.numId, '5');
      expect(numbering?.ilvl, 1);
    });

    test('resolves styleId by visible name', () {
      final reg = StyleRegistry();
      reg.load(makeStyles());
      expect(reg.resolveStyleIdByName('Heading 1'), 'Heading1');
    });

    test('addCodeStyleName marks code style by name', () {
      final reg = StyleRegistry();
      final xml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:styleId="CustomCode">
    <w:name w:val="My Code"/>
  </w:style>
</w:styles>''';
      reg.load(XmlDocument.parse(xml));
      reg.addCodeStyleName('My Code');
      final analysis = reg.analyzeParagraphStyle('CustomCode');
      expect(analysis.isCodeBlock, isTrue);
    });

    test('addCodeStyleId marks code style by id', () {
      final reg = StyleRegistry();
      final xml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:styleId="MyCode"/>
</w:styles>''';
      reg.load(XmlDocument.parse(xml));
      reg.addCodeStyleId('MyCode');
      final analysis = reg.analyzeParagraphStyle('MyCode');
      expect(analysis.isCodeBlock, isTrue);
    });

    test('cycle in basedOn chain does not loop', () {
      final reg = StyleRegistry();
      final xml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:styleId="A">
    <w:basedOn w:val="B"/>
  </w:style>
  <w:style w:type="paragraph" w:styleId="B">
    <w:basedOn w:val="A"/>
  </w:style>
</w:styles>''';
      reg.load(XmlDocument.parse(xml));
      final analysis = reg.analyzeParagraphStyle('A');
      expect(analysis.isHeading, isFalse);
      expect(analysis.isCodeBlock, isFalse);
    });

    test('resolveStyleIdByName respects type filter', () {
      final reg = StyleRegistry();
      final xml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:styleId="ParaStyle">
    <w:name w:val="Shared"/>
  </w:style>
  <w:style w:type="character" w:styleId="CharStyle">
    <w:name w:val="Shared"/>
  </w:style>
</w:styles>''';
      reg.load(XmlDocument.parse(xml));
      expect(
        reg.resolveStyleIdByName('Shared', type: StyleType.character),
        'CharStyle',
      );
    });

    test('heading level inferred from styleId', () {
      final reg = StyleRegistry();
      final xml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:styleId="Heading3"/>
</w:styles>''';
      reg.load(XmlDocument.parse(xml));
      final analysis = reg.analyzeParagraphStyle('Heading3');
      expect(analysis.isHeading, isTrue);
      expect(analysis.headingLevel, 3);
    });

    test('title/subtitle fallback to heading levels', () {
      final reg = StyleRegistry();
      final xml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:styleId="Title">
    <w:name w:val="Title"/>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Subtitle">
    <w:name w:val="Subtitle"/>
  </w:style>
</w:styles>''';
      reg.load(XmlDocument.parse(xml));
      final title = reg.analyzeParagraphStyle('Title');
      final subtitle = reg.analyzeParagraphStyle('Subtitle');
      expect(title.isHeading, isTrue);
      expect(title.headingLevel, 1);
      expect(subtitle.isHeading, isTrue);
      expect(subtitle.headingLevel, 2);
    });

    test('monospace without shading implies code via heuristics', () {
      final reg = StyleRegistry();
      final xml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:styleId="MonoOnly">
    <w:rPr><w:rFonts w:ascii="Consolas"/></w:rPr>
  </w:style>
</w:styles>''';
      reg.load(XmlDocument.parse(xml));
      final analysis = reg.analyzeParagraphStyle('MonoOnly');
      expect(analysis.isCodeBlock, isTrue);
    });
  });
}
