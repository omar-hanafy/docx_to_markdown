// src/config.dart
//
// Public, stable configuration surface for the DOCX → Markdown converter.
//
// Design goals:
// - Immutable-by-convention (defensively wraps lists/maps with unmodifiable views)
// - Small but expressive policies (tables, underline, unknown elements, etc.)
// - Extensibility hooks without forcing users to fork
//
// NOTE: This file intentionally depends only on the IR (src/ir.dart).
// It must not depend on OOXML parsing or rendering implementation details.

import 'package:docx_to_markdown/src/ir.dart';

/// The Markdown dialect to target for output.
///
/// Different Markdown flavors support different syntax extensions (tables,
/// strikethrough, task lists). Choose the flavor that matches your target
/// renderer to ensure correct display.
///
/// See also:
/// - [DocxToMarkdownConfig.flavor] where this is configured
enum MarkdownFlavor {
  /// GitHub Flavored Markdown.
  ///
  /// Enables GFM extensions: tables, strikethrough (`~~text~~`), task lists.
  /// Use this for GitHub READMEs, wikis, or any GFM-compatible renderer.
  gfm,

  /// Strict CommonMark without extensions.
  ///
  /// Produces portable Markdown that works everywhere but lacks table syntax.
  /// Tables will be rendered as HTML when [TableMode.auto] is used.
  commonmark,
}

/// Controls how DOCX tables are rendered in the output.
///
/// Markdown table syntax is limited: it cannot represent merged cells,
/// row spans, or complex layouts. Use this setting to balance output
/// quality against Markdown purity.
///
/// See also:
/// - [TableBlock.isComplex] indicates whether a table has merge/span issues
enum TableMode {
  /// Chooses Markdown for simple tables, HTML for complex ones.
  ///
  /// This is the recommended default. Simple tables (no merged cells, uniform
  /// columns) render as Markdown pipes. Complex tables with row/column spans
  /// fall back to `<table>` HTML to preserve structure.
  auto,

  /// Forces Markdown syntax for all tables.
  ///
  /// **Warning**: Complex tables (merged cells, row spans) will lose structure
  /// or render incorrectly. Use only when your documents have simple tables
  /// and you require pure Markdown output.
  markdownOnly,

  /// Forces HTML `<table>` for all tables.
  ///
  /// Use when you need consistent HTML output or when downstream processing
  /// handles HTML better than Markdown table syntax.
  htmlOnly,
}

/// Controls how underlined text is rendered in output.
///
/// Standard Markdown has no underline syntax. This setting lets you choose
/// between HTML tags, non-standard syntax, or dropping the formatting.
///
/// See also:
/// - [UnderlineInline] — the IR node representing underlined text
enum UnderlineMode {
  /// Renders underline as `<u>text</u>`.
  ///
  /// This is the safest choice for preserving the author's intent. Works in
  /// any renderer that supports inline HTML.
  html,

  /// Renders underline as `++text++`.
  ///
  /// Non-standard syntax supported by CriticMarkup and some Markdown editors
  /// (iA Writer, Ulysses). Use only if your target renderer supports it.
  plusPlus,

  /// Drops underline formatting, keeping only the text content.
  ///
  /// Use when underlines are not semantically important in your documents
  /// or when you need pure Markdown without HTML.
  ignore,
}

/// Determines how unrecognized OOXML elements are handled during parsing.
///
/// The DOCX format has many features (SmartArt, charts, embedded objects) that
/// cannot be cleanly converted to Markdown. This policy controls whether to
/// silently drop them, preserve their text content, or emit debug information.
///
/// A [DocWarning] with code `"unsupported.block"` or `"unsupported.inline"` is
/// emitted regardless of policy, so you can track what was downgraded.
enum UnknownElementPolicy {
  /// Silently removes the element from output.
  ///
  /// Produces the cleanest Markdown but loses content. Use when you know
  /// your documents don't contain important unsupported elements.
  drop,

  /// Extracts and keeps any text content inside the element.
  ///
  /// This is the recommended default. A SmartArt diagram's labels or a chart's
  /// data labels are preserved as plain text, even if the visual structure is lost.
  keepText,

