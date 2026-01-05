// ir.dart
//
// Production-grade Intermediate Representation (IR) for DOCX -> Markdown.
//
// Design goals:
// - Pure data model (no XML, no Markdown concerns)
// - Immutable by default (defensive copies + unmodifiable views)
// - Extensible enough for “Pandoc-level” fidelity (tables, lists, notes, raw HTML)
// - Value semantics (deep == / hashCode) for reliable tests & caching
//
// Note: Node `meta` is intentionally *non-semantic* and does NOT affect equality.
// This keeps golden tests stable even if you change location tracking.
//
// Requires: Dart 3+ (sealed classes)

import 'package:meta/meta.dart';

// ---------------------------------------------------------------------------
// Diagnostics / Source info
// ---------------------------------------------------------------------------

/// Severity levels for diagnostic messages emitted during parsing.
///
/// Used by [DocWarning] to indicate how serious an issue is.
enum DocSeverity {
  /// Informational message; no action needed.
  info,

  /// Non-fatal issue; output may be degraded but conversion continues.
  warning,

  /// Serious problem; may result in missing or incorrect content.
  error,
}

/// Points to a location within the DOCX package for debugging and warnings.
///
/// [SourceLocation] helps identify where in the source document an issue
/// occurred. Use it in error messages and when investigating conversion
/// problems.
///
/// ### Format
///
/// The [part] identifies the OOXML file (e.g., `"word/document.xml"`).
/// The [path] is an XPath-like string within that file (e.g., `"body/p[12]/r[3]"`).
///
/// See also:
/// - [DocWarning.location] where this is used
/// - [NodeMeta.location] for attaching locations to IR nodes
@immutable
final class SourceLocation {
  /// Creates a source location from a part name and path within that part.
  const SourceLocation({required this.part, required this.path});

  /// The OOXML part (file within the ZIP), e.g., `"word/document.xml"`.
  final String part;

  /// XPath-like location within the part, e.g., `"body/p[12]/r[3]"`.
  final String path;

  @override
  String toString() => '$part:$path';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SourceLocation && other.part == part && other.path == path);

  @override
  int get hashCode => Object.hash(part, path);
}

/// A non-fatal issue detected during DOCX parsing or conversion.
///
/// Warnings indicate that the output may be degraded but conversion can
/// continue. Common causes include:
///
/// - Unsupported OOXML constructs (SmartArt, charts, embedded objects)
/// - Complex tables downgraded to HTML due to merged cells
/// - Unresolved field codes or tracked changes
///
/// ### Handling Warnings
///
/// Configure [DocxToMarkdownHooks.onWarning] to collect or log warnings:
///
/// ```dart
/// final warnings = <DocWarning>[];
/// final config = DocxToMarkdownConfig(
///   hooks: DocxToMarkdownHooks(
///     onWarning: (w, ctx) => warnings.add(w),
///   ),
/// );
/// ```
///
/// ### Common Warning Codes
///
/// - `"unsupported.inline"` — inline element not converted
/// - `"unsupported.block"` — block element not converted
/// - `"table.mergedCells"` — table has merged cells, may lose structure
/// - `"fieldcode.unresolved"` — Word field code could not be resolved
///
/// See also:
/// - [Document.warnings] where warnings are collected
/// - [DocxToMarkdownHooks.onWarning] for real-time handling
@immutable
final class DocWarning {
  /// Creates a warning with the given code, message, and location.
  const DocWarning({
    required this.code,
    required this.message,
    required this.location,
    this.severity = DocSeverity.warning,
  });

  /// Machine-readable identifier for the warning type.
  ///
  /// Use this for programmatic filtering. Examples:
  /// `"unsupported.inline"`, `"table.mergedCells"`, `"fieldcode.unresolved"`.
  final String code;

  /// Human-readable description of the issue.
  final String message;

  /// Where in the source document the issue occurred.
  final SourceLocation location;

  /// How serious the issue is. Defaults to [DocSeverity.warning].
  final DocSeverity severity;

  @override
  String toString() => 'DocWarning($severity, $code, $location, $message)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DocWarning &&
          other.code == code &&
          other.message == message &&
          other.location == location &&
          other.severity == severity);

  @override
  int get hashCode => Object.hash(code, message, location, severity);
}

/// Debug metadata attached to IR nodes.
///
/// [NodeMeta] carries source location and arbitrary attributes for debugging,
/// hooks, and auditing. It is intentionally **excluded from equality** so that
/// two nodes with identical semantic content compare equal regardless of their
/// source locations.
///
/// ### When to Use
///
/// - Access [location] to find where a node came from in the source DOCX.
/// - Access [attributes] for Word-specific details like style IDs or list info.
/// - In hooks, use `node.meta` to make context-aware decisions.
///
/// ### Memory Considerations
///
/// Keep attributes minimal. Every node carries a reference to its meta, so
/// large attribute maps can bloat memory on big documents.
///
/// See also:
/// - [DocNode.meta] where this is attached
/// - [SourceLocation] for the location format
@immutable
final class NodeMeta {
  /// Creates node metadata with optional location and attributes.
  NodeMeta({this.location, Map<String, Object?> attributes = const {}})
    : attributes = Map.unmodifiable(attributes);

