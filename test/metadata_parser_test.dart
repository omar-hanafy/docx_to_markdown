import 'package:docx_to_markdown/src/ir.dart';
import 'package:docx_to_markdown/src/metadata_parser.dart';
import 'package:docx_to_markdown/src/ooxml_package.dart';
import 'package:test/test.dart';

import 'utils/docx_fixture.dart';

/// Wraps core-property [inner] XML in a `cp:coreProperties` root.
String core(String inner) =>
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<cp:coreProperties '
    'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/" '
    'xmlns:dcterms="http://purl.org/dc/terms/">'
    '$inner'
    '</cp:coreProperties>';

/// Wraps custom-property [inner] XML in a `Properties` root.
String custom(String inner) =>
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<Properties '
    'xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" '
    'xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">'
    '$inner'
    '</Properties>';

/// Builds a package from the given core/custom XML and parses its metadata.
DocumentMetadata parse(
  String? coreInner, {
  String? customInner,
  bool strict = false,
  List<DocWarning>? warnings,
}) {
  final bytes = buildDocxBytes(
    documentXml: docXmlWithBody(wP(text: 'Body')),
    coreXml: coreInner == null ? null : core(coreInner),
    customXml: customInner == null ? null : custom(customInner),
  );
  final pkg = DocxPackage.openBytes(bytes);
  try {
    return parseDocumentMetadata(pkg, strict: strict, onWarning: warnings?.add);
  } finally {
    pkg.close();
  }
}