  /// Emits an HTML comment with serialized XML for debugging.
  ///
  /// Useful for auditing what was lost during conversion. The output is noisy
  /// but lets you see exactly what OOXML content was not converted.
  keepHtml,
}

/// Controls how ordered list numbers are rendered in Markdown output.
///
/// DOCX ordered lists may start at arbitrary numbers or use custom sequences.
/// This setting controls whether to preserve that numbering or normalize it.
///
/// See also:
/// - [ListBlock.start] — the IR property holding the starting number
enum OrderedListNumbering {
  /// Attempts to preserve the original numbering from the DOCX.
  ///
  /// Lists starting at 5 will output `5.`, `6.`, etc. Note that Markdown
  /// renderers vary in how they handle non-1 start values.
  keep,

  /// Emits `1.` for every list item.
  ///
  /// This is valid Markdown and most renderers will auto-increment the display
  /// numbers. Use this for maximum compatibility and cleaner diffs.
  alwaysOne,
}

/// Controls how DOCX line breaks (`w:br`) are rendered in Markdown.
///
/// DOCX documents use explicit break elements for line breaks within paragraphs.
/// Markdown has multiple ways to represent these, with varying compatibility.
///
/// See also:
/// - [LineBreakInline] — the IR node representing a hard line break
enum LineBreakStyle {
  /// Two trailing spaces followed by newline (`  \n`).
  ///
  /// The standard Markdown hard break. Works in GFM and CommonMark but can be
  /// invisible in editors and may be stripped by formatters.
  hardBreak,

  /// HTML `<br/>` tag.
  ///
  /// Explicit and never stripped by formatters. Use when you need guaranteed
  /// line breaks and your target supports inline HTML.
  htmlBr,

  /// Plain newline character (`\n`).
  ///
  /// May render as a soft break (space) in strict CommonMark renderers.
  /// Use only if your target renderer interprets newlines as line breaks.
  newline,
}

/// Controls how image dimensions are encoded in Markdown output.
///
/// Standard Markdown has no image sizing syntax. This setting enables
/// non-standard extensions supported by specific renderers.
///
/// Dimensions are taken from the DOCX drawing properties when available.
///
/// See also:
/// - [DocxToMarkdownConfig.maxImageWidth] for constraining image widths
/// - [ImageInline], [ImageBlock] — the IR nodes for images
enum ImageSizeMode {
  /// Omits any size information from image syntax.
  ///
  /// Produces standard `![alt](src)` syntax that works everywhere.
  none,

  /// Obsidian-style dimensions: `![alt](img.png =300x200)`.
  ///
  /// Supported by Obsidian and some other note-taking apps. The `=WxH` suffix
  /// is appended to the image URL.
  obsidian,

  /// Pandoc-style attributes: `![alt](img.png){ width=300px }`.
  ///
  /// Supported by Pandoc and compatible processors. Enables precise control
  /// over image dimensions in PDF and HTML output.
  pandoc,
}

/// Maps a Word paragraph style to a specific Markdown block type.
///
/// Use this to handle custom styles in your organization's document templates.
/// For example, if your company uses a "CodeExample" style for code samples,
/// you can map it to fenced code blocks.
///
/// ### Example
///
/// ```dart
/// final config = DocxToMarkdownConfig(
///   paragraphStyleOverrides: {
///     'CodeExample': ParagraphStyleOverride(isCodeBlock: true, codeLanguage: 'dart'),
///     'ImportantNote': ParagraphStyleOverride(isQuote: true),
///     'ChapterTitle': ParagraphStyleOverride(headingLevel: 1),
///   },
/// );
/// ```
///
/// See also:
/// - [DocxToMarkdownConfig.paragraphStyleOverrides] where these are configured
/// - [DocxToMarkdownConfig.codeBlockStyleName] for the common "Code" style case
class ParagraphStyleOverride {
  /// Creates a style override.
  ///
  /// At least one property should be non-null for the override to have effect.
  /// If [headingLevel] is provided, it must be between 1 and 6.
  const ParagraphStyleOverride({
    this.headingLevel,
    this.isCodeBlock,
    this.isQuote,
    this.codeLanguage,
  }) : assert(
         headingLevel == null || (headingLevel >= 1 && headingLevel <= 6),
         'headingLevel must be 1..6',
       );

