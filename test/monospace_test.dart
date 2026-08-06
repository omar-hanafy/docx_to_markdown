import 'package:docx_to_markdown/docx_to_markdown.dart';
import 'package:test/test.dart';

import 'utils/docx_fixture.dart';

/// Converts a one-run document whose font is attached with a direct
/// `w:rFonts` on the run.
Future<String> _viaDirectFont(String font, [DocxToMarkdownConfig? cfg]) async {
  final body =
      '<w:p><w:r><w:rPr><w:rFonts w:ascii="$font" w:hAnsi="$font"/></w:rPr>'
      '<w:t>Code</w:t></w:r></w:p>';
  final md = await DocxConverter(
    buildDocxBytes(documentXml: docXmlWithBody(body)),
    config: cfg,
  ).convert();
  return md.trim();
}

/// Converts a one-run document whose font is carried by a character style.
Future<String> _viaCharacterStyle(
  String font, [
  DocxToMarkdownConfig? cfg,
]) async {
  final stylesXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:style w:type="character" w:styleId="Verbatim">'
      '<w:name w:val="Verbatim Char"/>'
      '<w:rPr><w:rFonts w:ascii="$font" w:hAnsi="$font"/></w:rPr>'
      '</w:style></w:styles>';
  const body =
      '<w:p><w:r><w:rPr><w:rStyle w:val="Verbatim"/></w:rPr>'
      '<w:t>Code</w:t></w:r></w:p>';
  final md = await DocxConverter(
    buildDocxBytes(documentXml: docXmlWithBody(body), stylesXml: stylesXml),
    config: cfg,
  ).convert();
  return md.trim();
}