void main() {
  group('parseDocumentMetadata core', () {
    test('parses the standard core properties', () {
      final m = parse(
        '<dc:title>My Title</dc:title>'
        '<dc:creator>Jane Doe</dc:creator>'
        '<dc:subject>The subject</dc:subject>'
        '<dc:description>A description</dc:description>'
        '<dc:language>en-US</dc:language>'
        '<cp:category>Reports</cp:category>'
        '<cp:keywords>alpha, beta</cp:keywords>'
        '<cp:lastModifiedBy>Bob</cp:lastModifiedBy>'
        '<cp:revision>3</cp:revision>'
        '<dcterms:created>2025-08-04T18:53:49Z</dcterms:created>'
        '<dcterms:modified>2025-08-05T09:00:00Z</dcterms:modified>',
      );
      expect(m.title, 'My Title');
      expect(m.creator, 'Jane Doe');
      expect(m.subject, 'The subject');
      expect(m.description, 'A description');
      expect(m.language, 'en-US');
      expect(m.category, 'Reports');
      expect(m.keywords, ['alpha', 'beta']);
      expect(m.lastModifiedBy, 'Bob');
      expect(m.revision, '3');
      expect(m.created, '2025-08-04T18:53:49Z');
      expect(m.modified, '2025-08-05T09:00:00Z');
    });

    test('empty core elements are treated as absent (null)', () {
      final m = parse(
        '<dc:title/>'
        '<dc:creator></dc:creator>'
        '<cp:keywords>   </cp:keywords>'
        '<dcterms:created>2025-08-04T18:53:49Z</dcterms:created>',
      );
      expect(m.title, isNull);
      expect(m.creator, isNull);
      expect(m.keywords, isEmpty);
      // A timestamp alone still counts as metadata.
      expect(m.created, '2025-08-04T18:53:49Z');
      expect(m.isEmpty, isFalse);
    });

    test('decodes XML entities in text', () {
      final m = parse(
        '<dc:description>amp &amp; lt &lt; gt &gt;</dc:description>',
      );
      expect(m.description, 'amp & lt < gt >');
    });

    test('decodes _x000d_ escapes and normalizes line endings', () {
      final m = parse(
        '<dc:description>Line one._x000d_\nLine two.</dc:description>',
      );
      expect(m.description, 'Line one.\nLine two.');
      expect(m.description, isNot(contains('_x000d_')));
      expect(m.description, isNot(contains('\r')));
    });

    test('preserves a longer multiline description', () {
      final m = parse('<dc:description>a_x000d_\nb_x000d_\nc</dc:description>');
      expect(m.description!.split('\n'), ['a', 'b', 'c']);
    });

    test('a literal escaped underscore (_x005f_) round-trips', () {
      // OOXML escapes a literal "_x000d_" as "_x005f_x000d_".
      final m = parse('<dc:title>_x005f_x000d_</dc:title>');
      expect(m.title, '_x000d_');
    });

    test('splits keywords on commas and semicolons', () {
      final m = parse('<cp:keywords>a, b ; c,d</cp:keywords>');
      expect(m.keywords, ['a', 'b', 'c', 'd']);
    });

    test('captures unknown core elements into extra (no data dropped)', () {
      final m = parse('<cp:contentStatus>Final</cp:contentStatus>');
      expect(m.extra['contentStatus'], 'Final');
      expect(m.isEmpty, isFalse);
    });
  });

  group('parseDocumentMetadata custom', () {
    test('parses custom properties of every supported vt type', () {
      final m = parse(
        null,
        customInner:
            '<property fmtid="{x}" pid="2" name="Company">'
            '<vt:lpwstr>ACME</vt:lpwstr></property>'
            '<property fmtid="{x}" pid="3" name="Legacy">'
            '<vt:lpstr>old</vt:lpstr></property>'
            '<property fmtid="{x}" pid="4" name="Count">'
            '<vt:i4>42</vt:i4></property>'
            '<property fmtid="{x}" pid="5" name="Big">'
            '<vt:int>7</vt:int></property>'
            '<property fmtid="{x}" pid="6" name="Ratio">'
            '<vt:r8>3.14</vt:r8></property>'
            '<property fmtid="{x}" pid="7" name="Flag">'
            '<vt:bool>true</vt:bool></property>'
            '<property fmtid="{x}" pid="8" name="Stamp">'
            '<vt:filetime>2025-08-04T18:53:49Z</vt:filetime></property>'
            '<property fmtid="{x}" pid="9" name="When">'
            '<vt:date>2025-08-04T00:00:00Z</vt:date></property>'
            '<property fmtid="{x}" pid="10" name="Blank">'
            '<vt:lpwstr/></property>',
      );
      expect(m.custom['Company'], 'ACME');
      expect(m.custom['Legacy'], 'old');
      expect(m.custom['Count'], '42');
      expect(m.custom['Big'], '7');
      expect(m.custom['Ratio'], '3.14');
      expect(m.custom['Flag'], 'true');
      expect(m.custom['Stamp'], '2025-08-04T18:53:49Z');
      expect(m.custom['When'], '2025-08-04T00:00:00Z');
      expect(m.custom['Blank'], '');
    });

    test('decodes entities and escapes in custom values', () {
      final m = parse(
        null,
        customInner:
            '<property fmtid="{x}" pid="2" name="Amp">'
            '<vt:lpwstr>a &amp; b</vt:lpwstr></property>'
            '<property fmtid="{x}" pid="3" name="Multi">'
            '<vt:lpwstr>x_x000d_\ny</vt:lpwstr></property>',
      );
      expect(m.custom['Amp'], 'a & b');
      expect(m.custom['Multi'], 'x\ny');
    });

    test('ignores custom properties without a name', () {
      final m = parse(
        null,
        customInner:
            '<property fmtid="{x}" pid="2">'
            '<vt:lpwstr>orphan</vt:lpwstr></property>',
      );
      expect(m.custom, isEmpty);
    });
  });

  group('parseDocumentMetadata robustness', () {
    test('missing parts produce empty metadata without throwing', () {
      final m = parse(null);
      expect(m.isEmpty, isTrue);
    });

    test('malformed core (strict=false) warns and keeps custom props', () {
      final warnings = <DocWarning>[];
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Body')),
        coreXml: '<cp:coreProperties>', // truncated, invalid XML
        customXml: custom(
          '<property fmtid="{x}" pid="2" name="Ok">'
          '<vt:lpwstr>kept</vt:lpwstr></property>',
        ),
      );
      final pkg = DocxPackage.openBytes(bytes);
      addTearDown(pkg.close);

      final m = parseDocumentMetadata(
        pkg,
        strict: false,
        onWarning: warnings.add,
      );
      expect(m.title, isNull);
      expect(m.custom['Ok'], 'kept');
      expect(warnings.map((w) => w.code), contains('metadata.malformed'));
    });

    test('malformed core (strict=true) throws', () {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Body')),
        coreXml: '<cp:coreProperties>',
      );
      final pkg = DocxPackage.openBytes(bytes);
      addTearDown(pkg.close);

      expect(
        () => parseDocumentMetadata(pkg, strict: true),
        throwsA(isA<DocxPackageException>()),
      );
    });

    test('resolves docProps via fallback path when rels are absent', () {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Body')),
        extraXmlParts: {
          'docProps/core.xml': core('<dc:title>Fallback</dc:title>'),
        },
      );
      final pkg = DocxPackage.openBytes(bytes);
      addTearDown(pkg.close);

      final m = parseDocumentMetadata(pkg);
      expect(m.title, 'Fallback');
    });
  });
}
