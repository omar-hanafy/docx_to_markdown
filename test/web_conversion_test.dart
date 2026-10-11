@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:docx_to_markdown/docx_to_markdown.dart';
import 'package:test/test.dart';

import 'utils/compressed_docx_fixture.dart';
import 'utils/docx_fixture.dart';

void main() {
  test('decodes a real compressed Word document on web', () async {
    final markdown = await DocxConverter(compressedDocxFixture()).convert();
    expect(
      markdown,
      'Bullets whose numbering comes from the paragraph style:\n\n'
      '- First style-driven bullet.\n- Second style-driven bullet.\n'
      '- Third style-driven bullet.\n\nClosing paragraph.',
    );
  });

  for (final endian in [Endian.little, Endian.big]) {
    final byteOrder = endian == Endian.little ? 'LE' : 'BE';
    test('converts UTF-16 $byteOrder XML on web', () async {
      const content = 'مرحبا 世界 😀';
      final xml = docXmlWithBody(wP(text: content))
          .replaceFirst('UTF-8', 'UTF-16');
      final data = ByteData((xml.codeUnits.length + 1) * 2)
        ..setUint16(0, 0xfeff, endian);
      for (var i = 0; i < xml.codeUnits.length; i++) {
        data.setUint16((i + 1) * 2, xml.codeUnits[i], endian);
      }
      final bytes = buildDocxBytes(
        media: {'word/document.xml': data.buffer.asUint8List()},
      );
      expect((await DocxConverter(bytes).convert()).trim(), content);
    });
  }

  test('exports images outside word/media on web', () async {
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
          target: '/custom/picture.png',
        ),
      ],
      media: {
        'custom/picture.png': Uint8List.fromList([1, 2, 3]),
      },
    );
    final markdown = await DocxConverter(bytes).convert(
      imageAssetSink: (asset) {
        expect(asset.partPath, 'custom/picture.png');
        expect(asset.bytes, [1, 2, 3]);
        return 'blob:custom-image';
      },
    );
    expect(markdown.trim(), '![Custom](blob:custom-image)');
  });

  test('converts DOCX bytes with imageAssetSink on web', () async {
    final bytes = buildDocxBytes(
      documentXml: docXmlWithBody(
        wP(
          innerXml: wR(
            innerXml: wDrawingImage(embedId: 'rId2', descr: 'AltText'),
          ),
        ),
      ),
      documentRels: const [
        DocxRel(
          id: 'rId2',
          type: DocxRelTypes.image,
          target: 'media/image1.png',
        ),
      ],
      media: {
        'word/media/image1.png': Uint8List.fromList([7, 8, 9]),
      },
    );

    DocxImageAsset? seenAsset;
    final markdown = await DocxConverter(bytes).convert(
      imageAssetSink: (asset) {
        seenAsset = asset;
        return 'blob:docx-image-1';
      },
    );

    expect(markdown.trim(), '![AltText](blob:docx-image-1)');
    expect(seenAsset?.partPath, 'word/media/image1.png');
    expect(seenAsset?.suggestedFilename, 'image1_1.png');
    expect(seenAsset?.contentType, 'image/png');
    expect(seenAsset?.bytes, [7, 8, 9]);
  });

  test('imageOutputDirectory is rejected on web', () async {
    final bytes = buildDocxBytes(
      documentXml: docXmlWithBody(wP(text: 'Hello')),
    );

    expect(
      DocxConverter(bytes).convert(imageOutputDirectory: 'images'),
      throwsA(isA<UnsupportedError>()),
    );
  });
}