void main() {
  group('MonospaceFontMatcher', () {
    final m = MonospaceFontMatcher.defaults;

    test('matches modern monospace families', () {
      for (final font in [
        'Consolas',
        'Courier New',
        'Liberation Mono',
        'DejaVu Sans Mono',
        'JetBrains Mono',
        'Fira Code',
        'Fira Mono',
        'Source Code Pro',
        'IBM Plex Mono',
        'Cascadia Code',
        'Cascadia Mono',
        'SF Mono',
        'SFMono-Regular',
        'Roboto Mono',
        'Ubuntu Mono',
        'Inconsolata',
        'Hack',
        'Iosevka',
        'PT Mono',
        'Noto Sans Mono',
        'Anonymous Pro',
        'Space Mono',
        'Nimbus Mono PS',
        'JetBrainsMono-Regular',
        'IBMPlexMono',
        'Menlo',
        'Monaco',
      ]) {
        expect(m.matches(font), isTrue, reason: '"$font" should be monospace');
      }
    });

    test('does not match families that merely contain the letters mono', () {
      // Whole-word matching is what separates the family token "Mono" from
      // the Monotype foundry prefix. A deny-list would be a second list to
      // keep in sync.
      for (final font in [
        'Monotype Corsiva',
        'Monotype Sorts',
        'Monoline Script MT',
        'Mongolian Baiti',
        'Montserrat',
        'Times New Roman',
        'Calibri',
        'MS Gothic',
        'NSimSun',
      ]) {
        expect(m.matches(font), isFalse, reason: '"$font" is not monospace');
      }
    });

    test('an empty list disables font matching entirely', () {
      expect(MonospaceFontMatcher(const []).matches('Consolas'), isFalse);
    });
  });

  group('Run-level and style-level detection agree', () {
    // The defect this suite exists for: the two paths held separate font
    // lists, so "Liberation Mono" was code through a character style and
    // plain text through a direct w:rFonts. The parity assertion only holds
    // because both now resolve through one MonospaceFontMatcher.
    const corpus = [
      'Consolas',
      'Courier New',
      'Liberation Mono',
      'DejaVu Sans Mono',
      'JetBrains Mono',
      'Fira Code',
      'Inconsolata',
      'Ubuntu Mono',
      'SF Mono',
      'Roboto Mono',
      'IBM Plex Mono',
      'Cascadia Code',
      'Menlo',
      'Monotype Corsiva',
      'Calibri',
      'Times New Roman',
    ];

    for (final font in corpus) {
      test('"$font" resolves the same either way', () async {
        expect(
          await _viaDirectFont(font),
          await _viaCharacterStyle(font),
          reason: 'run-level and style-level disagree on "$font"',
        );
      });
    }

    test('narrowing the list narrows both paths', () async {
      final cfg = DocxToMarkdownConfig(monospaceFonts: const ['courier']);
      expect(await _viaDirectFont('Courier New', cfg), '`Code`');
      expect(await _viaCharacterStyle('Courier New', cfg), '`Code`');
      expect(await _viaDirectFont('Consolas', cfg), 'Code');
      expect(await _viaCharacterStyle('Consolas', cfg), 'Code');
    });

    test('an empty list disables both paths', () async {
      final cfg = DocxToMarkdownConfig(monospaceFonts: const []);
      expect(await _viaDirectFont('Consolas', cfg), 'Code');
      expect(await _viaCharacterStyle('Consolas', cfg), 'Code');
    });
  });

  group('Only the Latin font slots decide code', () {
    Future<String> convert(String rFonts) async {
      final body =
          '<w:p><w:r><w:rPr>$rFonts</w:rPr><w:t>Text</w:t></w:r></w:p>';
      final md = await DocxConverter(
        buildDocxBytes(documentXml: docXmlWithBody(body)),
      ).convert();
      return md.trim();
    }

    test('a complex-script font alone is not code', () async {
      // A Calibri paragraph whose Arabic fallback happens to be monospace is
      // not code; w:cs selects the face for a different Unicode range.
      expect(
        await convert(
          '<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Courier New"/>',
        ),
        'Text',
      );
    });

    test('an east-Asian font alone is not code', () async {
      // MS Gothic is a fixed-pitch CJK *body* face.
      expect(
        await convert(
          '<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="MS Gothic"/>',
        ),
        'Text',
      );
    });

    test('a Latin mono font with a non-mono complex script is code', () async {
      expect(
        await convert(
          '<w:rFonts w:ascii="Liberation Mono" w:hAnsi="Liberation Mono" '
          'w:eastAsia="Liberation Mono" w:cs="Noto Sans Arabic"/>',
        ),
        '`Text`',
      );
    });
  });

  group('A monospace body font carries no contrast', () {
    const monoNormal =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">'
        '<w:name w:val="Normal"/>'
        '<w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/></w:rPr>'
        '</w:style></w:styles>';

    Future<String> convert(String body) async {
      final md = await DocxConverter(
        buildDocxBytes(
          documentXml: docXmlWithBody(body),
          stylesXml: monoNormal,
        ),
      ).convert();
      return md.trim();
    }

    test('body text in the default mono font is not code', () async {
      expect(
        await convert(
          '<w:p><w:pPr><w:pStyle w:val="Normal"/></w:pPr>'
          '<w:r><w:t>Ordinary body sentence.</w:t></w:r></w:p>',
        ),
        'Ordinary body sentence.',
      );
    });

    test('a different mono font still contrasts and is code', () async {
      expect(
        await convert(
          '<w:p><w:pPr><w:pStyle w:val="Normal"/></w:pPr>'
          '<w:r><w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/>'
          '</w:rPr><w:t>getUser()</w:t></w:r></w:p>',
        ),
        '`getUser()`',
      );
    });

    test('shading still marks code in a mono-bodied document', () async {
      expect(
        await convert(
          '<w:p><w:pPr><w:pStyle w:val="Normal"/></w:pPr>'
          '<w:r><w:rPr><w:shd w:val="clear" w:fill="EEEEEE"/></w:rPr>'
          '<w:t>shaded</w:t></w:r></w:p>',
        ),
        '`shaded`',
      );
    });
  });
}
