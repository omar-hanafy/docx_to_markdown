import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

class DocxRel {
  const DocxRel({
    required this.id,
    required this.type,
    required this.target,
    this.external = false,
  });

  final String id;
  final String type;
  final String target;
  final bool external;
}

class DocxRelTypes {
  static const officeDocument =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument';
  static const styles =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles';
  static const numbering =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering';
  static const comments =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments';
  static const footnotes =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes';
  static const endnotes =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships/endnotes';
  static const header =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships/header';
  static const footer =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer';
  static const image =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships/image';
  static const hyperlink =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink';
}

Uint8List buildDocxBytes({
  String? documentXml,
  bool includeDocumentXml = true,
  String documentPath = 'word/document.xml',
  List<DocxRel> packageRels = const [],
  List<DocxRel> documentRels = const [],
  String? stylesXml,
  String? numberingXml,
  String? footnotesXml,
  String? endnotesXml,
  String? commentsXml,
  Map<String, Uint8List> media = const {},
  Map<String, String> extraXmlParts = const {},
}) {
  final files = <String, Uint8List>{};

  if (includeDocumentXml) {
    files[documentPath] = Uint8List.fromList(
      utf8.encode(documentXml ?? docXmlWithBody('')),
    );
  }

  if (stylesXml != null) {
    files['word/styles.xml'] = Uint8List.fromList(utf8.encode(stylesXml));
  }
  if (numberingXml != null) {
    files['word/numbering.xml'] = Uint8List.fromList(utf8.encode(numberingXml));
  }
  if (footnotesXml != null) {
    files['word/footnotes.xml'] = Uint8List.fromList(utf8.encode(footnotesXml));
  }
  if (endnotesXml != null) {
    files['word/endnotes.xml'] = Uint8List.fromList(utf8.encode(endnotesXml));
  }
  if (commentsXml != null) {
    files['word/comments.xml'] = Uint8List.fromList(utf8.encode(commentsXml));
  }

  for (final entry in extraXmlParts.entries) {
    files[entry.key] = Uint8List.fromList(utf8.encode(entry.value));
  }

  if (packageRels.isNotEmpty) {
    files['_rels/.rels'] = Uint8List.fromList(
      utf8.encode(relsXml(packageRels)),
    );
  } else {
    files['_rels/.rels'] = Uint8List.fromList(utf8.encode(relsXml(const [])));
  }

  if (documentRels.isNotEmpty) {
    final relsPath = _relsPathForPart(documentPath);
    files[relsPath] = Uint8List.fromList(utf8.encode(relsXml(documentRels)));
  }

  for (final entry in media.entries) {
    files[entry.key] = entry.value;
  }

  files['[Content_Types].xml'] = Uint8List.fromList(
    utf8.encode(
      contentTypesXml(files.keys.toList(), mainDocumentPath: documentPath),
    ),
  );

  return _buildZip(files);
}

String relsXml(List<DocxRel> rels) {
  final buffer = StringBuffer();
  buffer.writeln('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>');
  buffer.writeln(
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
  );
  for (final rel in rels) {
    final mode = rel.external ? ' TargetMode="External"' : '';
    buffer.writeln(
      '<Relationship Id="${rel.id}" Type="${rel.type}" Target="${rel.target}"$mode/>',
    );
  }
  buffer.writeln('</Relationships>');
  return buffer.toString();
}

String contentTypesXml(
  List<String> partNames, {
  String mainDocumentPath = 'word/document.xml',
}) {
  final parts = partNames.toSet();

  String override(String part, String type) {
    if (!parts.contains(part)) return '';
    return '<Override PartName="/$part" ContentType="$type"/>';
  }

  final buffer = StringBuffer();
  buffer.writeln('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>');
  buffer.writeln(
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
  );
  buffer.writeln(
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
  );
  buffer.writeln('<Default Extension="xml" ContentType="application/xml"/>');
  buffer.writeln(
    override(
      mainDocumentPath,
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml',
    ),
  );
  buffer.writeln(
    override(
      'word/styles.xml',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml',
    ),
  );
  buffer.writeln(
    override(
      'word/numbering.xml',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml',
    ),
  );
  buffer.writeln(
    override(
      'word/footnotes.xml',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml',
    ),
  );
  buffer.writeln(
    override(
      'word/endnotes.xml',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.endnotes+xml',
    ),
  );
  buffer.writeln(
    override(
      'word/comments.xml',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml',
    ),
  );
  buffer.writeln('</Types>');
  return buffer.toString();
}