  /// Forces this style to render as a heading of the given level (1–6).
  ///
  /// Useful for custom heading styles like "ChapterTitle" or "SectionHeader"
  /// that don't use Word's built-in Heading 1–6 styles.
  final int? headingLevel;

  /// Forces this style to render as a fenced code block.
  ///
  /// When `true`, the paragraph text becomes the code block content.
  /// Combine with [codeLanguage] for syntax highlighting.
  final bool? isCodeBlock;

  /// Forces this style to render as a block quote.
  ///
  /// When `true`, the paragraph is prefixed with `>` in Markdown output.
  final bool? isQuote;

  /// The language identifier for fenced code blocks (e.g., `"dart"`, `"python"`).
  ///
  /// Only used when [isCodeBlock] is `true`. Produces output like:
  /// ~~~markdown
  /// ```dart
  /// code here
  /// ```
  /// ~~~
  final String? codeLanguage;
}

/// Contextual information passed to hook functions during parsing.
///
/// [HookContext] provides location and styling information about the element
/// being processed. Use it to make context-sensitive decisions in your hooks.
///
/// ### Example
///
/// ```dart
/// final hooks = DocxToMarkdownHooks(
///   transformBlock: (block, ctx) {
///     if (ctx.styleId == 'Draft') {
///       return null; // Drop paragraphs with "Draft" style
///     }
///     return block;
///   },
/// );
/// ```
///
/// See also:
/// - [DocxToMarkdownHooks] where hooks are configured
/// - [SourceLocation] for the underlying location type
class HookContext {
  /// Creates a hook context with optional location and style information.
  const HookContext({
    this.part = '',
    this.path = '',
    this.styleId,
    this.listLevel,
    this.meta = const {},
    String? location,
  }) : _locationOverride = location;

  /// The OOXML part being processed, e.g., `word/document.xml`.
  ///
  /// Useful for distinguishing between main document, headers, footers, etc.
  final String part;

  /// XPath-like location within the part, e.g., `body/p[12]/r[3]`.
  ///
  /// The format is best-effort and may vary. Use for debugging and logging.
  final String path;

  /// The Word paragraph style ID when processing a paragraph.
  ///
  /// This is the internal style identifier (e.g., `"Heading1"`, `"Normal"`),
  /// not the display name. Use to apply style-specific logic in hooks.
  final String? styleId;

  /// The list nesting level (0-based) when processing a list item.
  ///
  /// `null` if not inside a list; `0` for top-level list items.
  final int? listLevel;

  /// Additional metadata for future expansion.
  ///
  /// Use sparingly. Common keys include `"styleId"`, `"numId"`, `"rid"`.
  final Map<String, Object?> meta;

  final String? _locationOverride;

  /// A formatted string suitable for logging: `"part::path"`.
  String get location => _locationOverride ?? '$part::$path';

  /// Creates a copy of this context with the given fields replaced.
  ///
  /// Use this to override specific fields while preserving the rest.
  HookContext copyWith({
    String? part,
    String? path,
    String? styleId,
    int? listLevel,
    Map<String, Object?>? meta,
    String? location,
  }) {
    return HookContext(
      part: part ?? this.part,
      path: path ?? this.path,
      styleId: styleId ?? this.styleId,
      listLevel: listLevel ?? this.listLevel,
      meta: meta ?? this.meta,
      location: location ?? _locationOverride,
    );
  }

  /// Creates a child context by appending a segment to the current path.
  ///
  /// Used internally when descending into nested XML structures. The [segment]
  /// is appended to [path] with a `/` separator.
  HookContext child(
    String segment, {
    String? styleId,
    int? listLevel,
    Map<String, Object?>? meta,
  }) {
    return HookContext(
      part: part,
      path: path.isEmpty ? segment : '$path/$segment',
      styleId: styleId ?? this.styleId,
      listLevel: listLevel ?? this.listLevel,
      meta: meta ?? this.meta,
    );
  }
}