  /// Where in the source DOCX this node originated.
  ///
  /// May be `null` for synthesized nodes (e.g., nodes created by hooks).
  final SourceLocation? location;

  /// Arbitrary attributes from the source document.
  ///
  /// Common keys include:
  /// - `"styleId"` — Word paragraph style ID
  /// - `"styleName"` — Human-readable style name
  /// - `"numId"` — Numbering definition ID for lists
  /// - `"ilvl"` — List indentation level
  /// - `"rid"` — Relationship ID for links/images
  final Map<String, Object?> attributes;

  @override
  String toString() => 'NodeMeta(location: $location, attributes: $attributes)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NodeMeta &&
          other.location == location &&
          _deepEquals(other.attributes, attributes));

  @override
  int get hashCode => Object.hash(location, _deepHash(attributes));
}

// ---------------------------------------------------------------------------
// Core node hierarchy
// ---------------------------------------------------------------------------

/// Base class for all IR nodes.
///
/// [DocNode] provides value semantics: two nodes are equal if they have the
/// same type and [props]. The [meta] field is intentionally excluded from
/// equality to allow location-independent comparisons.
///
/// This is a sealed class. Use the concrete subclasses:
/// - [Block] for block-level content (paragraphs, headings, lists, tables)
/// - [Inline] for inline content (text, links, formatting spans)
/// - [Document] for the root document
@immutable
sealed class DocNode {
  /// Creates a node with optional debug metadata.
  const DocNode({this.meta});

  /// Debug metadata (source location, attributes).
  ///
  /// Excluded from [==] and [hashCode] so nodes with identical content
  /// compare equal regardless of where they came from.
  final NodeMeta? meta;

  /// Semantic properties used for equality and hashing.
  ///
  /// Subclasses must return all fields that define the node's content.
  /// The [meta] field is intentionally excluded.
  List<Object?> get props;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other.runtimeType == runtimeType &&
          other is DocNode &&
          _deepEquals(other.props, props));

  @override
  int get hashCode => Object.hash(runtimeType, _deepHash(props));

  @override
  String toString() => runtimeType.toString();
}

/// A block-level IR node (paragraph, heading, list, table, etc.).
///
/// Blocks represent structural document elements that stack vertically.
/// Use pattern matching on the sealed subclasses to handle each block type:
///
/// ```dart
/// switch (block) {
///   case ParagraphBlock(): // ...
///   case HeadingBlock(): // ...
///   case ListBlock(): // ...
///   // etc.
/// }
/// ```
///
/// See also:
/// - [Inline] for inline content within blocks
/// - [Document.blocks] where blocks are collected
@immutable
sealed class Block extends DocNode {
  /// Creates a block with optional debug metadata.
  const Block({super.meta});
}

/// An inline IR node (text, link, formatting span, etc.).
///
/// Inlines represent content that flows horizontally within a line.
/// Use pattern matching on the sealed subclasses to handle each inline type:
///
/// ```dart
/// switch (inline) {
///   case TextInline(): // ...
///   case StrongInline(): // ...
///   case LinkInline(): // ...
///   // etc.
/// }
/// ```
///
/// See also:
/// - [Block] for block-level containers
/// - [InlinePlainText.toPlainText] for extracting raw text
@immutable
sealed class Inline extends DocNode {
  /// Creates an inline with optional debug metadata.
  const Inline({super.meta});
}

// ---------------------------------------------------------------------------
// Document root + Notes
// ---------------------------------------------------------------------------

/// The root IR node representing a complete DOCX document.
///
/// [Document] contains all block-level content ([blocks]), footnote definitions
/// ([footnotes]), and any warnings generated during parsing ([warnings]).
///
/// ### Usage
///
/// After conversion, iterate over [blocks] to process the document content.
/// Look up footnotes by ID when you encounter a [FootnoteRefInline].
///
/// ```dart
/// final doc = parser.parseMainDocument();
/// for (final block in doc.blocks) {
///   // Process each block...
/// }
/// for (final warning in doc.warnings) {
///   print('Warning: ${warning.message}');
/// }
/// ```
///
/// ### Immutability
///
/// [Document] is immutable. Use [copyWith] to create a modified copy.
///
/// See also:
/// - [DocxConverter.convert] which produces Markdown from a Document
/// - [Block] for the block types that can appear in [blocks]
@immutable
final class Document extends DocNode {
  /// Creates a document with the given blocks, footnotes, and warnings.
  Document({
    required Iterable<Block> blocks,
    Map<String, FootnoteDefinition> footnotes = const {},
    Iterable<DocWarning> warnings = const [],
    super.meta,
  }) : blocks = _freezeList(blocks),
       footnotes = Map.unmodifiable(footnotes),
       warnings = _freezeList(warnings);

