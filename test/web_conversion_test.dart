@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:docx_to_markdown/docx_to_markdown.dart';
import 'package:test/test.dart';

import 'utils/docx_fixture.dart';

void main() {
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