// ---------------------------------------------------------------------------
// Hook type definitions
// ---------------------------------------------------------------------------

/// Callback invoked when the parser emits a non-fatal warning.
///
/// Use to collect warnings, log them, or take corrective action. The [warning]
/// contains a machine-readable [DocWarning.code] and human-readable message.
typedef WarningHandler = void Function(DocWarning warning, HookContext ctx);

/// Transforms or filters a parsed block before rendering.
///
/// Return the block unchanged, return a modified block, or return `null` to
/// drop it from output entirely.
///
/// ### Example: Drop empty paragraphs
///
/// ```dart
/// Block? dropEmpty(Block block, HookContext ctx) {
///   if (block is ParagraphBlock && block.isEmpty) return null;
///   return block;
/// }
/// ```
typedef BlockTransformer = Block? Function(Block block, HookContext ctx);

/// Transforms or filters a parsed inline element before rendering.
///
/// Return the inline unchanged, return a modified inline, or return `null`
/// to drop it from output.
typedef InlineTransformer =
    Inline? Function(Inline inlineNode, HookContext ctx);

/// Rewrites hyperlink URLs before rendering.
///
/// Use to fix relative paths, add tracking parameters, or redirect links.
/// The returned string replaces the original URL in output.
typedef LinkRewriter = String Function(String url, [HookContext? ctx]);

/// Rewrites image source paths before rendering.
///
/// Use to map extracted filenames to CDN URLs, add image processing
/// parameters, or redirect to a different host.
typedef ImageRewriter = String Function(String src, [HookContext? ctx]);

/// Converts Office Math Markup Language (OMML) to LaTeX.
///
/// DOCX equations use OMML format. Return a LaTeX string to render the
/// equation, or return `null` to fall back to extracting raw text from
/// the `<m:t>` elements (lossy but readable).
typedef OmmlToLatexConverter =
    String? Function(String ommlXml, [HookContext? ctx]);

/// Extension points for customizing parsing and rendering behavior.
///
/// Hooks let you intercept the conversion process without forking the library.
/// All hooks are optional; `null` means no-op / default behavior.
///
/// ### Common Use Cases
///
/// - **Collect warnings**: Use [onWarning] to log or aggregate parsing issues.
/// - **Filter content**: Use [transformBlock] to drop or replace paragraphs.
/// - **Fix links**: Use [rewriteLinkTarget] to convert relative URLs to absolute.
/// - **CDN images**: Use [rewriteImageTarget] to point extracted images to a CDN.
/// - **Math support**: Use [ommlToLatex] to convert equations to LaTeX.
///
/// ### Example
///
/// ```dart
/// final hooks = DocxToMarkdownHooks(
///   onWarning: (w, ctx) => print('Warning at ${ctx.location}: ${w.message}'),
///   rewriteLinkTarget: (url, ctx) => url.startsWith('/')
///       ? 'https://example.com$url'
///       : url,
/// );
/// final config = DocxToMarkdownConfig(hooks: hooks);
/// ```
///
/// See also:
/// - [HookContext] for location/style information passed to hooks
/// - [DocWarning] for warning structure
class DocxToMarkdownHooks {
  /// Creates a hooks configuration.
  ///
  /// All parameters are optional. Pass only the hooks you need.
  const DocxToMarkdownHooks({
    this.onWarning,
    this.transformBlock,
    this.transformInline,
    this.rewriteLinkTarget,
    this.rewriteImageTarget,
    this.ommlToLatex,
  });

  /// Called when the parser emits a non-fatal warning.
  ///
  /// Warnings indicate degraded output (unsupported features, complex tables
  /// rendered as HTML, etc.) but don't stop conversion.
  final WarningHandler? onWarning;

  /// Intercepts each block after parsing, before rendering.
  ///
  /// Return the block to keep it, return a modified block to replace it,
  /// or return `null` to drop it from output.
  final BlockTransformer? transformBlock;

