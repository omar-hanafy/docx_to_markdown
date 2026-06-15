/// Converts DOCX (OOXML) documents to Markdown with configurable output.
///
/// This library parses `.docx` files in memory and produces Markdown text.
/// Use it when you need to migrate Word documents to Markdown-based systems
/// (wikis, static site generators, documentation platforms).
///
/// ## Capabilities
///
/// - **Content extraction**: paragraphs, headings, nested lists, tables
/// - **Image handling**: extracts embedded images to a directory or asset sink
/// - **Text formatting**: bold, italic, strikethrough, underline, inline code
/// - **Extensibility**: hooks let you rewrite links, transform blocks, or inject custom logic
///
/// ## Quick Start
///
/// ```dart
/// import 'package:docx_to_markdown/docx_to_markdown.dart';
///
/// final bytes = File('document.docx').readAsBytesSync();
/// final converter = DocxConverter(bytes);
/// final markdown = await converter.convert();
/// ```
///
/// ## Customization
///
/// For non-default behavior, pass a [DocxToMarkdownConfig]:
///
/// ```dart
/// final config = DocxToMarkdownConfig(
///   flavor: MarkdownFlavor.gfm,
///   extractImages: true,
///   underlineMode: UnderlineMode.html,
/// );
/// final converter = DocxConverter(bytes, config: config);
/// final markdown = await converter.convert(imageOutputDirectory: 'images/');
/// ```
///
/// See also:
/// - [DocxConverter] - the main conversion entry point
/// - [DocxToMarkdownConfig] - all configuration options
/// - [Document] - the intermediate representation if you need lower-level access
library;

import 'dart:typed_data';

import 'package:docx_to_markdown/src/config.dart';
import 'package:docx_to_markdown/src/media.dart';
import 'package:docx_to_markdown/src/markdown_renderer.dart';
import 'package:docx_to_markdown/src/ooxml_package.dart';
import 'package:docx_to_markdown/src/parser.dart';
import 'package:docx_to_markdown/src/styles.dart';

export 'src/config.dart';
export 'src/ir.dart';
export 'src/media.dart';
export 'src/ooxml_package.dart' show DocxPackageException;

/// Parses DOCX bytes and renders Markdown output.
///
/// [DocxConverter] is the primary entry point for converting Word documents.
/// It takes raw `.docx` file bytes, parses the OOXML structure, and produces
/// a Markdown string.
///
/// ### When to Use
///
/// Use [DocxConverter] when you have a complete `.docx` file in memory and
/// want Markdown output. For streaming or partial document access, consider
/// working with the IR types ([Document], [Block], [Inline]) directly.
///
/// ### Side Effects
///
/// - **Image export**: If [DocxToMarkdownConfig.extractImages] is `true`, pass
///   either an `imageOutputDirectory` for VM/native disk extraction or an
///   `imageAssetSink` for web-safe caller-owned assets.
/// - **Warnings**: Non-fatal issues (unsupported elements, complex tables)
///   are reported via [DocxToMarkdownHooks.onWarning] if configured.
///
/// ### Example
///
/// ```dart
/// final bytes = File('report.docx').readAsBytesSync();
/// final converter = DocxConverter(bytes, config: DocxToMarkdownConfig(
///   flavor: MarkdownFlavor.gfm,
///   extractImages: true,
/// ));
/// final md = await converter.convert(imageOutputDirectory: 'assets/');
/// ```
///
/// See also:
/// - [DocxToMarkdownConfig] for all configuration options
/// - [DocxPackageException] for input validation errors
class DocxConverter {
  /// Creates a converter for a DOCX file loaded into memory.
  ///
  /// The [bytes] must be the raw contents of a valid `.docx` file (a ZIP
  /// archive with OOXML structure). If [config] is omitted, sensible defaults
  /// from [DocxToMarkdownConfig.defaults] are used.
  ///
  /// The converter does not read from disk or network; you must load the file
  /// yourself before calling this constructor.
  DocxConverter(this._bytes, {DocxToMarkdownConfig? config})
    : config = config ?? DocxToMarkdownConfig.defaults;