String docXmlWithBody(String bodyInner) {
  return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document
  xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
  xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
  xmlns:v="urn:schemas-microsoft-com:vml"
  xmlns:o="urn:schemas-microsoft-com:office:office"
  xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math">
  <w:body>
    $bodyInner
    <w:sectPr/>
  </w:body>
</w:document>''';
}

String wDrawingTextBox(List<String> paragraphTexts) {
  final paras = paragraphTexts.map((t) => '<w:p>${wR(text: t)}</w:p>').join();
  return '''<w:drawing>
  <w:txbxContent>
    $paras
  </w:txbxContent>
</w:drawing>''';
}

String vmlImage(String rid) {
  return '''<w:pict>
  <v:shape>
    <v:imagedata r:id="$rid"/>
  </v:shape>
</w:pict>''';
}

String wP({
  String? text,
  String? innerXml,
  String? styleId,
  String? numId,
  int? ilvl,
  bool horizontalRule = false,
}) {
  final pPr = StringBuffer();
  if (styleId != null) {
    pPr.write('<w:pStyle w:val="$styleId"/>');
  }
  if (numId != null) {
    final lvl = ilvl ?? 0;
    pPr.write(
      '<w:numPr><w:ilvl w:val="$lvl"/><w:numId w:val="$numId"/></w:numPr>',
    );
  }
  if (horizontalRule) {
    pPr.write(
      '<w:pBdr><w:bottom w:val="single" w:sz="4" w:space="1" w:color="auto"/></w:pBdr>',
    );
  }
  final pPrXml = pPr.isEmpty ? '' : '<w:pPr>${pPr.toString()}</w:pPr>';

  final content = innerXml ?? (text == null ? '' : wR(text: text));
  return '<w:p>$pPrXml$content</w:p>';
}

String wR({String? text, String? innerXml, String? rPrXml}) {
  final rPr = rPrXml == null ? '' : '<w:rPr>$rPrXml</w:rPr>';
  final content =
      innerXml ?? (text == null ? '' : '<w:t>${_escapeXml(text)}</w:t>');
  return '<w:r>$rPr$content</w:r>';
}

String wT(String text) => '<w:t>${_escapeXml(text)}</w:t>';

String wBr() => '<w:br/>';

String wHyperlink({required String rid, required String innerXml}) {
  return '<w:hyperlink r:id="$rid">$innerXml</w:hyperlink>';
}

String wFldSimple({required String instr, required String innerXml}) {
  final escaped = _escapeXml(instr);
  return '<w:fldSimple w:instr="$escaped">$innerXml</w:fldSimple>';
}

String wDrawingImage({
  required String embedId,
  String? descr,
  String? title,
  int? extentCx,
  int? extentCy,
}) {
  final d = descr ?? 'Image';
  final titleAttr = title == null ? '' : ' title="$title"';
  final extent = extentCx == null || extentCy == null
      ? ''
      : '<wp:extent cx="$extentCx" cy="$extentCy"/>';
  return '''<w:drawing>
  <wp:inline>
    $extent
    <wp:docPr id="1" name="Picture" descr="$d"$titleAttr/>
    <a:graphic>
      <a:graphicData>
        <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
          <pic:blipFill>
            <a:blip r:embed="$embedId"/>
          </pic:blipFill>
        </pic:pic>
      </a:graphicData>
    </a:graphic>
  </wp:inline>
</w:drawing>''';
}

String numberingXml({
  String numId = '1',
  String abstractNumId = '1',
  String numFmt = 'decimal',
  int? start = 1,
  bool includeLevel1 = false,
  String level1Fmt = 'bullet',
  int? startOverride,
}) {
  final startTag = start == null ? '' : '<w:start w:val="$start"/>';
  final lvl1 = includeLevel1
      ? '<w:lvl w:ilvl="1"><w:numFmt w:val="$level1Fmt"/></w:lvl>'
      : '';
  final override = startOverride == null
      ? ''
      : '<w:lvlOverride w:ilvl="0"><w:startOverride w:val="$startOverride"/></w:lvlOverride>';
  return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:abstractNum w:abstractNumId="$abstractNumId">
    <w:lvl w:ilvl="0">
      $startTag
      <w:numFmt w:val="$numFmt"/>
    </w:lvl>
    $lvl1
  </w:abstractNum>
  <w:num w:numId="$numId">
    <w:abstractNumId w:val="$abstractNumId"/>
    $override
  </w:num>
</w:numbering>''';
}

String stylesXml({
  String? styleId,
  String? styleName,
  int? outlineLevel,
  bool codeStyle = false,
  bool quoteStyle = false,
}) {
  final id = styleId ?? 'Normal';
  final name = styleName ?? 'Normal';
  final outline = outlineLevel == null
      ? ''
      : '<w:pPr><w:outlineLvl w:val="$outlineLevel"/></w:pPr>';
  final nameXml = '<w:name w:val="$name"/>';
  final rPr = codeStyle
      ? '<w:rPr><w:rFonts w:ascii="Consolas"/><w:shd/></w:rPr>'
      : '';
  final quoteName = quoteStyle ? '<w:name w:val="Intense Quote"/>' : nameXml;
  return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:styleId="$id">
    $quoteName
    $outline
    $rPr
  </w:style>
</w:styles>''';
}

Uint8List _buildZip(Map<String, Uint8List> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  final encoder = ZipEncoder();
  final bytes = encoder.encode(archive);
  return Uint8List.fromList(bytes);
}

String _relsPathForPart(String partPath) {
  final normalized = partPath.replaceAll('\\', '/');
  final parts = normalized.split('/');
  if (parts.length == 1) {
    return '_rels/$normalized.rels';
  }
  final fileName = parts.removeLast();
  final baseDir = parts.join('/');
  return '$baseDir/_rels/$fileName.rels';
}

String _escapeXml(String input) {
  return input
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