  /// The block-level content of the document in order.
  ///
  /// Includes paragraphs, headings, lists, tables, and other block elements.
  final List<Block> blocks;

  /// Footnote definitions keyed by their ID.
  ///
  /// IDs are whatever the DOCX provides (often numeric strings like `"1"`, `"2"`).
  /// Look up definitions when rendering [FootnoteRefInline] nodes.
  final Map<String, FootnoteDefinition> footnotes;

  /// Warnings generated during parsing.
  ///
  /// These indicate non-fatal issues like unsupported elements or complex
  /// tables that were downgraded. Check after conversion to assess fidelity.
  final List<DocWarning> warnings;

  @override
  List<Object?> get props => <Object?>[blocks, footnotes];

  /// Creates a copy with the given fields replaced.
  Document copyWith({
    Iterable<Block>? blocks,
    Map<String, FootnoteDefinition>? footnotes,
    Iterable<DocWarning>? warnings,
    NodeMeta? meta,
  }) {
    return Document(
      blocks: blocks ?? this.blocks,
      footnotes: footnotes ?? this.footnotes,
      warnings: warnings ?? this.warnings,
      meta: meta ?? this.meta,
    );
  }

  @override
  String toString() =>
      'Document(blocks: ${blocks.length}, footnotes: ${footnotes.length}, warnings: ${warnings.length})';
}

/// The content of a footnote or endnote.
///
/// [FootnoteDefinition] holds the blocks that make up a note's content.
/// Notes are stored in [Document.footnotes] and referenced by [FootnoteRefInline].
///
/// See also:
/// - [FootnoteRefInline] which references these definitions
/// - [Document.footnotes] where definitions are stored
@immutable
final class FootnoteDefinition extends DocNode {
  /// Creates a footnote definition with the given ID and content blocks.
  FootnoteDefinition({
    required this.id,
    required Iterable<Block> blocks,
    super.meta,
  }) : blocks = _freezeList(blocks);

  /// The footnote ID (matches [FootnoteRefInline.id]).
  ///
  /// This is the DOCX-provided ID, typically a numeric string.
  final String id;

  /// The block content of the footnote.
  final List<Block> blocks;

  @override
  List<Object?> get props => <Object?>[id, blocks];

  @override
  String toString() => 'FootnoteDefinition(id: $id, blocks: ${blocks.length})';
}

// ---------------------------------------------------------------------------
// Blocks
// ---------------------------------------------------------------------------

/// A paragraph containing inline content.
///
/// [ParagraphBlock] is the most common block type. It contains a sequence of
/// [Inline] nodes (text, links, formatting spans) that form a paragraph.
///
/// See also:
/// - [HeadingBlock] for headings
/// - [DocxToMarkdownConfig.preserveEmptyParagraphs] for empty paragraph handling
@immutable
final class ParagraphBlock extends Block {
  /// Creates a paragraph with the given inline content.
  ParagraphBlock(Iterable<Inline> inlines, {super.meta})
    : inlines = _freezeList(inlines);

  /// The inline content of the paragraph.
  final List<Inline> inlines;

  /// Whether this paragraph has no visible content.
  ///
  /// Returns `true` if [inlines] is empty or contains only whitespace.
  bool get isEmpty => inlines.isEmpty || inlines.toPlainText().trim().isEmpty;

  @override
  List<Object?> get props => <Object?>[inlines];

  @override
  String toString() => 'ParagraphBlock(inlines: ${inlines.length})';
}

/// A heading with a level and inline content.
///
/// [HeadingBlock] represents headings from Word's built-in styles (Heading 1–6)
/// or custom heading styles mapped via [ParagraphStyleOverride].
///
/// ### Level Handling
///
/// Word supports heading levels beyond 6, but Markdown only supports 1–6.
/// The renderer clamps levels to 6 for Markdown output; the IR preserves
/// the original level for other uses.
///
/// See also:
/// - [ParagraphStyleOverride.headingLevel] for mapping custom styles to headings
@immutable
final class HeadingBlock extends Block {
  /// Creates a heading with the given level and inline content.
  ///
  /// The [level] is clamped to a minimum of 1.
  HeadingBlock({
    required int level,
    required Iterable<Inline> inlines,
    super.meta,
  }) : level = level < 1 ? 1 : level,
       inlines = _freezeList(inlines);

  /// The heading level (1 = most important).
  ///
  /// May exceed 6 if the source Word document uses deep heading styles.
  /// The renderer clamps to 6 for Markdown output.
  final int level;