  final Uint8List _bytes;

  /// The configuration controlling output format, content inclusion, and hooks.
  ///
  /// This is immutable after construction. To convert the same document with
  /// different settings, create a new [DocxConverter] instance.
  final DocxToMarkdownConfig config;

  /// Parses the DOCX and renders Markdown.
  ///
  /// Call this method to perform the actual conversion. The returned string
  /// is the complete Markdown representation of the document.
  ///
  /// ### Parameters
  ///
  /// - [imageOutputDirectory]: If provided (and [DocxToMarkdownConfig.extractImages]
  ///   is `true`), embedded images are extracted to this directory. Image
  ///   references in the output Markdown use relative paths. This option
  ///   requires VM/native file IO.
  /// - [imageAssetSink]: If provided (and [DocxToMarkdownConfig.extractImages]
  ///   is `true`), embedded image bytes are sent to the sink. The sink's
  ///   returned string becomes the Markdown image source. Returning `null` or
  ///   an empty string skips that image.
  ///
  /// ### Throws
  ///
  /// - [DocxPackageException] if [_bytes] is empty or not a valid ZIP/DOCX file.
  /// - [ArgumentError] if both [imageOutputDirectory] and [imageAssetSink] are
  ///   provided.
  /// - [UnsupportedError] if [imageOutputDirectory] is used on a platform
  ///   without local file IO, such as web.
  ///
  /// ### Side Effects
  ///
  /// - Writes image files to [imageOutputDirectory] if specified.
  /// - Invokes [imageAssetSink] for embedded images if specified.
  /// - Invokes [DocxToMarkdownHooks.onWarning] for non-fatal parsing issues.
  Future<String> convert({
    String? imageOutputDirectory,
    DocxImageAssetSink? imageAssetSink,
  }) async {
    if (imageOutputDirectory != null && imageAssetSink != null) {
      throw ArgumentError(
        'Pass either imageOutputDirectory or imageAssetSink, not both.',
      );
    }

    // Input validation for better error messages
    if (_bytes.isEmpty) {
      throw DocxPackageException('Empty file: cannot convert empty bytes');
    }
    // Check for ZIP signature ('PK' = 0x50 0x4B)
    if (_bytes.length < 4 || _bytes[0] != 0x50 || _bytes[1] != 0x4B) {
      throw DocxPackageException('Invalid file: not a valid ZIP/DOCX file');
    }

    final package = DocxPackage.openBytes(_bytes);
    try {
      // 1. Extract media if requested
      final mediaMap = <String, String>{};
      var allowUnmappedMediaReferences = false;
      if (config.extractImages) {
        if (imageAssetSink != null) {
          final extracted = await package.extractMediaToSink(imageAssetSink);
          mediaMap.addAll(extracted);
        } else if (imageOutputDirectory != null) {
          final extracted = await package.extractMediaToDirectory(
            imageOutputDirectory,
            overwrite: true,
          );
          mediaMap.addAll(extracted);
        } else {
          allowUnmappedMediaReferences = true;
        }
      }

      // 2. Load styles
      final styles = StyleRegistry();
      styles.setMonospaceFonts(config.monospaceFonts);
      styles.load(package.stylesXml);

      // Load "Code" style names from config
      if (config.codeBlockStyleName.isNotEmpty) {
        styles.addCodeStyleName(config.codeBlockStyleName);
      }

      // 3. Parse
      final parser = DocxParser(
        package: package,
        styles: styles,
        config: config,
        mediaMap: mediaMap,
        allowUnmappedMediaReferences: allowUnmappedMediaReferences,
        onWarning: (w) {
          if (config.hooks.onWarning != null) {
            config.hooks.onWarning!(
              w,
              HookContext(part: w.location.part, path: w.location.path),
            );
          }
        },
      );

      final document = parser.parseMainDocument();

      // 4. Render
      final renderer = MarkdownRenderer(config: config);
      return renderer.render(document);
    } finally {
      await package.close();
    }
  }
}
