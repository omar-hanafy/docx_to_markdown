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
      expect(config.trackChangesMode, TrackChangesMode.acceptAll);
      expect(config.orderedListMarker, OrderedListMarker.decimal);
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
        trackChangesMode: TrackChangesMode.showDeletionsAsStrikethrough,
        orderedListMarker: OrderedListMarker.preserveFormat,
      );
      expect(copy.flavor, MarkdownFlavor.commonmark);
      expect(copy.extractImages, isFalse);
      expect(copy.orderedListNumbering, OrderedListNumbering.keep);
      expect(copy.lineBreakStyle, LineBreakStyle.htmlBr);
      expect(
        copy.trackChangesMode,
        TrackChangesMode.showDeletionsAsStrikethrough,
      );
      expect(copy.orderedListMarker, OrderedListMarker.preserveFormat);
    });

    test('highlight and color modes default to none and round-trip', () {
      final config = DocxToMarkdownConfig.defaults;
      expect(config.highlightMode, HighlightMode.none);
      expect(config.textColorMode, TextColorMode.none);

      final copy = config.copyWith(
        highlightMode: HighlightMode.mark,
        textColorMode: TextColorMode.htmlSpan,
      );
      expect(copy.highlightMode, HighlightMode.mark);
      expect(copy.textColorMode, TextColorMode.htmlSpan);
      // Unspecified copyWith preserves the overridden values.
      expect(copy.copyWith().highlightMode, HighlightMode.mark);
      expect(copy.copyWith().textColorMode, TextColorMode.htmlSpan);
    });

    test('pageBreakMode defaults to ignore and round-trips', () {
      expect(DocxToMarkdownConfig.defaults.pageBreakMode, PageBreakMode.ignore);
      final copy = DocxToMarkdownConfig.defaults.copyWith(
        pageBreakMode: PageBreakMode.thematicBreak,
      );
      expect(copy.pageBreakMode, PageBreakMode.thematicBreak);
      expect(copy.copyWith().pageBreakMode, PageBreakMode.thematicBreak);
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