  /// The inline content of the heading.
  final List<Inline> inlines;

  @override
  List<Object?> get props => <Object?>[level, inlines];

  @override
  String toString() =>
      'HeadingBlock(level: $level, inlines: ${inlines.length})';
}

/// A fenced code block with optional language hint.
///
/// [CodeBlock] represents preformatted code. It is produced from paragraphs
/// with the "Code" style, monospace font runs, or custom style mappings.
///
/// ### Markdown Output
///
/// Renders as a fenced code block:
/// ~~~markdown
/// ```dart
/// void main() => print('Hello');
/// ```
/// ~~~
///
/// See also:
/// - [DocxToMarkdownConfig.codeBlockStyleName] for style-based detection
/// - [ParagraphStyleOverride.isCodeBlock] for custom style mapping
/// - [CodeInline] for inline code spans
@immutable
final class CodeBlock extends Block {
  /// Creates a code block with the given text and optional language.
  const CodeBlock({required this.text, this.language, super.meta});

  /// The code content (whitespace and newlines preserved).
  final String text;

  /// Optional language identifier for syntax highlighting (e.g., `"dart"`, `"python"`).
  ///
  /// When present, the renderer includes it in the fence: `` ```dart ``.
  final String? language;

  @override
  List<Object?> get props => <Object?>[text, language];

  @override
  String toString() => 'CodeBlock(lang: $language, chars: ${text.length})';
}

/// A block quote containing nested blocks.
///
/// [QuoteBlock] represents quoted content, typically rendered with `>` prefixes
/// in Markdown. It can contain any block types, including nested quotes.
///
/// See also:
/// - [ParagraphStyleOverride.isQuote] for mapping styles to quotes
@immutable
final class QuoteBlock extends Block {
  /// Creates a quote block with the given nested content.
  QuoteBlock(Iterable<Block> blocks, {super.meta})
    : blocks = _freezeList(blocks);

  /// The content blocks inside the quote.
  final List<Block> blocks;

  @override
  List<Object?> get props => <Object?>[blocks];

  @override
  String toString() => 'QuoteBlock(blocks: ${blocks.length})';
}

/// Controls spacing between list items.
///
/// Used by [ListBlock.tightness] to determine whether to insert blank lines
/// between items during rendering.
enum ListTightness {
  /// No blank lines between items.
  tight,

  /// Blank lines between items.
  loose,

  /// Let the renderer decide based on item content.
  auto,
}

/// A list (ordered or unordered) containing list items.
///
/// [ListBlock] represents both bullet and numbered lists. Nested lists are
/// represented as [ListBlock] nodes inside [ListItem.blocks].
///
/// ### Nesting
///
/// Word lists with multiple indentation levels become nested [ListBlock]s:
///
/// ```
/// - Item 1
///   - Nested item
/// - Item 2
/// ```
///
/// See also:
/// - [ListItem] for individual items
/// - [DocxToMarkdownConfig.orderedListNumbering] for numbering options
/// - [DocxToMarkdownConfig.bulletMarkers] for bullet characters
@immutable
final class ListBlock extends Block {
  /// Creates a list with the given type, items, and optional start number.
  ListBlock({
    required this.ordered,
    required Iterable<ListItem> items,
    this.start = 1,
    this.tightness = ListTightness.auto,
    super.meta,
  }) : assert(start >= 1),
       items = _freezeList(items);

  /// Whether this is an ordered (numbered) list.
  ///
  /// When `true`, items are numbered. When `false`, items use bullet markers.
  final bool ordered;

  /// The starting number for ordered lists.
  ///
  /// Defaults to 1. DOCX may specify non-1 start values (e.g., continuing a
  /// previous list). See [DocxToMarkdownConfig.orderedListNumbering] for how
  /// this is rendered.
  final int start;

  /// How tightly to render items.
  ///
  /// See [ListTightness] for options.
  final ListTightness tightness;

  /// The items in this list.
  final List<ListItem> items;

  @override
  List<Object?> get props => <Object?>[ordered, start, tightness, items];

  @override
  String toString() =>
      'ListBlock(ordered: $ordered, start: $start, items: ${items.length}, tightness: $tightness)';
}

/// A single item in a list.
///
/// [ListItem] contains block content (typically a [ParagraphBlock]) and may
/// include nested [ListBlock]s for sublists.
///
/// See also:
/// - [ListBlock] the container for list items
@immutable
final class ListItem extends DocNode {
  /// Creates a list item with the given content blocks.
  ListItem({required Iterable<Block> blocks, super.meta})
    : blocks = _freezeList(blocks);

  /// The content of this list item.
  ///
  /// Usually contains a [ParagraphBlock]. May contain additional blocks
  /// including nested [ListBlock]s.
  final List<Block> blocks;

