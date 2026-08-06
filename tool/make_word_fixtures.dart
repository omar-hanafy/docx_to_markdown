// Regenerates the Word-realistic `.docx` golden fixtures.
//
// Usage:
//   dart run tool/make_word_fixtures.dart
//   dart run tool/update_goldens.dart      # then refresh the expected .md
//
// Unlike the Pandoc-generated fixtures that came before them, these carry the
// property elements Word actually writes - a populated `<w:tcPr>` on every
// cell, `<w:tblPr>`, `<w:trPr>` - which is what real documents look like and
// what the Pandoc-shaped fixtures never exercised.
//
// Only the cases listed in [_fixtures] are managed here. The other fixtures
// under test/docx_golden/ are Pandoc output and must not be regenerated.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

const _w =
    'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main";';

const _rels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''';

const _docRels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
</Relationships>''';

const _contentTypes = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
</Types>''';

/// Word-realistic styles: heading bold lives in the style's own `w:rPr`, never
/// on the run, and `ListBullet` carries its `w:numPr` in the style definition.
final String _styles =
    '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles ${_w.replaceAll(';', '')}>
<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Arial"/><w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults>
<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:qFormat/>
  <w:pPr><w:spacing w:after="300"/></w:pPr>
  <w:rPr><w:b/><w:sz w:val="60"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:qFormat/>
  <w:pPr><w:keepNext/><w:keepLines/><w:outlineLvl w:val="0"/></w:pPr>
  <w:rPr><w:b/><w:bCs/><w:sz w:val="36"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:qFormat/>
  <w:pPr><w:keepNext/><w:keepLines/><w:outlineLvl w:val="1"/></w:pPr>
  <w:rPr><w:b/><w:i/><w:sz w:val="26"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="ListBullet"><w:name w:val="List Bullet"/><w:basedOn w:val="Normal"/>
  <w:pPr><w:numPr><w:numId w:val="1"/></w:numPr><w:contextualSpacing/></w:pPr></w:style>
<w:style w:type="character" w:styleId="VerbatimChar"><w:name w:val="Verbatim Char"/>
  <w:rPr><w:rFonts w:ascii="Liberation Mono" w:hAnsi="Liberation Mono"/></w:rPr></w:style>
</w:styles>''';

final String _numbering =
    '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:numbering ${_w.replaceAll(';', '')}>
<w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>
  <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="&#xF0B7;"/>
    <w:lvlJc w:val="left"/><w:pPr><w:ind w:left="360" w:hanging="360"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="Symbol" w:hAnsi="Symbol" w:hint="default"/></w:rPr></w:lvl></w:abstractNum>
