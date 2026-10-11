import 'dart:io';
import 'dart:typed_data';

import 'package:docx_to_markdown/docx_to_markdown.dart' show DocxConverter;
import 'package:docx_to_markdown/src/ooxml_package.dart';
import 'package:test/test.dart';

import 'utils/docx_fixture.dart';

void main() {
  group('DocxPackage', () {
    for (final endian in [Endian.little, Endian.big]) {
      final byteOrder = endian == Endian.little ? 'LE' : 'BE';
      for (final withBom in [true, false]) {
        test('converts UTF-16 $byteOrder XML (BOM: $withBom)', () async {
          const text = 'مرحبا 世界 😀';
          final encoding = withBom
              ? 'UTF-16'
              : endian == Endian.little
              ? 'UTF-16LE'
              : 'UTF-16BE';
          final xml = docXmlWithBody(wP(text: text))
              .replaceFirst('UTF-8', encoding);
          final data = ByteData((xml.codeUnits.length + (withBom ? 1 : 0)) * 2);
          var offset = 0;
          if (withBom) {
            data.setUint16(offset, 0xfeff, endian);
            offset += 2;
          }
          for (final unit in xml.codeUnits) {
            data.setUint16(offset, unit, endian);
            offset += 2;
          }
          final bytes = buildDocxBytes(
            media: {'word/document.xml': data.buffer.asUint8List()},
          );
          expect((await DocxConverter(bytes).convert()).trim(), text);
        });
      }
    }

    test('truncated UTF-16 failure is reported and cached', () {
      final bytes = buildDocxBytes(
        media: {
          'word/document.xml': Uint8List.fromList([0xff, 0xfe, 0x3c]),
        },
      );
      final pkg = DocxPackage.openBytes(bytes);
      addTearDown(pkg.close);
      for (var attempt = 0; attempt < 2; attempt++) {
        expect(
          () => pkg.documentXml,
          throwsA(
            isA<DocxXmlParseException>().having(
              (e) => e.inner,
              'decoding error',
              isA<FormatException>(),
            ),
          ),
        );
      }
    });

    test('exports relationship images outside word/media once', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(
          wP(
            innerXml: wR(
              innerXml: wDrawingImage(embedId: 'rId1', descr: 'Custom'),
            ),
          ),
        ),
        documentRels: const [
          DocxRel(
            id: 'rId1',
            type: DocxRelTypes.image,
            target: '../custom/picture.png',
          ),
          DocxRel(
            id: 'rId2',
            type: DocxRelTypes.image,
            target: '/custom/picture.png',
          ),
          DocxRel(
            id: 'rId3',
            type: DocxRelTypes.image,
            target: '/custom/external.png',
            external: true,
          ),
        ],
        extraXmlParts: {
          'word/_rels/header1.xml.rels': relsXml(const [
            DocxRel(
              id: 'rId4',
              type: DocxRelTypes.image,
              target: '../custom/header.png',
            ),
          ]),
        },
        media: {
          'custom/picture.png': Uint8List.fromList([1, 2, 3]),
          'custom/header.png': Uint8List.fromList([4, 5, 6]),
          'custom/external.png': Uint8List.fromList([7]),
          'custom/unreferenced.png': Uint8List.fromList([8]),
        },
      );
      final seen = <String>[];
      final markdown = await DocxConverter(bytes).convert(
        imageAssetSink: (asset) {
          seen.add(asset.partPath);
          expect(asset.contentType, 'image/png');
          return 'assets/${asset.suggestedFilename}';
        },
      );
      expect(seen, ['custom/header.png', 'custom/picture.png']);
      expect(markdown.trim(), '![Custom](assets/picture_2.png)');

      final pkg = DocxPackage.openBytes(bytes);
      addTearDown(pkg.close);
      final directory = await Directory.systemTemp.createTemp(
        'docx_custom_media_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final map = await pkg.extractMediaToDirectory(directory.path);
      expect(map.keys, seen);
      expect(
        await File('${directory.path}/${map['custom/picture.png']}')
            .readAsBytes(),
        [1, 2, 3],
      );
    });

    test('falls back to word/document.xml when no root rels', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Hello')),
        packageRels: const [],
      );
      final pkg = DocxPackage.openBytes(bytes);
      addTearDown(pkg.close);

      expect(pkg.mainDocumentPartPath, 'word/document.xml');
      expect(pkg.documentXml, isNotNull);
    });

    test('resolves main document part via root relationship', () async {
      final bytes = buildDocxBytes(
        documentPath: 'word/document2.xml',
        documentXml: docXmlWithBody(wP(text: 'Hello')),
        packageRels: const [
          DocxRel(
            id: 'rId1',
            type: DocxRelTypes.officeDocument,
            target: 'word/document2.xml',
          ),
        ],
      );
      final pkg = DocxPackage.openBytes(bytes);
      addTearDown(pkg.close);

      expect(pkg.mainDocumentPartPath, 'word/document2.xml');
    });

    test('root rel to missing part falls back to word/document.xml', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Hello')),
        packageRels: const [
          DocxRel(
            id: 'rId1',
            type: DocxRelTypes.officeDocument,
            target: 'word/missing.xml',
          ),
        ],
      );
      final pkg = DocxPackage.openBytes(bytes);
      addTearDown(pkg.close);

      expect(pkg.mainDocumentPartPath, 'word/document.xml');
    });

    test('openFile non-streaming', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Hello')),
      );
      final dir = await Directory.systemTemp.createTemp('docx_file_');
      addTearDown(() async {
        if (dir.existsSync()) {
          await dir.delete(recursive: true);
        }
      });
      final file = File('${dir.path}/test.docx');
      await file.writeAsBytes(bytes);

      final pkg = await DocxPackage.openFile(file.path);
      addTearDown(pkg.close);

      expect(pkg.isStreaming, isFalse);
      expect(pkg.documentXml, isNotNull);
    });

    test('resolves relationship targets relative to source', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Image')),
        documentRels: const [
          DocxRel(
            id: 'rId1',
            type: DocxRelTypes.image,
            target: 'media/image1.png',
          ),
        ],
      );
      final pkg = DocxPackage.openBytes(bytes);
      addTearDown(pkg.close);

      final resolved = pkg.resolveRelTarget('word/document.xml', 'rId1');
      expect(resolved, 'word/media/image1.png');
    });

    test('relationshipsForPart returns empty when rels missing', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Hello')),
      );
      final pkg = DocxPackage.openBytes(bytes);
      addTearDown(pkg.close);

      final rels = pkg.relationshipsForPart('word/document.xml');
      expect(rels.byId, isEmpty);
    });

    test('readPartText reads xml content', () async {
      const xml = '<root>ok</root>';
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Hello')),
        extraXmlParts: {'custom/part.xml': xml},
      );
      final pkg = DocxPackage.openBytes(bytes);
      addTearDown(pkg.close);

      final text = pkg.readPartText('custom/part.xml');
      expect(text, contains('root'));
    });

    test('hasPart/readPartBytes return false/null for missing part', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Hello')),
      );
      final pkg = DocxPackage.openBytes(bytes);
      addTearDown(pkg.close);

      expect(pkg.hasPart('word/missing.xml'), isFalse);
      expect(pkg.readPartBytes('word/missing.xml'), isNull);
    });

    test('openBytes wraps corrupt zip errors', () {
      final bytes = Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, 0x00]);
      expect(
        () => DocxPackage.openBytes(bytes),
        throwsA(isA<DocxPackageException>()),
      );
    });

    test('openFile supports streaming', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Hello')),
      );
      final dir = await Directory.systemTemp.createTemp('docx_file_');
      addTearDown(() async {
        if (dir.existsSync()) {
          await dir.delete(recursive: true);
        }
      });
      final file = File('${dir.path}/test.docx');
      await file.writeAsBytes(bytes);

      final pkg = await DocxPackage.openFile(file.path, streaming: true);
      addTearDown(pkg.close);

      expect(pkg.isStreaming, isTrue);
      expect(pkg.documentXml, isNotNull);
    });

    test('parses external relationships', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Link')),
        documentRels: const [
          DocxRel(
            id: 'rId5',
            type: DocxRelTypes.hyperlink,
            target: 'https://example.com',
            external: true,
          ),
        ],
      );
      final pkg = DocxPackage.openBytes(bytes);
      addTearDown(pkg.close);

      final rels = pkg.relationshipsForPart('word/document.xml');
      final rel = rels.byId['rId5'];
      expect(rel, isNotNull);
      expect(rel!.isExternal, isTrue);
      expect(rel.resolvedTarget, 'https://example.com');
    });

    test('loadXml throws on parse error and tryLoadXml returns null', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Hello')),
        stylesXml: '<w:styles>',
      );
      final pkg = DocxPackage.openBytes(bytes);
      addTearDown(pkg.close);

      expect(
        () => pkg.loadXml('word/styles.xml'),
        throwsA(isA<DocxXmlParseException>()),
      );
      expect(pkg.tryLoadXml('word/styles.xml'), isNull);
    });

    test('extractMediaToDirectory writes files and returns map', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Media')),
        media: {
          'word/media/image1.png': Uint8List.fromList(List<int>.filled(4, 0)),
        },
      );
      final pkg = DocxPackage.openBytes(bytes);
      addTearDown(pkg.close);

      final dir = await Directory.systemTemp.createTemp('docx_media_');
      addTearDown(() async {
        if (dir.existsSync()) {
          await dir.delete(recursive: true);
        }
      });

      final map = await pkg.extractMediaToDirectory(dir.path);
      expect(map.keys, contains('word/media/image1.png'));
      final filePath = '${dir.path}/${map['word/media/image1.png']}';
      expect(File(filePath).existsSync(), isTrue);
    });

    test('mediaAssets exposes bytes and stable metadata', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Media')),
        media: {
          'word/media/image1.png': Uint8List.fromList([1, 2, 3]),
        },
      );
      final pkg = DocxPackage.openBytes(bytes);
      addTearDown(pkg.close);

      final asset = pkg.mediaAssets().single;
      expect(asset.partPath, 'word/media/image1.png');
      expect(asset.suggestedFilename, 'image1_1.png');
      expect(asset.contentType, 'image/png');
      expect(asset.bytes, [1, 2, 3]);
    });

    test('resolves core/custom property parts via root rels', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Hi')),
        coreXml:
            '<cp:coreProperties '
            'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/">'
            '<dc:title>Hello</dc:title></cp:coreProperties>',
        customXml:
            '<Properties '
            'xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties">'
            '</Properties>',
      );
      final pkg = DocxPackage.openBytes(bytes);
      addTearDown(pkg.close);

      expect(pkg.corePropertiesPartPath, 'docProps/core.xml');
      expect(pkg.customPropertiesPartPath, 'docProps/custom.xml');
      expect(pkg.corePropertiesXml, isNotNull);
      expect(pkg.customPropertiesXml, isNotNull);
      expect(pkg.corePropertiesXml!.toXmlString(), contains('Hello'));
    });

    test('falls back to conventional docProps path without a rel', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Hi')),
        extraXmlParts: {
          'docProps/core.xml':
              '<cp:coreProperties '
              'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"/>',
        },
      );
      final pkg = DocxPackage.openBytes(bytes);
      addTearDown(pkg.close);

      expect(pkg.corePropertiesPartPath, 'docProps/core.xml');
      expect(pkg.customPropertiesPartPath, isNull);
    });

    test('core/custom property parts are null when absent', () async {
      final bytes = buildDocxBytes(documentXml: docXmlWithBody(wP(text: 'Hi')));
      final pkg = DocxPackage.openBytes(bytes);
      addTearDown(pkg.close);

      expect(pkg.corePropertiesPartPath, isNull);
      expect(pkg.customPropertiesPartPath, isNull);
      expect(pkg.corePropertiesXml, isNull);
      expect(pkg.customPropertiesXml, isNull);
    });

    test('canonicalizes part paths to posix style', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(wP(text: 'Hello')),
      );
      final pkg = DocxPackage.openBytes(bytes);
      addTearDown(pkg.close);

      expect(
        pkg.canonicalizePartPath('word\\document.xml'),
        'word/document.xml',
      );
    });
  });
}