  @override
  List<Object?> get props => <Object?>[blocks];

  @override
  String toString() => 'ListItem(blocks: ${blocks.length})';
}

/// A table with rows, cells, and optional column alignments.
///
/// [TableBlock] represents DOCX tables. Simple tables render as Markdown pipe
/// tables; complex tables (with merged cells) may render as HTML depending
/// on [DocxToMarkdownConfig.tableMode].
///
/// ### Complexity Detection
///
/// Use [isComplex] to check if the table has merged cells or irregular
/// structure. Complex tables cannot be accurately represented in Markdown
/// table syntax.
///
/// See also:
/// - [TableGrid] for the row/cell structure
/// - [DocxToMarkdownConfig.tableMode] for rendering options
@immutable
final class TableBlock extends Block {
  /// Creates a table with the given grid and optional column alignments.
  TableBlock({
    required this.grid,
    List<TableAlign> alignments = const [],
    super.meta,
  }) : alignments = _freezeList(alignments);

  /// The row and cell structure of the table.
  final TableGrid grid;

  /// Column alignments for Markdown table rendering.
  ///
  /// If shorter than [grid.columnCount], remaining columns use [TableAlign.auto].
  final List<TableAlign> alignments;

  /// Whether this table has merged cells or irregular structure.
  ///
  /// Complex tables may lose formatting when rendered as Markdown.
  bool get isComplex => grid.isComplex;

  @override
  List<Object?> get props => <Object?>[grid, alignments];

  @override
  String toString() =>
      'TableBlock(rows: ${grid.rows.length}, cols: ${grid.columnCount}, alignments: ${alignments.length}, complex: $isComplex)';
}

/// A horizontal rule (thematic break).
///
/// Renders as `---` or similar in Markdown.
@immutable
final class HorizontalRuleBlock extends Block {
  /// Creates a horizontal rule.
  const HorizontalRuleBlock({super.meta});

  @override
  List<Object?> get props => const <Object?>[];

  @override
  String toString() => 'HorizontalRuleBlock()';
}

/// Raw HTML to be passed through to output.
///
/// [HtmlBlock] is used for content that cannot be represented in Markdown,
/// such as complex tables or OOXML elements kept as HTML per
/// [UnknownElementPolicy.keepHtml].
@immutable
final class HtmlBlock extends Block {
  /// Creates an HTML block with the given content.
  const HtmlBlock(this.html, {super.meta});

  /// The raw HTML content.
  final String html;

  @override
  List<Object?> get props => <Object?>[html];

  @override
  String toString() => 'HtmlBlock(chars: ${html.length})';
}

/// A math equation block.
///
/// [MathBlock] represents Office Math (OMML) equations. If
/// [DocxToMarkdownHooks.ommlToLatex] is configured, the content is LaTeX;
/// otherwise it's extracted text from `<m:t>` elements.
///
/// See also:
/// - [DocxToMarkdownHooks.ommlToLatex] for LaTeX conversion
@immutable
final class MathBlock extends Block {
  /// Creates a math block with the given content.
  const MathBlock(this.latexOrText, {this.displayMode = true, super.meta});

  /// The math content (LaTeX if converted, otherwise raw text).
  final String latexOrText;

  /// Whether to render as display math (centered, block) vs inline.
  ///
  /// Display mode typically uses `$$...$$` or `\[...\]` syntax.
  final bool displayMode;

  @override
  List<Object?> get props => <Object?>[latexOrText, displayMode];

  @override
  String toString() =>
      'MathBlock(display: $displayMode, chars: ${latexOrText.length})';
}

/// A standalone image.
///
/// [ImageBlock] represents images that appear as their own block rather than
/// inline within a paragraph. Common in Word documents where images are
/// inserted on their own lines.
///
/// See also:
/// - [ImageInline] for inline images
/// - [DocxToMarkdownConfig.extractImages] for image extraction
/// - [DocxToMarkdownHooks.rewriteImageTarget] for URL rewriting
@immutable
final class ImageBlock extends Block {
  /// Creates an image block with the given source, alt text, and optional title.
  const ImageBlock({
    required this.src,
    required this.alt,
    this.title,
    super.meta,
  });

  /// The image source path or URL.
  ///
  /// May be a relative path to an extracted file or a data URI.
  final String src;

  /// Alternative text for accessibility.
  final String alt;

  /// Optional title (appears on hover in some renderers).
  final String? title;

  @override
  List<Object?> get props => <Object?>[src, alt, title];

  @override
  String toString() => 'ImageBlock(src: $src, alt: $alt)';
}

// ---------------------------------------------------------------------------
// Inlines
// ---------------------------------------------------------------------------