<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
</w:numbering>''';

String _document(String body) =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<w:document ${_w.replaceAll(';', '')}><w:body>$body'
    '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
    '<w:pgMar w:top="1417" w:right="1417" w:bottom="1417" w:left="1417"/>'
    '</w:sectPr></w:body></w:document>';

// --------------------------------------------------------------- builders ---

String _p(String? text, {String? style, String? runs, String pPrExtra = ''}) {
  var pPr = '';
  if (style != null || pPrExtra.isNotEmpty) {
    pPr =
        '<w:pPr>${style != null ? '<w:pStyle w:val="$style"/>' : ''}'
        '$pPrExtra</w:pPr>';
  }
  final inner = runs ?? (text != null ? _r(text) : '');
  return '<w:p>$pPr$inner</w:p>';
}

String _r(String text, [String rPr = '']) {
  final preserve = text != text.trim() ? ' xml:space="preserve"' : '';
  final props = rPr.isEmpty ? '' : '<w:rPr>$rPr</w:rPr>';
  return '<w:r>$props<w:t$preserve>$text</w:t></w:r>';
}

/// Word writes a full `<w:tcPr>` on every single cell. That realism is what
/// the Pandoc-generated fixtures lack entirely.
String _tc(
  String inner, {
  int w = 4675,
  String? shd,
  int? span,
  String? vAlign,
  bool borders = true,
}) {
  final b = StringBuffer('<w:tcW w:w="$w" w:type="dxa"/>');
  if (span != null) b.write('<w:gridSpan w:val="$span"/>');
  if (borders) {
    b.write(
      '<w:tcBorders>'
      '<w:top w:val="single" w:sz="4" w:space="0" w:color="CBD5E1"/>'
      '<w:left w:val="single" w:sz="4" w:space="0" w:color="CBD5E1"/>'
      '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="CBD5E1"/>'
      '<w:right w:val="single" w:sz="4" w:space="0" w:color="CBD5E1"/>'
      '</w:tcBorders>',
    );
  }
  if (shd != null) {
    b.write('<w:shd w:val="clear" w:color="auto" w:fill="$shd"/>');
  }
  b.write(
    '<w:tcMar><w:top w:w="85" w:type="dxa"/><w:start w:w="95" w:type="dxa"/>'
    '<w:bottom w:w="85" w:type="dxa"/><w:end w:w="95" w:type="dxa"/></w:tcMar>',
  );
  if (vAlign != null) b.write('<w:vAlign w:val="$vAlign"/>');
  return '<w:tc><w:tcPr>$b</w:tcPr>$inner</w:tc>';
}

String _tr(List<String> cells, {bool header = false, bool cantSplit = true}) {
  final props = StringBuffer();
  if (cantSplit) props.write('<w:cantSplit/>');
  if (header) props.write('<w:tblHeader w:val="true"/>');
  final trPr = props.isEmpty ? '' : '<w:trPr>$props</w:trPr>';
  return '<w:tr>$trPr${cells.join()}</w:tr>';
}

String _tbl(List<String> rows, int cols) {
  final grid = List.generate(
    cols,
    (_) => '<w:gridCol w:w="${9350 ~/ cols}"/>',
  ).join();
  return '<w:tbl><w:tblPr>'
      '<w:tblW w:w="0" w:type="auto"/>'
      '<w:jc w:val="center"/>'
      '<w:tblLayout w:type="fixed"/>'
      '<w:tblLook w:val="04A0" w:firstRow="1" w:lastRow="0" '
      'w:firstColumn="1" w:lastColumn="0" w:noHBand="0" w:noVBand="1"/>'
      '</w:tblPr>'
      '<w:tblGrid>$grid</w:tblGrid>'
      '${rows.join()}</w:tbl>';
}

const _bold = '<w:b/>';
const _mono = '<w:rFonts w:ascii="Liberation Mono" w:hAnsi="Liberation Mono"/>';

// --------------------------------------------------------------- fixtures ---

Map<String, String> _fixtures() {
  final out = <String, String>{};

  // Word-realistic tables: a full property element on every cell.
  out['word_table_cell_properties'] =
      _p('Word writes a full property element on every table cell.') +
      _tbl([
        _tr([
          _tc(
            _p(null, runs: _r('Field', _bold)),
            shd: '334155',
            vAlign: 'center',
          ),
          _tc(
            _p(null, runs: _r('Value', _bold)),
            shd: '334155',
            vAlign: 'center',
          ),
        ], header: true),
        _tr([_tc(_p('Status')), _tc(_p('Draft'))]),
        _tr([_tc(_p('Owner')), _tc(_p('Product'))]),
      ], 2) +
      _p('A second table with no header row falls back to HTML.') +
      _tbl([
        _tr([_tc(_p('Left'), shd: 'F1F5F9'), _tc(_p('Right'))]),
        _tr([_tc(_p('Bottom'), span: 2, w: 9350)]),
      ], 2);

  // Word constantly emits formatted runs whose text carries the trailing
  // space; emphasis delimiters must not end up adjacent to it.
  out['emphasis_whitespace'] =
      _p(
        null,
        runs: _r('1.  ', _bold) + _r('Ordered step written as literal text.'),
      ) +
      _p(
        null,
        runs: _r('Note: ', _bold) + _r('bold label with a trailing space.'),
      ) +
      _p(
        null,
        runs: _r('Leading') + _r(' emphasised', '<w:i/>') + _r(' tail.'),
      ) +
      _p(null, runs: _r('a') + _r('  spaced both sides  ', _bold) + _r('b')) +
      _p(
        null,
        runs: _r('Struck ') + _r('removed  ', '<w:strike/>') + _r('kept.'),
      ) +
      _p(
        null,
        runs: _r('Nested ') + _r(' inner  ', '<w:b/><w:i/>') + _r('done.'),
      ) +
      _p(
        null,
        runs: _r('Whitespace-only bold run:') + _r('   ', _bold) + _r('|end'),
      );

  // Bold and italic reach the runs only through the paragraph style's rPr.
  out['heading_style_bold'] =
      _p('Document Title', style: 'Title') +
      _p('Style-bold heading', style: 'Heading1') +
      _p('Body text under the heading.') +
      _p('Style-bold-italic heading', style: 'Heading2') +
      _p(
        null,
        style: 'Heading1',
        runs: _r('Explicitly ', _bold) + _r('bolded heading run'),
      ) +
      _p(null, runs: _r('Body ') + _r('bold', _bold) + _r(' stays bold.'));

  // The same font attached two ways, plus the mono families real exports use
  // and a "Monotype" name that must NOT match.
  const fonts = [
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
  ];
  final mono = StringBuffer(_p('Direct w:rFonts on the run:'));
  for (final f in fonts) {
    mono.write(
      _p(
        null,
        runs:
            _r('$f: ') +
            _r('value', '<w:rFonts w:ascii="$f" w:hAnsi="$f" w:cs="Arial"/>'),
      ),
    );
  }
  mono
    ..write(_p('Same font carried by a character style:'))
    ..write(_p(null, runs: _r('styled', '<w:rStyle w:val="VerbatimChar"/>')))
    ..write(_p('Complex-script slot only (should not be code):'))
    ..write(
      _p(
        null,
        runs: _r(
          'cs-only',
          '<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Liberation Mono"/>',
        ),
      ),
    );
  out['monospace_fonts'] = mono.toString();

  // The coloured-bar-as-horizontal-rule and callout-with-accent-stripe idioms.
  final decorative =
      _tbl([
        _tr([_tc('<w:p/>', w: 9350, shd: '2563EB', borders: false)]),
      ], 1) +
      _p('Body paragraph between the decorative rule and the callout.') +
      _tbl([
        _tr([
          _tc('<w:p/>', w: 100, shd: '2563EB', borders: false),
          _tc(
            _p(null, runs: _r('Core proposal', _bold)) +
                _p('Keep the project as the parent entity.'),
            w: 9250,
            shd: 'EFF6FF',
            borders: false,
          ),
        ]),
      ], 2) +
      _p('Trailing paragraph.');
  out['table_decorative_rule'] = decorative;
  // Same document, converted with preserveEmptyTables: true (see the sibling
  // .config.json) so the opt-out is pinned too.
  out['table_decorative_rule_preserved'] = decorative;

  // <w:br/> inside a cell and a single-column preformatted block.
  const jsonLines = [
    '{',
    '  "id": "positions",',
    '  "type": "repeatableGroup",',
    '  "maxItems": 5',
    '}',
  ];
  final codeRuns = StringBuffer();
  for (var i = 0; i < jsonLines.length; i++) {
    final esc = jsonLines[i]
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('"', '&quot;');
    final br = i < jsonLines.length - 1 ? '<w:br/>' : '';
    codeRuns.write(
      '<w:r><w:rPr>$_mono</w:rPr>'
      '<w:t xml:space="preserve">$esc</w:t>$br</w:r>',
    );
  }
  out['table_cell_breaks'] =
      _p('A single-column table used as a code block:') +
      _tbl([
        _tr([_tc('<w:p>$codeRuns</w:p>', w: 9350, shd: 'F1F5F9')]),
      ], 1) +
      _p('A cell holding a line break and two paragraphs:') +
      _tbl([
        _tr([
          _tc(
            _p(
                  null,
                  runs:
                      '${_r('First line')}<w:r><w:br/></w:r>'
                      '${_r('second line')}',
                ) +
                _p('A second paragraph in the same cell.'),
          ),
          _tc(_p('Plain neighbour.')),
        ]),
      ], 2);

  const rtl = '<w:rtl/>';
  out['rtl_arabic'] =
      _p('Mixed direction content follows.') +
      _p(null, runs: _r('المناصب المطلوبة', rtl), pPrExtra: '<w:bidi/>') +
      _p(
        null,
        runs: _r('English then ') + _r('عربي', rtl) + _r(' then English.'),
      ) +
      _p(null, runs: _r('منصب مطلوب', '$rtl$_bold'), pPrExtra: '<w:bidi/>') +
      _tbl([
        _tr([
          _tc(_p(null, runs: _r('English', _bold)), shd: '334155'),
          _tc(_p(null, runs: _r('العربية', '$rtl$_bold')), shd: '334155'),
        ], header: true),
        _tr([
          _tc(_p('Add another position')),
          _tc(_p(null, runs: _r('إضافة منصب آخر', rtl))),
        ]),
      ], 2);

  // numPr lives ONLY in the ListBullet style definition, never on a paragraph.
  out['list_bullet_style'] =
      _p('Bullets whose numbering comes from the paragraph style:') +
      _p('First style-driven bullet.', style: 'ListBullet') +
      _p('Second style-driven bullet.', style: 'ListBullet') +
      _p('Third style-driven bullet.', style: 'ListBullet') +
      _p('Closing paragraph.');

  return out;
}

void main() {
  final dir = p.join(Directory.current.path, 'test', 'docx_golden');
  _fixtures().forEach((name, body) {
    final files = <String, Uint8List>{
      '[Content_Types].xml': _bytes(_contentTypes),
      '_rels/.rels': _bytes(_rels),
      'word/_rels/document.xml.rels': _bytes(_docRels),
      'word/document.xml': _bytes(_document(body)),
      'word/styles.xml': _bytes(_styles),
      'word/numbering.xml': _bytes(_numbering),
    };
    final archive = Archive();
    files.forEach((path, data) {
      archive.addFile(ArchiveFile(path, data.length, data));
    });
    final out = File(p.join(dir, '$name.docx'));
    out.writeAsBytesSync(ZipEncoder().encode(archive));
    stdout.writeln('wrote ${p.relative(out.path)}');
  });
  stdout.writeln(
    '\nNow refresh the expected Markdown:\n'
    '  dart run tool/update_goldens.dart',
  );
}

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));
