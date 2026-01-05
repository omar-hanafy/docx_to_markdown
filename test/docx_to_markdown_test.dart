import 'package:docx_to_markdown/docx_to_markdown.dart';
import 'package:test/test.dart';

void main() {
  group('DocxToMarkdownConfig', () {
    test('defaults', () {
      final config = DocxToMarkdownConfig.defaults;
      expect(config.flavor, MarkdownFlavor.gfm);
      expect(config.extractImages, isTrue);
    });

    test('copyWith works', () {
      final config = DocxToMarkdownConfig.defaults.copyWith(
        flavor: MarkdownFlavor.commonmark,
        extractImages: false,
      );
      expect(config.flavor, MarkdownFlavor.commonmark);
      expect(config.extractImages, isFalse);
    });
  });
}