/// Plain text content.
///
/// [TextInline] is the most basic inline node, containing a string of text
/// with no formatting.
@immutable
final class TextInline extends Inline {
  /// Creates a text node with the given content.
  const TextInline(this.text, {super.meta});

  /// The text content.
  final String text;

  @override
  List<Object?> get props => <Object?>[text];

  @override
  String toString() => 'TextInline(${text.length} chars)';
}

/// A soft line break (typically rendered as a space or ignored).
///
/// [SoftBreakInline] represents a line break in the source that doesn't
/// create a visible line break in output.
@immutable
final class SoftBreakInline extends Inline {
  /// Creates a soft break.
  const SoftBreakInline({super.meta});

  @override
  List<Object?> get props => const <Object?>[];

  @override
  String toString() => 'SoftBreakInline()';
}

/// A hard line break within a paragraph.
///
/// [LineBreakInline] represents DOCX `<w:br>` elements. The rendering
/// depends on [DocxToMarkdownConfig.lineBreakStyle].
///
/// See also:
/// - [LineBreakStyle] for rendering options
@immutable
final class LineBreakInline extends Inline {
  /// Creates a hard line break.
  const LineBreakInline({super.meta});

  @override
  List<Object?> get props => const <Object?>[];

  @override
  String toString() => 'LineBreakInline()';
}

/// Italic/emphasized text.
///
/// Renders as `*text*` or `_text_` in Markdown.
@immutable
final class EmphInline extends Inline {
  /// Creates an emphasis span with the given children.
  EmphInline(Iterable<Inline> children, {super.meta})
    : children = _freezeList(children);

  /// The emphasized content.
  final List<Inline> children;

  @override
  List<Object?> get props => <Object?>[children];

  @override
  String toString() => 'EmphInline(children: ${children.length})';
}

/// Bold/strong text.
///
/// Renders as `**text**` or `__text__` in Markdown.
@immutable
final class StrongInline extends Inline {
  /// Creates a strong span with the given children.
  StrongInline(Iterable<Inline> children, {super.meta})
    : children = _freezeList(children);

  /// The bold content.
  final List<Inline> children;

  @override
  List<Object?> get props => <Object?>[children];

  @override
  String toString() => 'StrongInline(children: ${children.length})';
}

/// Strikethrough text.
///
/// Renders as `~~text~~` in GFM. Not supported in strict CommonMark.
@immutable
final class StrikeInline extends Inline {
  /// Creates a strikethrough span with the given children.
  StrikeInline(Iterable<Inline> children, {super.meta})
    : children = _freezeList(children);

  /// The struck-through content.
  final List<Inline> children;

  @override
  List<Object?> get props => <Object?>[children];

  @override
  String toString() => 'StrikeInline(children: ${children.length})';
}

/// Underlined text.
///
/// Markdown has no standard underline syntax. Rendering depends on
/// [DocxToMarkdownConfig.underlineMode].
///
/// See also:
/// - [UnderlineMode] for rendering options
@immutable
final class UnderlineInline extends Inline {
  /// Creates an underline span with the given children.
  UnderlineInline(Iterable<Inline> children, {super.meta})
    : children = _freezeList(children);

  /// The underlined content.
  final List<Inline> children;

  @override
  List<Object?> get props => <Object?>[children];

  @override
  String toString() => 'UnderlineInline(children: ${children.length})';
}

/// Inline code (monospace text).
///
/// Renders as `` `code` `` in Markdown.
///
/// See also:
/// - [CodeBlock] for fenced code blocks
/// - [DocxToMarkdownConfig.monospaceFonts] for font-based detection
@immutable
final class CodeInline extends Inline {
  /// Creates inline code with the given text.
  const CodeInline(this.text, {super.meta});

  /// The code content.
  final String text;

  @override
  List<Object?> get props => <Object?>[text];

  @override
  String toString() => 'CodeInline(${text.length} chars)';
}

/// A hyperlink with text content.
///
/// Renders as `[text](url)` or `[text](url "title")` in Markdown.
///
/// See also:
/// - [DocxToMarkdownHooks.rewriteLinkTarget] for URL rewriting
@immutable
final class LinkInline extends Inline {
  /// Creates a link with the given URL, children, and optional title.
  LinkInline({
    required this.url,
    required Iterable<Inline> children,
    this.title,
    super.meta,
  }) : children = _freezeList(children);

  /// The link destination URL.
  final String url;

  /// Optional title (appears on hover in some renderers).
  final String? title;

  /// The link text content.
  final List<Inline> children;

  @override
  List<Object?> get props => <Object?>[url, title, children];

  @override
  String toString() => 'LinkInline(url: $url, children: ${children.length})';
}