  /// Intercepts each inline element after parsing, before rendering.
  ///
  /// Return the inline to keep it, return a modified inline to replace it,
  /// or return `null` to drop it from output.
  final InlineTransformer? transformInline;

  /// Rewrites hyperlink URLs before rendering.
  ///
  /// Called for each [LinkInline]. Return the rewritten URL.
  final LinkRewriter? rewriteLinkTarget;

  /// Rewrites image source paths before rendering.
  ///
  /// Called for each [ImageInline] and [ImageBlock]. Return the rewritten path.
  final ImageRewriter? rewriteImageTarget;

  /// Converts OMML equations to LaTeX.
  ///
  /// Return a LaTeX string, or `null` to use default text extraction.
  final OmmlToLatexConverter? ommlToLatex;
}

/// Complete configuration for DOCX to Markdown conversion.
///
/// [DocxToMarkdownConfig] controls every aspect of the conversion: output
/// format, content inclusion, code detection, list rendering, and hooks.
/// All options have sensible defaults; create an instance with no arguments
/// for standard GFM output.
///
/// ### Immutability
///
/// Configuration objects are immutable. Lists and maps are defensively copied
/// and wrapped in unmodifiable views. Use [copyWith] to create modified copies.
///
/// ### Example
///
/// ```dart
/// // Minimal configuration
/// final config = DocxToMarkdownConfig();
///
/// // Custom configuration
/// final config = DocxToMarkdownConfig(
///   flavor: MarkdownFlavor.commonmark,
///   extractImages: true,
///   underlineMode: UnderlineMode.ignore,
///   paragraphStyleOverrides: {
///     'Code': ParagraphStyleOverride(isCodeBlock: true),
///   },
/// );
/// ```
///
/// See also:
/// - [DocxConverter] where this configuration is used
/// - [DocxToMarkdownConfig.defaults] for the default instance
class DocxToMarkdownConfig {
  /// Creates a configuration with the specified options.
  ///
  /// All parameters are optional and have sensible defaults:
  /// - [flavor]: GFM (GitHub Flavored Markdown)
  /// - [tableMode]: Auto (Markdown for simple, HTML for complex)
  /// - [underlineMode]: HTML `<u>` tags
  /// - [unknownElementPolicy]: Keep text content
  ///
  /// See individual field documentation for detailed behavior.
  DocxToMarkdownConfig({
    // Output flavor / policies
    this.flavor = MarkdownFlavor.gfm,
    this.tableMode = TableMode.auto,
    this.underlineMode = UnderlineMode.html,
    this.unknownElementPolicy = UnknownElementPolicy.keepText,

    // What content to include
    this.extractImages = true,
    this.includeFootnotes = true,
    this.includeEndnotes = false,
    this.includeComments = false,
    this.includeHeadersFooters = false,

    // Paragraph behavior
    this.preserveEmptyParagraphs = false,
    this.trimTrailingWhitespace = true,

    // Lists
    this.orderedListNumbering = OrderedListNumbering.alwaysOne,
    List<String> bulletMarkers = const ['-', '*', '+'],
    this.listIndent = 2,
    this.tightLists = true,

    // Inline behavior
    this.lineBreakStyle = LineBreakStyle.hardBreak,

    // Code detection
    this.codeBlockStyleName = 'Code',
    List<String> monospaceFonts = const [
      'consolas',
      'courier',
      'menlo',
      'monaco',
      'source code pro',
      'lucida console',
      'andale mono',
    ],
    this.treatShadedRunsAsCode = true,

    // Images
    this.maxImageWidth = 0,
    this.imageSizeMode = ImageSizeMode.none,

    // Style overrides (keyed by paragraph styleId)
    Map<String, ParagraphStyleOverride> paragraphStyleOverrides = const {},

    // Diagnostics
    this.strict = false,
    this.emitWarningsAsHtmlComments = false,

    // Hooks
    this.hooks = const DocxToMarkdownHooks(),
  }) : assert(listIndent >= 0, 'listIndent must be >= 0'),
       assert(maxImageWidth >= 0, 'maxImageWidth must be >= 0'),
       assert(bulletMarkers.isNotEmpty, 'bulletMarkers cannot be empty'),
       assert(
         bulletMarkers.every((m) => m.trim().isNotEmpty),
         'bulletMarkers must not contain empty markers',
       ),
       bulletMarkers = List.unmodifiable(bulletMarkers),
       monospaceFonts = List.unmodifiable(monospaceFonts),
       paragraphStyleOverrides = Map.unmodifiable(paragraphStyleOverrides);

