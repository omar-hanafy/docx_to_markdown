import 'package:docx_to_markdown/docx_to_markdown.dart';
import 'package:test/test.dart';

void main() {
  group('DocxToMarkdownConfig', () {
    test('defaults are stable and immutable', () {
      final config = DocxToMarkdownConfig.defaults;
      expect(config.flavor, MarkdownFlavor.gfm);
      expect(config.extractImages, isTrue);
      expect(config.bulletMarkers, contains('-'));
      expect(config.listIndent, greaterThanOrEqualTo(0));
      expect(() => config.bulletMarkers.add('x'), throwsUnsupportedError);
    });

    test('copyWith preserves existing values by default', () {
      final config = DocxToMarkdownConfig.defaults;
      final copy = config.copyWith();
      expect(copy.flavor, config.flavor);
      expect(copy.bulletMarkers, config.bulletMarkers);
      expect(copy.monospaceFonts, config.monospaceFonts);
    });

    test('copyWith overrides selected fields', () {
      final copy = DocxToMarkdownConfig.defaults.copyWith(
        flavor: MarkdownFlavor.commonmark,
        extractImages: false,
        orderedListNumbering: OrderedListNumbering.keep,
        lineBreakStyle: LineBreakStyle.htmlBr,
      );
      expect(copy.flavor, MarkdownFlavor.commonmark);
      expect(copy.extractImages, isFalse);
      expect(copy.orderedListNumbering, OrderedListNumbering.keep);
      expect(copy.lineBreakStyle, LineBreakStyle.htmlBr);
    });

    test('imageSizeMode none with maxImageWidth 0 is valid', () {
      final config = DocxToMarkdownConfig(
        maxImageWidth: 0,
        imageSizeMode: ImageSizeMode.none,
      );
      expect(config.maxImageWidth, 0);
      expect(config.imageSizeMode, ImageSizeMode.none);
    });

    test('bulletMarkers must be non-empty and non-blank', () {
      expect(
        () => DocxToMarkdownConfig(bulletMarkers: const []),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => DocxToMarkdownConfig(bulletMarkers: const [' ', '']),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('ParagraphStyleOverride', () {
    test('heading level must be 1..6', () {
      expect(
        () => ParagraphStyleOverride(headingLevel: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => ParagraphStyleOverride(headingLevel: 7),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('HookContext', () {
    test('location combines part/path by default', () {
      final ctx = const HookContext(
        part: 'word/document.xml',
        path: 'body/p[1]',
      );
      expect(ctx.location, 'word/document.xml::body/p[1]');
    });

    test('child builds hierarchical path', () {
      final ctx = const HookContext(part: 'word/document.xml', path: 'body');
      final child = ctx.child('p[2]');
      expect(child.location, 'word/document.xml::body/p[2]');
    });
  });
}