/// An inline image.
///
/// Renders as `![alt](src)` in Markdown.
///
/// See also:
/// - [ImageBlock] for standalone images
/// - [DocxToMarkdownHooks.rewriteImageTarget] for URL rewriting
/// - [DocxToMarkdownConfig.imageSizeMode] for size syntax
@immutable
final class ImageInline extends Inline {
  /// Creates an inline image with the given source, alt text, and optional title.
  const ImageInline({
    required this.src,
    required this.alt,
    this.title,
    super.meta,
  });

  /// The image source path or URL.
  final String src;

  /// Alternative text for accessibility.
  final String alt;

  /// Optional title (appears on hover in some renderers).
  final String? title;

  @override
  List<Object?> get props => <Object?>[src, alt, title];

  @override
  String toString() => 'ImageInline(src: $src, alt: $alt)';
}

/// A reference to a footnote definition.
///
/// [FootnoteRefInline] marks where a footnote is referenced in text.
/// The actual content is in [Document.footnotes] keyed by [id].
///
/// Renders as `[^1]` or similar in Markdown footnote syntax.
///
/// See also:
/// - [FootnoteDefinition] for the footnote content
/// - [Document.footnotes] where definitions are stored
@immutable
final class FootnoteRefInline extends Inline {
  /// Creates a footnote reference with the given ID.
  const FootnoteRefInline(this.id, {super.meta});

  /// The footnote ID (matches [FootnoteDefinition.id]).
  final String id;

  @override
  List<Object?> get props => <Object?>[id];

  @override
  String toString() => 'FootnoteRefInline(id: $id)';
}

/// Superscript text.
///
/// Markdown has no standard superscript syntax. Typically renders as
/// `<sup>text</sup>` HTML.
@immutable
final class SupInline extends Inline {
  /// Creates a superscript span with the given children.
  SupInline(Iterable<Inline> children, {super.meta})
    : children = _freezeList(children);

  /// The superscript content.
  final List<Inline> children;

  @override
  List<Object?> get props => <Object?>[children];

  @override
  String toString() => 'SupInline(children: ${children.length})';
}

/// Subscript text.
///
/// Markdown has no standard subscript syntax. Typically renders as
/// `<sub>text</sub>` HTML.
@immutable
final class SubInline extends Inline {
  /// Creates a subscript span with the given children.
  SubInline(Iterable<Inline> children, {super.meta})
    : children = _freezeList(children);

  /// The subscript content.
  final List<Inline> children;

  @override
  List<Object?> get props => <Object?>[children];

  @override
  String toString() => 'SubInline(children: ${children.length})';
}

/// Raw inline HTML to be passed through to output.
///
/// Used for content that cannot be represented in Markdown syntax.
@immutable
final class HtmlInline extends Inline {
  /// Creates an inline HTML node with the given content.
  const HtmlInline(this.html, {super.meta});

  /// The raw HTML content.
  final String html;

  @override
  List<Object?> get props => <Object?>[html];

  @override
  String toString() => 'HtmlInline(chars: ${html.length})';
}

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

/// The row and cell structure of a table.
///
/// [TableGrid] holds the 2D structure of a table. Use [isComplex] to check
/// if the table has merged cells that may not render correctly in Markdown.
///
/// See also:
/// - [TableBlock] which wraps this with alignment info
@immutable
final class TableGrid extends DocNode {
  /// Creates a table grid with the given rows.
  TableGrid({required Iterable<TableRow> rows, super.meta})
    : rows = _freezeList(rows);

  /// The rows in the table.
  final List<TableRow> rows;

  /// The number of rows in the table.
  int get rowCount => rows.length;

  /// The maximum number of columns in any row.
  int get columnCount => rows.isEmpty
      ? 0
      : rows.map((r) => r.cells.length).reduce((a, b) => a > b ? a : b);

  /// Whether this table has merged cells or irregular structure.
  ///
  /// Returns `true` if any cell has [TableCell.colSpan] or [TableCell.rowSpan]
  /// greater than 1, or if rows have different numbers of cells.
  bool get isComplex {
    for (final row in rows) {
      if (row.cells.any((c) => c.colSpan != 1 || c.rowSpan != 1)) return true;
    }
    final cols = columnCount;
    return rows.any((r) => r.cells.length != cols);
  }

  @override
  List<Object?> get props => <Object?>[rows];

  @override
  String toString() => 'TableGrid(rows: $rowCount, cols: $columnCount)';
}

/// A single row in a table.
///
/// See also:
/// - [TableGrid] which contains rows
/// - [TableCell] for individual cells
@immutable
final class TableRow extends DocNode {
  /// Creates a table row with the given cells.
  TableRow({
    required Iterable<TableCell> cells,
    this.isHeader = false,
    super.meta,
  }) : cells = _freezeList(cells);

  /// The cells in this row.
  final List<TableCell> cells;

  /// Whether this is a header row.
  ///
  /// When `true`, the renderer may output a separator line after this row
  /// for Markdown table syntax.
  final bool isHeader;