  /// A pre-built configuration with all default values.
  ///
  /// Equivalent to `DocxToMarkdownConfig()` but avoids repeated allocations.
  static final defaults = DocxToMarkdownConfig();

  // --------------------------------------------------------------------------
  // Output flavor / policies
  // --------------------------------------------------------------------------

  /// The Markdown dialect to target. Defaults to [MarkdownFlavor.gfm].
  ///
  /// See [MarkdownFlavor] for available options and their implications.
  final MarkdownFlavor flavor;

  /// How to render DOCX tables. Defaults to [TableMode.auto].
  ///
  /// See [TableMode] for options. Complex tables may lose structure in
  /// Markdown-only mode.
  final TableMode tableMode;

  /// How to render underlined text. Defaults to [UnderlineMode.html].
  ///
  /// See [UnderlineMode] for options.
  final UnderlineMode underlineMode;

  /// What to do with unrecognized OOXML elements. Defaults to [UnknownElementPolicy.keepText].
  ///
  /// See [UnknownElementPolicy] for options.
  final UnknownElementPolicy unknownElementPolicy;

  // --------------------------------------------------------------------------
  // Content toggles
  // --------------------------------------------------------------------------

  /// Whether to extract embedded images from the DOCX. Defaults to `true`.
  ///
  /// When `true` and an `imageOutputDirectory` is passed to [DocxConverter.convert],
  /// images are written to disk and referenced by relative path. When `false`,
  /// images are omitted from output.
  final bool extractImages;

  /// Whether to include footnotes in the output. Defaults to `true`.
  ///
  /// Footnotes are rendered at the end of the document using Markdown
  /// footnote syntax (`[^1]`).
  final bool includeFootnotes;

  /// Whether to include endnotes in the output. Defaults to `false`.
  ///
  /// Endnotes are treated similarly to footnotes when enabled.
  final bool includeEndnotes;

  /// Whether to include Word comments in the output. Defaults to `false`.
  ///
  /// When `true`, comments are rendered as HTML `<!-- comment -->` blocks.
  final bool includeComments;

  /// Whether to include headers and footers. Defaults to `false`.
  ///
  /// Headers and footers are rendered as separate sections when enabled.
  final bool includeHeadersFooters;

  // --------------------------------------------------------------------------
  // Paragraph behavior
  // --------------------------------------------------------------------------

  /// Whether to preserve empty paragraphs as blank lines. Defaults to `false`.
  ///
  /// When `false`, consecutive empty paragraphs are collapsed. When `true`,
  /// each empty paragraph produces a blank line (except in tight lists).
  final bool preserveEmptyParagraphs;

  /// Whether to trim trailing whitespace from output lines. Defaults to `true`.
  ///
  /// Trailing whitespace can cause issues with some Markdown processors and
  /// version control systems.
  final bool trimTrailingWhitespace;

  // --------------------------------------------------------------------------
  // Lists
  // --------------------------------------------------------------------------

  /// How to number ordered list items. Defaults to [OrderedListNumbering.alwaysOne].
  ///
  /// See [OrderedListNumbering] for options.
  final OrderedListNumbering orderedListNumbering;

  /// Markers for bullet lists, cycled by nesting depth.
  ///
  /// Defaults to `['-', '*', '+']`. Depth 0 uses `-`, depth 1 uses `*`,
  /// depth 2 uses `+`, then cycles back to `-`.
  final List<String> bulletMarkers;