  @override
  List<Object?> get props => <Object?>[isHeader, cells];

  @override
  String toString() => 'TableRow(header: $isHeader, cells: ${cells.length})';
}

/// A single cell in a table row.
///
/// See also:
/// - [TableRow] which contains cells
@immutable
final class TableCell extends DocNode {
  /// Creates a table cell with the given content and optional span.
  TableCell({
    required Iterable<Block> blocks,
    this.colSpan = 1,
    this.rowSpan = 1,
    this.isHeader = false,
    super.meta,
  }) : assert(colSpan >= 1),
       assert(rowSpan >= 1),
       blocks = _freezeList(blocks);

  /// The content blocks inside this cell.
  final List<Block> blocks;

  /// How many columns this cell spans (default: 1).
  ///
  /// Values greater than 1 indicate horizontally merged cells.
  final int colSpan;

  /// How many rows this cell spans (default: 1).
  ///
  /// Values greater than 1 indicate vertically merged cells.
  final int rowSpan;

  /// Whether this is a header cell (`<th>` vs `<td>`).
  final bool isHeader;

  @override
  List<Object?> get props => <Object?>[colSpan, rowSpan, isHeader, blocks];

  @override
  String toString() =>
      'TableCell(colSpan: $colSpan, rowSpan: $rowSpan, header: $isHeader, blocks: ${blocks.length})';
}

/// Column alignment for Markdown tables.
///
/// See also:
/// - [TableBlock.alignments] where this is used
enum TableAlign {
  /// Left-aligned (`:---`).
  left,

  /// Center-aligned (`:---:`).
  center,

  /// Right-aligned (`---:`).
  right,

  /// Let the renderer decide (typically left).
  auto,
}

// ---------------------------------------------------------------------------
// Convenience helpers
// ---------------------------------------------------------------------------

/// Extension for extracting plain text from inline nodes.
extension InlinePlainText on Iterable<Inline> {
  /// Extracts plain text content from a sequence of inline nodes.
  ///
  /// Recursively walks through formatting spans and extracts text, discarding
  /// all markup. Useful for:
  ///
  /// - Generating alt text
  /// - Debugging output
  /// - Checking if content is empty
  ///
  /// ### Behavior
  ///
  /// - Text and code: keeps content
  /// - Formatting spans: extracts children
  /// - Links: keeps link text (discards URL)
  /// - Images: keeps alt text
  /// - Footnote refs: outputs `^`
  /// - Line breaks: outputs `\n`
  String toPlainText() {
    final b = StringBuffer();
    void walk(Inline node) {
      switch (node) {
        case TextInline():
          b.write(node.text);
          return;
        case CodeInline():
          b.write(node.text);
          return;
        case SoftBreakInline():
          b.write('\n');
          return;
        case LineBreakInline():
          b.write('\n');
          return;
        case EmphInline():
          node.children.forEach(walk);
          return;
        case StrongInline():
          node.children.forEach(walk);
          return;
        case StrikeInline():
          node.children.forEach(walk);
          return;
        case UnderlineInline():
          node.children.forEach(walk);
          return;
        case SupInline():
          node.children.forEach(walk);
          return;
        case SubInline():
          node.children.forEach(walk);
          return;
        case LinkInline():
          node.children.forEach(walk);
          return;
        case ImageInline():
          b.write(node.alt);
          return;
        case FootnoteRefInline():
          // often omitted in plain text; keep a caret marker
          b.write('^');
          return;
        case HtmlInline():
          // keep nothing or strip tags? for now, keep as-is
          b.write(node.html);
          return;
      }
    }

    for (final i in this) {
      walk(i);
    }
    return b.toString();
  }
}

/// -------------------------
/// Internal immutability helpers
/// -------------------------

List<T> _freezeList<T>(Iterable<T> items) {
  // Defensive copy + unmodifiable wrapper.
  if (items is List<T>) {
    return List<T>.unmodifiable(items);
  }
  return List<T>.unmodifiable(items.toList(growable: false));
}

/// -------------------------
/// Deep equality / hashing
/// -------------------------

bool _deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;

  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }

  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!_deepEquals(a[key], b[key])) return false;
    }
    return true;
  }

  return a == b;
}

int _deepHash(Object? obj) {
  if (obj == null) return 0;

  if (obj is List) {
    // Order-sensitive
    return Object.hashAll(obj.map(_deepHash));
  }

  if (obj is Map) {
    // Order-insensitive but stable:
    // Sort keys by toString() to ensure deterministic hashing.
    final keys = obj.keys.toList()
      ..sort((a, b) => a.toString().compareTo(b.toString()));
    return Object.hashAll(
      keys.map((k) => Object.hash(_deepHash(k), _deepHash(obj[k]))),
    );
  }

  return obj.hashCode;
}