  /// Spaces per list nesting level. Defaults to `2`.
  ///
  /// Most Markdown processors require 2–4 spaces for proper list nesting.
  /// Must be non-negative.
  final int listIndent;

  /// Whether to render list items without blank lines between them. Defaults to `true`.
  ///
  /// Tight lists are more compact but may not work with all Markdown processors.
  final bool tightLists;

  // --------------------------------------------------------------------------
  // Inline behavior
  // --------------------------------------------------------------------------

  /// How to render line breaks within paragraphs. Defaults to [LineBreakStyle.hardBreak].
  ///
  /// See [LineBreakStyle] for options and their compatibility.
  final LineBreakStyle lineBreakStyle;

  // --------------------------------------------------------------------------
  // Code detection
  // --------------------------------------------------------------------------

  /// The Word style name that indicates a code block. Defaults to `"Code"`.
  ///
  /// Paragraphs with this style (or derived styles) are rendered as fenced
  /// code blocks. For more control, use [paragraphStyleOverrides].
  final String codeBlockStyleName;

  /// Font family names (lowercased) that indicate inline code.
  ///
  /// Defaults to common monospace fonts: Consolas, Courier, Menlo, Monaco, etc.
  /// Runs using these fonts are rendered as inline code (`` `text` ``).
  final List<String> monospaceFonts;

  /// Whether shaded runs (`w:shd`) are treated as inline code. Defaults to `true`.
  ///
  /// Many Word users highlight code with background shading rather than
  /// using a specific font or style.
  final bool treatShadedRunsAsCode;

  // --------------------------------------------------------------------------
  // Images
  // --------------------------------------------------------------------------

  /// Maximum image width hint in pixels. Defaults to `0` (disabled).
  ///
  /// When non-zero and [imageSizeMode] is not [ImageSizeMode.none], images
  /// wider than this value include a width hint. The actual constraining
  /// depends on the target renderer.
  final int maxImageWidth;

  /// How to encode image dimensions. Defaults to [ImageSizeMode.none].
  ///
  /// See [ImageSizeMode] for available syntaxes.
  final ImageSizeMode imageSizeMode;

  // --------------------------------------------------------------------------
  // Style overrides
  // --------------------------------------------------------------------------

  /// Custom mappings from Word style IDs to Markdown block types.
  ///
  /// Keys are Word style IDs (e.g., `"Heading1"`, `"Code"`, `"MyCustomStyle"`).
  /// Values specify how paragraphs with that style should render.
  ///
  /// See [ParagraphStyleOverride] for available options.
  final Map<String, ParagraphStyleOverride> paragraphStyleOverrides;

  // --------------------------------------------------------------------------
  // Diagnostics
  // --------------------------------------------------------------------------

  /// Whether to throw on structural problems. Defaults to `false`.
  ///
  /// When `false`, missing parts or corrupt structures produce warnings and
  /// partial output. When `true`, a [DocxPackageException] is thrown instead.
  final bool strict;

  /// Whether to embed warnings as HTML comments in output. Defaults to `false`.
  ///
  /// Useful for debugging. Warnings appear as `<!-- Warning: ... -->`.
  final bool emitWarningsAsHtmlComments;

  // --------------------------------------------------------------------------
  // Hooks
  // --------------------------------------------------------------------------

  /// Extension points for custom parsing and rendering logic.
  ///
  /// See [DocxToMarkdownHooks] for available hooks.
  final DocxToMarkdownHooks hooks;

  /// Creates a copy of this configuration with the given fields replaced.
  ///
  /// Use this to create variations of an existing configuration without
  /// mutating the original. Unspecified fields retain their current values.
  DocxToMarkdownConfig copyWith({
    MarkdownFlavor? flavor,
    TableMode? tableMode,
    UnderlineMode? underlineMode,
    UnknownElementPolicy? unknownElementPolicy,
    bool? extractImages,
    bool? includeFootnotes,
    bool? includeEndnotes,
    bool? includeComments,
    bool? includeHeadersFooters,
    bool? preserveEmptyParagraphs,
    bool? trimTrailingWhitespace,
    OrderedListNumbering? orderedListNumbering,
    List<String>? bulletMarkers,
    int? listIndent,
    bool? tightLists,
    LineBreakStyle? lineBreakStyle,
    String? codeBlockStyleName,
    List<String>? monospaceFonts,
    bool? treatShadedRunsAsCode,
    int? maxImageWidth,
    ImageSizeMode? imageSizeMode,
    Map<String, ParagraphStyleOverride>? paragraphStyleOverrides,
    bool? strict,
    bool? emitWarningsAsHtmlComments,
    DocxToMarkdownHooks? hooks,
  }) {
    return DocxToMarkdownConfig(
      flavor: flavor ?? this.flavor,
      tableMode: tableMode ?? this.tableMode,
      underlineMode: underlineMode ?? this.underlineMode,
      unknownElementPolicy: unknownElementPolicy ?? this.unknownElementPolicy,
      extractImages: extractImages ?? this.extractImages,
      includeFootnotes: includeFootnotes ?? this.includeFootnotes,
      includeEndnotes: includeEndnotes ?? this.includeEndnotes,
      includeComments: includeComments ?? this.includeComments,
      includeHeadersFooters:
          includeHeadersFooters ?? this.includeHeadersFooters,
      preserveEmptyParagraphs:
          preserveEmptyParagraphs ?? this.preserveEmptyParagraphs,
      trimTrailingWhitespace:
          trimTrailingWhitespace ?? this.trimTrailingWhitespace,
      orderedListNumbering: orderedListNumbering ?? this.orderedListNumbering,
      bulletMarkers: bulletMarkers ?? this.bulletMarkers,
      listIndent: listIndent ?? this.listIndent,
      tightLists: tightLists ?? this.tightLists,
      lineBreakStyle: lineBreakStyle ?? this.lineBreakStyle,
      codeBlockStyleName: codeBlockStyleName ?? this.codeBlockStyleName,
      monospaceFonts: monospaceFonts ?? this.monospaceFonts,
      treatShadedRunsAsCode:
          treatShadedRunsAsCode ?? this.treatShadedRunsAsCode,
      maxImageWidth: maxImageWidth ?? this.maxImageWidth,
      imageSizeMode: imageSizeMode ?? this.imageSizeMode,
      paragraphStyleOverrides:
          paragraphStyleOverrides ?? this.paragraphStyleOverrides,
      strict: strict ?? this.strict,
      emitWarningsAsHtmlComments:
          emitWarningsAsHtmlComments ?? this.emitWarningsAsHtmlComments,
      hooks: hooks ?? this.hooks,
    );
  }

  @override
  String toString() {
    return 'DocxToMarkdownConfig('
        'flavor: $flavor, '
        'tableMode: $tableMode, '
        'underlineMode: $underlineMode, '
        'unknownElementPolicy: $unknownElementPolicy, '
        'extractImages: $extractImages, '
        'includeFootnotes: $includeFootnotes, '
        'includeEndnotes: $includeEndnotes, '
        'includeComments: $includeComments, '
        'includeHeadersFooters: $includeHeadersFooters, '
        'preserveEmptyParagraphs: $preserveEmptyParagraphs, '
        'trimTrailingWhitespace: $trimTrailingWhitespace, '
        'orderedListNumbering: $orderedListNumbering, '
        'bulletMarkers: $bulletMarkers, '
        'listIndent: $listIndent, '
        'tightLists: $tightLists, '
        'lineBreakStyle: $lineBreakStyle, '
        'codeBlockStyleName: $codeBlockStyleName, '
        'monospaceFonts: $monospaceFonts, '
        'treatShadedRunsAsCode: $treatShadedRunsAsCode, '
        'maxImageWidth: $maxImageWidth, '
        'imageSizeMode: $imageSizeMode, '
        'paragraphStyleOverrides: ${paragraphStyleOverrides.length}, '
        'strict: $strict, '
        'emitWarningsAsHtmlComments: $emitWarningsAsHtmlComments'
        ')';
  }
}
