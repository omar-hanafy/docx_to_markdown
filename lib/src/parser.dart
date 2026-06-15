// parser.dart
//
// Production-grade OOXML -> IR parser for DOCX (word/document.xml).
// - Robust to missing parts / unknown elements (configurable fallbacks).
// - Builds proper nested lists (numPr + numbering.xml).
// - Supports hyperlinks (w:hyperlink + field codes), images (drawing + VML),
//   textboxes (txbxContent flatten), math (OMML), footnotes, comments.
// - Does NOT render Markdown (that’s renderer.dart’s job).

import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:xml/xml.dart';

import 'package:docx_to_markdown/src/config.dart';
import 'package:docx_to_markdown/src/ir.dart';
import 'package:docx_to_markdown/src/ooxml_package.dart';
import 'package:docx_to_markdown/src/styles.dart';

/// Callback type for receiving non-fatal parsing warnings.
///
/// Implementations should handle or log the warning as appropriate.
/// Warnings are advisory and do not stop parsing.
typedef WarningSink = void Function(DocWarning warning);

/// Holds context for parsing, specifically the current part path for resolving relationships.
class _ParseContext {
  _ParseContext({required this.partPath});
  final String partPath;
}

/// Parses a DOCX package into an intermediate representation (IR) [Document].
///
/// This parser handles the complex transition from OOXML (flat XML with
/// relationships) to a structured block/inline tree.
///
/// ### Key Responsibilities
/// - **Structure recovery:** Reconstructs nested lists and tables from flat
///   paragraph streams.
/// - **Resilience:** Handles missing parts or unknown elements based on
///   [DocxToMarkdownConfig].
/// - **Normalization:** Resolves styles, numbering, and relationships to
///   produce a clean IR.
///
/// ### Usage
/// Use [parseMainDocument] to process the entire document.
class DocxParser {
  /// Creates a parser for the given DOCX package.
  ///
  /// All dependencies are injected to allow testing and customization:
  /// - [package]: The opened DOCX archive to parse
  /// - [styles]: Pre-loaded style definitions for heading/code detection
  /// - [config]: Conversion settings (what to include, how to handle unknowns)
  /// - [mediaMap]: Mapping from internal media paths to output paths
  /// - [onWarning]: Callback for non-fatal issues encountered during parsing
  DocxParser({
    required this.package,
    required this.styles,
    required this.config,
    required this.mediaMap,
    required this.onWarning,
  }) : _numbering = _NumberingModel.fromXml(package.numberingXml),
       _comments = _CommentIndex.fromXml(package.commentsXml);

  /// The DOCX package being parsed.
  final DocxPackage package;

  /// Style registry for resolving paragraph semantics (headings, code, quotes).
  final StyleRegistry styles;

  /// Configuration controlling what content is included and how it's processed.
  final DocxToMarkdownConfig config;

  /// Mapping from internal media paths (e.g., `word/media/image1.png`) to
  /// output paths or URLs for use in the rendered Markdown.
  final Map<String, String> mediaMap;

  /// Callback invoked for each non-fatal warning during parsing.
  final WarningSink onWarning;
  final _NumberingModel _numbering;
  final _CommentIndex _comments;
  final List<DocWarning> _warnings = [];
  Set<String> _targetedAnchors = const <String>{};

  /// Parses `word/document.xml` and its dependencies into a [Document].
  ///
  /// This process follows a strict sequence:
  /// 1. Validation: checks the main document part and body.
  /// 2. Header/footer extraction (if enabled).
  /// 3. Body tokenization into a flat stream of [_Token]s.
  /// 4. Block building (list reconstruction, code merging).
  /// 5. Post-processing (footnotes and hooks).
  ///
  /// Throws [DocxPackageException] if critical parts are missing and
  /// [DocxToMarkdownConfig.strict] is `true`.
  Document parseMainDocument() {
    final docXml = package.documentXml;
    if (docXml == null) {
      if (config.strict) {
        throw DocxPackageException(
          'word/document.xml not found',
          part: 'word/document.xml',
        );
      }
      _warn(
        code: 'missing.part',
        message: 'word/document.xml not found',
        location: 'word/document.xml',
      );
      return Document(blocks: const [], warnings: List.of(_warnings));
    }

    final body = _firstDescendantByLocal(docXml, 'body');
    if (body == null) {
      if (config.strict) {
        throw DocxPackageException(
          'document.xml missing w:body',
          part: package.mainDocumentPartPath,
        );
      }
      _warn(
        code: 'invalid.document',
        message: 'document.xml missing w:body',
        location: 'word/document.xml',
      );
      return Document(blocks: const [], warnings: List.of(_warnings));
    }

    final mainCtx = _ParseContext(partPath: package.mainDocumentPartPath);
    _targetedAnchors = _collectTargetedAnchors(body);

    // 1. Parse Headers
    final headerBlocks = <Block>[];
    if (config.includeHeadersFooters) {
      headerBlocks.addAll(_parseHeadersOrFooters(body, isHeader: true));
    }

    // 2. Parse Body
    final builder = _TokenBuilder(warn: _warn, config: config);
    final children = body.children.whereType<XmlElement>().toList();
    for (var i = 0; i < children.length; i++) {
      final el = children[i];
      final loc = 'document.xml:body[$i]:${el.name.qualified}';
      final tokens = _tokenizeBodyElement(el, ctx: mainCtx, loc: loc);
      builder.consumeAll(tokens);
    }
    builder.finish();

    // 3. Parse Footers
    final footerBlocks = <Block>[];
    if (config.includeHeadersFooters) {
      footerBlocks.addAll(_parseHeadersOrFooters(body, isHeader: false));
    }

    // Combine all
    final allBlocks = [
      if (headerBlocks.isNotEmpty) ...[
        ...headerBlocks,
        const HorizontalRuleBlock(),
      ],
      ...builder.outputBlocks,
      if (footerBlocks.isNotEmpty) ...[
        const HorizontalRuleBlock(),
        ...footerBlocks,
      ],
    ];

    // 4. Parse Footnotes/Endnotes
    final footnotes = <String, FootnoteDefinition>{};
    if (config.includeFootnotes) {
      footnotes.addAll(_parseFootnotes());
    }
    if (config.includeEndnotes) {
      footnotes.addAll(_parseEndnotesAsFootnotes());
    }

    // 5. Apply Hooks recursively (once)
    final hookedBlocks = _applyHooksToBlocks(allBlocks, baseLoc: 'document');
    final hookedFootnotes = <String, FootnoteDefinition>{};
    for (final e in footnotes.entries) {
      final blocks = _applyHooksToBlocks(
        e.value.blocks,
        baseLoc: 'footnotes:${e.key}',
      );
      hookedFootnotes[e.key] = FootnoteDefinition(id: e.key, blocks: blocks);
    }

    return Document(
      blocks: hookedBlocks,
      footnotes: hookedFootnotes,
      warnings: List.of(_warnings),
    );
  }

  // ===========================================================================
  // Tokenization (OOXML -> tokens)
  // ===========================================================================

  /// Converts a single body element into a stream of tokens.
  ///
  /// Why tokenization? OOXML represents lists as flat paragraphs with
  /// numbering properties. We emit [_ListItemToken]s first, then use
  /// [_TokenBuilder] to reconstruct proper nesting.
  List<_Token> _tokenizeBodyElement(
    XmlElement el, {
    required _ParseContext ctx,
    required String loc,
  }) {
    switch (el.name.local) {
      case 'p':
        return _tokenizeParagraph(el, ctx: ctx, loc: loc);

      case 'tbl':
        return [
          _BlockToken(
            _parseTable(el, ctx: ctx, loc: loc),
            loc: loc,
          ),
        ];

      case 'sdt':
        // Recursive unwrap
        final content = _firstChildByLocal(el, 'sdtContent');
        return content == null
            ? []
            : _tokenizeContainerChildren(content, ctx: ctx, loc: loc);

      case 'smartTag':
      case 'customXml':
        return _tokenizeContainerChildren(el, ctx: ctx, loc: loc);

      case 'oMath':
      case 'oMathPara':
        return [
          _BlockToken(
            _parseMathBlock(el, ctx: ctx, loc: loc),
            loc: loc,
          ),
        ];

      case 'bookmarkStart':
        final name = _attrLocal(el, 'name');
        if (name != null &&
            _isNavigableBookmark(name) &&
            _targetedAnchors.contains(name)) {
          return [
            _AnchorToken(
              name: name,
              '<a id="${_escapeHtmlAttr(name)}"></a>',
              loc: loc,
            ),
          ];
        }
        return const [];

      case 'bookmarkEnd':
        return const [];

      case 'sectPr':
        return const [];

      default:
        return _unknownBlockTokens(el, ctx: ctx, loc: loc);
    }
  }

  List<_Token> _tokenizeContainerChildren(
    XmlElement container, {
    required _ParseContext ctx,
    required String loc,
  }) {
    final out = <_Token>[];
    final kids = container.children.whereType<XmlElement>().toList();
    for (var i = 0; i < kids.length; i++) {
      out.addAll(
        _tokenizeBodyElement(kids[i], ctx: ctx, loc: '$loc:child[$i]'),
      );
    }
    return out;
  }

  /// Tokenizes a paragraph (`<w:p>`) into a block or list-item token.
  ///
  /// Logic flow:
  /// 1. Style analysis (heading, quote, code).
  /// 2. Numbering resolution (direct `numPr`, then style-based).
  /// 3. Inline parsing of runs, hyperlinks, fields, etc.
  List<_Token> _tokenizeParagraph(
    XmlElement p, {
    required _ParseContext ctx,
    required String loc,
  }) {
    final pPr = _firstChildByLocal(p, 'pPr');
    final styleId = _attrLocal(
      _firstChildByLocal(pPr, 'pStyle'),
      'val',
    ); // w:val
    final numPr = _firstChildByLocal(pPr, 'numPr');

    final indentLeftTwips = _readIndentLeftTwips(pPr);

    if (_isHorizontalRuleParagraph(p, pPr: pPr)) {
      return [_BlockToken(const HorizontalRuleBlock(), loc: loc)];
    }

    // Explicit page break (w:br type="page"). Only a paragraph whose sole
    // content is the break becomes a PageBreakBlock; a break embedded in a
    // paragraph with other content is kept as a line break (mid-paragraph
    // splitting is deferred) and reported. w:lastRenderedPageBreak (a layout
    // hint) is always ignored.
    if (config.pageBreakMode != PageBreakMode.ignore && _hasPageBreak(p)) {
      if (_isPageBreakOnlyParagraph(p)) {
        return [_BlockToken(const PageBreakBlock(), loc: loc)];
      }
      _warn(
        code: 'page.break.midparagraph',
        message:
            'Page break inside a paragraph with content; kept as a line break. '
            'Mid-paragraph page-break splitting is not yet supported.',
        location: loc,
      );
    }

    final analysis = styles.analyzeParagraphStyle(styleId);
    final override = styleId == null
        ? null
        : config.paragraphStyleOverrides[styleId];
    final isCodeBlock = override?.isCodeBlock ?? analysis.isCodeBlock;
    final isQuote = override?.isQuote ?? analysis.isQuote;
    final headingLevel = override?.headingLevel ?? analysis.headingLevel;
    final isHeading = override?.headingLevel != null
        ? true
        : analysis.isHeading;
    final codeLanguage = override?.codeLanguage;

    if (isCodeBlock) {
      final codeLine = _extractPlainTextFromParagraph(p);
      return [
        _CodeLineToken(
          codeLine,
          loc: loc,
          continuationIndentTwips: indentLeftTwips,
          language: codeLanguage,
        ),
      ];
    }

    // Check for direct numbering properties or style-inherited numbering
    String? effectiveNumId;
    int effectiveIlvl = 0;

    if (numPr != null) {
      // Direct paragraph numbering
      effectiveIlvl =
          int.tryParse(
            _attrLocal(_firstChildByLocal(numPr, 'ilvl'), 'val') ?? '0',
          ) ??
          0;
      effectiveNumId = _attrLocal(_firstChildByLocal(numPr, 'numId'), 'val');
    } else if (styleId != null) {
      // Fallback: check style-level numbering (common in templates)
      final styleNum = styles.resolveNumberingForStyle(styleId);
      if (styleNum != null) {
        effectiveNumId = styleNum.numId;
        effectiveIlvl = styleNum.ilvl;
      }
    }

    if (effectiveNumId != null) {
      final levelInfo = _numbering.levelInfo(
        numId: effectiveNumId,
        ilvl: effectiveIlvl,
      );
      final ordered = levelInfo?.ordered ?? false;
      // Resolved starting number: an instance lvlOverride/startOverride wins,
      // otherwise the abstract level's w:start. This only sets where the list
      // begins - it must not trigger a per-item restart (see _addListItem).
      final start = levelInfo?.startOverride ?? levelInfo?.start;
      final numberFormat = levelInfo?.numberFormat ?? ListNumberFormat.decimal;

      final inlines = _parseInlinesFromParagraph(p, ctx: ctx, loc: loc);

      // Even if paragraph is empty, keep as list item
      return [
        _ListItemToken(
          ordered: ordered,
          level: math.max(effectiveIlvl, 0),
          numId: effectiveNumId,
          start: start,
          numberFormat: numberFormat,
          loc: loc,
          itemBlocks: [ParagraphBlock(inlines)],
        ),
      ];
    }

    if (isHeading && headingLevel > 0) {
      final inlines = _parseInlinesFromParagraph(p, ctx: ctx, loc: loc);
      if (_isInlineListEffectivelyEmpty(inlines)) return const [];
      return [
        _BlockToken(
          HeadingBlock(level: headingLevel, inlines: inlines),
          loc: loc,
          canContinueList: false,
        ),
      ];
    }

    if (isQuote) {
      final inlines = _parseInlinesFromParagraph(p, ctx: ctx, loc: loc);
      if (_isInlineListEffectivelyEmpty(inlines)) return const [];
      return [
        _BlockToken(
          QuoteBlock([ParagraphBlock(inlines)]),
          loc: loc,
          canContinueList: false,
        ),
      ];
    }

    final inlines = _parseInlinesFromParagraph(p, ctx: ctx, loc: loc);
    final isEmpty = _isInlineListEffectivelyEmpty(inlines);
    final canContinueList = (indentLeftTwips ?? 0) > 0 && !isEmpty;

    if (isEmpty && !config.preserveEmptyParagraphs) return const [];

    return [
      _BlockToken(
        ParagraphBlock(inlines),
        loc: loc,
        canContinueList: canContinueList,
      ),
    ];
  }

  // ===========================================================================
  // Inline parsing
  // ===========================================================================

  List<Inline> _parseInlinesFromParagraph(
    XmlElement p, {
    required _ParseContext ctx,
    required String loc,
  }) {
    final pPr = _firstChildByLocal(p, 'pPr');
    final styleId = _attrLocal(_firstChildByLocal(pPr, 'pStyle'), 'val');
    return _parseInlineChildren(
      p,
      ctx: ctx,
      loc: loc,
      inheritedRunProps: styles.resolveRunPropertiesForStyle(styleId),
    );
  }

  /// Parses child elements into a list of [Inline] nodes.
  ///
  /// Why complex? Word breaks text into arbitrary runs (`<w:r>`). We must:
  /// 1. Flatten containers like `smartTag` or `ins`.
  /// 2. Handle fields (e.g., `HYPERLINK`) via [_FieldState].
  /// 3. Merge adjacent text runs for clean output.
  List<Inline> _parseInlineChildren(
    XmlElement container, {
    required _ParseContext ctx,
    required String loc,
    StyleRunProperties? inheritedRunProps,
  }) {
    final out = <Inline>[];
    final activeCommentIds = <String>{};
    final field = _FieldState();

    void processChildren(XmlElement node, String parentLoc) {
      final children = node.children.whereType<XmlElement>().toList();
      for (var i = 0; i < children.length; i++) {
        final child = children[i];
        final cLoc = '$parentLoc:${child.name.local}[$i]';
        _processInlineNode(
          child,
          ctx,
          cLoc,
          out,
          field,
          activeCommentIds,
          processChildren,
          inheritedRunProps,
        );
      }
    }

    processChildren(container, loc);

    while (field.isActive) {
      _finalizeField(out, field, '$loc:end');
    }

    return _mergeAdjacentText(out);
  }

  void _processInlineNode(
    XmlElement child,
    _ParseContext ctx,
    String cLoc,
    List<Inline> out,
    _FieldState field,
    Set<String> activeCommentIds,
    void Function(XmlElement, String) recurse,
    StyleRunProperties? inheritedRunProps,
  ) {
    void push(Inline i) {
      // NOTE: Removed double hook application here.
      // Hooks are applied once at the very end.
      out.add(i);
    }

    switch (child.name.local) {
      case 'r':
        final runs = _parseRun(
          child,
          ctx: ctx,
          loc: cLoc,
          field: field,
          commentIds: activeCommentIds,
          inheritedRunProps: inheritedRunProps,
        );
        if (field.isActive && field.inResult) {
          field.displayInlines.addAll(runs);
        } else {
          runs.forEach(push);
        }
        while (field.isActive && field.sawEnd) {
          _finalizeField(out, field, '$cLoc:fldCharEnd');
        }
        break;

      // Inline Containers (Recursively Unwrap)
      case 'smartTag':
      case 'customXml':
      case 'bdo':
      case 'dir':
        recurse(child, cLoc);
        break;

      case 'ins':
        // Tracked insertion: keep inline unless revisions are rejected.
        if (config.trackChangesMode != TrackChangesMode.rejectChanges) {
          recurse(child, cLoc);
        }
        break;

      case 'sdt':
        final content = _firstChildByLocal(child, 'sdtContent');
        if (content != null) recurse(content, cLoc);
        break;

      case 'hyperlink':
        if (field.isActive) _finalizeField(out, field, cLoc);
        final linkInlines = _parseHyperlink(
          child,
          ctx: ctx,
          loc: cLoc,
          inheritedRunProps: inheritedRunProps,
        );
        linkInlines.forEach(push);
        break;

      case 'fldSimple':
        if (field.isActive) _finalizeField(out, field, cLoc);
        final simpleInlines = _parseFldSimple(
          child,
          ctx: ctx,
          loc: cLoc,
          inheritedRunProps: inheritedRunProps,
        );
        simpleInlines.forEach(push);
        break;

      case 'oMath':
        if (field.isActive) _finalizeField(out, field, cLoc);
        push(_parseMathInline(child, ctx: ctx, loc: cLoc));
        break;

      case 'commentRangeStart':
        if (config.includeComments) {
          final id = _attrLocal(child, 'id');
          if (id != null) activeCommentIds.add(id);
        }
        break;

      case 'commentRangeEnd':
        if (config.includeComments) {
          final id = _attrLocal(child, 'id');
          if (id != null && activeCommentIds.remove(id)) {
            final c = _comments.byId(id);
            if (c != null) {
              push(
                HtmlInline(
                  '^[${_escapeForComment(c.author)}: ${_escapeForComment(c.text)}]',
                ),
              );
            }
          }
        }
        break;

      case 'bookmarkStart':
        final name = _attrLocal(child, 'name');
        if (name != null && _isNavigableBookmark(name)) {
          push(HtmlInline('<a id="$name"></a>'));
        }
        break;

      case 'del':
        switch (config.trackChangesMode) {
          case TrackChangesMode.acceptAll:
            _warn(
              code: 'trackChanges.deletionDropped',
              message: 'Dropped deleted text (w:del).',
              location: cLoc,
            );
            break;
          case TrackChangesMode.rejectChanges:
            final restored = _delText(child);
            if (restored.isNotEmpty) push(TextInline(restored));
            break;
          case TrackChangesMode.showDeletionsAsStrikethrough:
            final removed = _delText(child);
            if (removed.isNotEmpty) {
              push(StrikeInline([TextInline(removed)]));
            }
            break;
        }
        break;

      // Property and marker elements never carry inline content. Skipping them
      // explicitly prevents a whitespace-formatted <w:pPr> (or similar) from
      // being treated as an unknown inline, which would otherwise leak its
      // inter-element whitespace into the paragraph text and emit a spurious
      // `unsupported.inline` warning.
      case 'pPr':
      case 'rPr':
      case 'sectPr':
      case 'tblPr':
      case 'trPr':
      case 'tcPr':
      case 'tblGrid':
      case 'bookmarkEnd':
      case 'proofErr':
      case 'lastRenderedPageBreak':
        break;

      default:
        // Fallback for unknown containers that might hold text
        if (child.descendants.whereType<XmlElement>().any(
          (e) => e.name.local == 'r',
        )) {
          recurse(child, cLoc);
        } else {
          // If it's truly unknown, use policy
          final unknown = _unknownInline(child, loc: cLoc);
          unknown.forEach(push);
        }
        break;
    }
  }

  void _finalizeField(List<Inline> out, _FieldState field, String loc) {
    final result = field.finalizeTop(loc: loc);
    if (result == null) return;

    final emitted = result.produced != null
        ? <Inline>[result.produced!]
        : result.displayInlines;
    if (emitted.isEmpty) return;

    if (field.isActive && field.inResult) {
      field.displayInlines.addAll(emitted);
      return;
    }

    if (!field.isActive) {
      out.addAll(emitted);
    }
  }

  List<Inline> _parseRun(
    XmlElement r, {
    required _ParseContext ctx,
    required String loc,
    required _FieldState field,
    required Set<String> commentIds,
    required StyleRunProperties? inheritedRunProps,
  }) {
    final out = <Inline>[];

    final fldChar = _firstChildByLocal(r, 'fldChar');
    if (fldChar != null) {
      final type = _attrLocal(fldChar, 'fldCharType');
      if (type == 'begin') {
        field.begin(loc: loc);
        return const [];
      }
      if (type == 'separate') {
        field.separate(loc: loc);
        return const [];
      }
      if (type == 'end') {
        field.end(loc: loc);
        return const [];
      }
    }

    final instrText = _firstChildByLocal(r, 'instrText');
    if (instrText != null && field.isActive && !field.inResult) {
      final t = instrText.innerText;
      if (t.isNotEmpty) field.appendInstr(t);
      return const [];
    }

    if (config.includeFootnotes) {
      final fnRef = _firstChildByLocal(r, 'footnoteReference');
      if (fnRef != null) {
        final id = _attrLocal(fnRef, 'id');
        if (id != null) {
          return [FootnoteRefInline(id)];
        }
      }
    }

    if (config.includeEndnotes) {
      final enRef = _firstChildByLocal(r, 'endnoteReference');
      if (enRef != null) {
        final id = _attrLocal(enRef, 'id');
        if (id != null) {
          return [FootnoteRefInline('endnote:$id')];
        }
      }
    }

    final drawing = _firstChildByLocal(r, 'drawing');
    if (drawing != null) {
      final extracted = _parseDrawingAsInline(
        drawing,
        ctx: ctx,
        loc: '$loc:drawing',
      );
      if (extracted != null) return extracted;
    }

    final pict = _firstChildByLocal(r, 'pict');
    if (pict != null) {
      final img = _parseVmlImage(pict, ctx: ctx, loc: '$loc:pict');
      if (img != null) return [img];
    }

    final sym = _firstChildByLocal(r, 'sym');
    if (sym != null) {
      final charHex = _attrLocal(sym, 'char');
      final decoded = _decodeHexChar(charHex);
      if (decoded != null) {
        out.add(TextInline(decoded));
      }
    }

    final rPr = _firstChildByLocal(r, 'rPr');
    final runProps = _effectiveRunProperties(
      rPr,
      inheritedRunProps: inheritedRunProps,
    );

    for (final child in r.children.whereType<XmlElement>()) {
      switch (child.name.local) {
        case 't':
          final text = child.innerText;
          if (text.isEmpty) break;
          out.add(
            _applyRunFormatting(TextInline(text), rPr: rPr, props: runProps),
          );
          break;
        case 'tab':
        case 'ptab':
          out.add(const TextInline('\t'));
          break;
        case 'br':
        case 'cr':
          out.add(const LineBreakInline());
          break;
        case 'noBreakHyphen':
          out.add(const TextInline('-'));
          break;
        default:
          break;
      }
    }

    if (out.isEmpty) {
      final txt = r.findAllElements('w:t').map((e) => e.innerText).join();
      if (txt.isNotEmpty) {
        out.add(
          _applyRunFormatting(TextInline(txt), rPr: rPr, props: runProps),
        );
      }
    }

    return out;
  }

  Inline _applyRunFormatting(
    Inline base, {
    required XmlElement? rPr,
    required StyleRunProperties? props,
  }) {
    if (props == null && rPr == null) return base;

    Inline node = base;

    // Inline code (monospace font/shading, or a monospace character style) is
    // the innermost wrapper so emphasis and sub/superscript compose around it
    // instead of being dropped (e.g. a superscripted `2` in a Verbatim run
    // must render as `<sup>`2`</sup>`, not a bare `2`).
    final isCode = _isCodeRun(rPr, props: props);
    if (isCode) {
      if (node case TextInline(:final text)) {
        node = CodeInline(text);
      } else {
        node = HtmlInline(_inlineToPlainText(node));
      }
    }

    final bold = props?.bold == true;
    final italic = props?.italic == true;
    final strike = props?.strike == true;
    final underline = props?.underline == true;
    final vertAlign = props?.vertAlign;

    if (underline) node = UnderlineInline([node]);
    if (strike) node = StrikeInline([node]);
    if (italic) node = EmphInline([node]);
    if (bold) node = StrongInline([node]);

    if (vertAlign == 'subscript') node = SubInline([node]);
    if (vertAlign == 'superscript') node = SupInline([node]);

    // Highlight (w:highlight) and text color (w:color) wrap the formatted run.
    // They are always parsed into the IR for fidelity; the renderer drops them
    // when the corresponding mode is `none` (mirroring UnderlineMode.ignore).
    // Code takes precedence over these treatments: a run rendered as inline
    // code (including a shaded run via treatShadedRunsAsCode) is not also
    // wrapped in highlight/color, since w:shd and w:highlight share the same
    // background/color channel.
    if (!isCode) {
      final color = props?.color;
      if (color != null && color.isNotEmpty) {
        node = ColorInline([node], color: color);
      }
      final highlight = props?.highlight;
      if (highlight != null && highlight.isNotEmpty) {
        node = HighlightInline([node], color: highlight);
      }
    }

    return node;
  }

  StyleRunProperties? _effectiveRunProperties(
    XmlElement? rPr, {
    required StyleRunProperties? inheritedRunProps,
  }) {
    var effective = inheritedRunProps;
    if (rPr == null) return effective;

    final rStyle = _attrLocal(_firstChildByLocal(rPr, 'rStyle'), 'val');
    final styleProps = styles.resolveRunPropertiesForStyle(rStyle);
    if (styleProps != null) {
      effective = effective == null ? styleProps : effective.merge(styleProps);
    }

    final directProps = _parseDirectRunProperties(rPr);
    if (directProps != null) {
      effective = effective == null
          ? directProps
          : effective.merge(directProps);
    }

    return effective;
  }

  StyleRunProperties? _parseDirectRunProperties(XmlElement rPr) {
    final rFonts = _firstChildByLocal(rPr, 'rFonts');
    final ascii = _attrLocal(rFonts, 'ascii');
    final hAnsi = _attrLocal(rFonts, 'hAnsi');
    final cs = _attrLocal(rFonts, 'cs');

    final hasShading = _firstChildByLocal(rPr, 'shd') != null;
    final bold = _parseAnyOnOff(rPr, const ['b', 'bCs']);
    final italic = _parseAnyOnOff(rPr, const ['i', 'iCs']);
    final strike = _parseAnyOnOff(rPr, const ['strike', 'dstrike']);
    final underline = _parseOnOff(_firstChildByLocal(rPr, 'u'));

    final vertAlignEl = _firstChildByLocal(rPr, 'vertAlign');
    final vertAlign = _attrLocal(vertAlignEl, 'val');

    final colorEl = _firstChildByLocal(rPr, 'color');
    final rawColor = _attrLocal(colorEl, 'val');
    final color = rawColor == null || rawColor.toLowerCase() == 'auto'
        ? null
        : rawColor;

    final highlightEl = _firstChildByLocal(rPr, 'highlight');
    final rawHighlight = _attrLocal(highlightEl, 'val');
    final highlight =
        rawHighlight == null || rawHighlight.toLowerCase() == 'none'
        ? null
        : rawHighlight;

    if (ascii == null &&
        hAnsi == null &&
        cs == null &&
        !hasShading &&
        bold == null &&
        italic == null &&
        strike == null &&
        underline == null &&
        vertAlignEl == null &&
        colorEl == null &&
        highlightEl == null) {
      return null;
    }

    return StyleRunProperties(
      asciiFont: ascii,
      hAnsiFont: hAnsi,
      csFont: cs,
      hasShading: hasShading,
      bold: bold,
      italic: italic,
      strike: strike,
      underline: underline,
      vertAlign: vertAlign,
      vertAlignIsSet: vertAlignEl != null,
      color: color,
      colorIsSet: colorEl != null,
      highlight: highlight,
      highlightIsSet: highlightEl != null,
    );
  }

  bool? _parseAnyOnOff(XmlElement rPr, Iterable<String> childLocalNames) {
    var sawExplicitOff = false;
    for (final name in childLocalNames) {
      final parsed = _parseOnOff(_firstChildByLocal(rPr, name));
      if (parsed == true) return true;
      if (parsed == false) sawExplicitOff = true;
    }
    return sawExplicitOff ? false : null;
  }

  bool? _parseOnOff(XmlElement? el) {
    if (el == null) return null;
    final v = _attrLocal(el, 'val');
    if (v == null) return true;
    final normalized = v.trim().toLowerCase();
    return normalized != 'false' &&
        normalized != '0' &&
        normalized != 'off' &&
        normalized != 'none';
  }

  bool _isCodeRun(XmlElement? rPr, {required StyleRunProperties? props}) {
    if (_fontLooksMonospace(props?.asciiFont) ||
        _fontLooksMonospace(props?.hAnsiFont) ||
        _fontLooksMonospace(props?.csFont)) {
      return true;
    }
    if (config.treatShadedRunsAsCode && (props?.hasShading ?? false)) {
      return true;
    }
    // A character style (w:rStyle) can carry the monospace font instead of an
    // inline w:rFonts. Pandoc/Word emit inline code via a "Verbatim Char"
    // character style (Consolas), so resolve it through the style chain.
    final rStyle = _attrLocal(_firstChildByLocal(rPr, 'rStyle'), 'val');
    if (rStyle != null && styles.isCodeCharacterStyle(rStyle)) {
      return true;
    }
    return false;
  }

  bool _fontLooksMonospace(String? font) {
    if (font == null) return false;
    final f = font.trim().toLowerCase();
    if (f.isEmpty) return false;

    for (final hint in config.monospaceFonts) {
      final h = hint.trim().toLowerCase();
      if (h.isEmpty) continue;
      if (f == h || f.contains(h)) return true;
    }
    return false;
  }

  /// Whether a bookmark name is a navigable cross-reference target.
  ///
  /// Word emits internal scaffolding bookmarks prefixed with `_`, but its
  /// cross-reference (`_Ref`), table-of-contents (`_Toc`), and hyperlink
  /// (`_Hlk`) anchors are real navigation targets that REF/PAGEREF link to.
  bool _isNavigableBookmark(String name) {
    if (!name.startsWith('_')) return true;
    return name.startsWith('_Ref') ||
        name.startsWith('_Toc') ||
        name.startsWith('_Hlk');
  }

  List<Inline> _parseHyperlink(
    XmlElement hyperlink, {
    required _ParseContext ctx,
    required String loc,
    required StyleRunProperties? inheritedRunProps,
  }) {
    final rid = _attrLocal(hyperlink, 'id');
    final anchor = _attrLocal(hyperlink, 'anchor');

    // Recursively parse children (could contain runs with formatting)
    final children = _parseInlineChildren(
      hyperlink,
      ctx: ctx,
      loc: loc,
      inheritedRunProps: inheritedRunProps,
    );

    if (children.isEmpty) return const [];

    if (anchor != null && anchor.isNotEmpty) {
      return [LinkInline(url: '#$anchor', children: children)];
    }

    if (rid != null) {
      // PART-AWARE RESOLUTION
      final target = package.resolveRelTarget(ctx.partPath, rid);
      if (target != null && target.isNotEmpty) {
        return [LinkInline(url: target, children: children)];
      }
    }

    return children;
  }

  List<Inline> _parseFldSimple(
    XmlElement fldSimple, {
    required _ParseContext ctx,
    required String loc,
    required StyleRunProperties? inheritedRunProps,
  }) {
    final instr = _attrLocal(fldSimple, 'instr');
    if (instr == null || instr.isEmpty) return const [];

    final url = _extractHyperlinkUrl(instr);
    final anchor = _extractHyperlinkAnchor(instr);
    final ref = _extractRefBookmark(instr);

    // Recursively parse children
    final children = _parseInlineChildren(
      fldSimple,
      ctx: ctx,
      loc: loc,
      inheritedRunProps: inheritedRunProps,
    );

    if (children.isEmpty) {
      if (url != null) {
        return [
          LinkInline(url: url, children: [TextInline(url)]),
        ];
      }
      if (anchor != null) {
        return [
          LinkInline(url: '#$anchor', children: [TextInline(anchor)]),
        ];
      }
      if (ref != null) {
        return [
          LinkInline(url: '#$ref', children: [TextInline(ref)]),
        ];
      }
      return const [];
    }

    if (url != null) {
      return [LinkInline(url: url, children: children)];
    }
    if (anchor != null) {
      return [LinkInline(url: '#$anchor', children: children)];
    }
    if (ref != null) {
      return [LinkInline(url: '#$ref', children: children)];
    }

    return children;
  }

  List<Inline>? _parseDrawingAsInline(
    XmlElement drawing, {
    required _ParseContext ctx,
    required String loc,
  }) {
    final blip = drawing.descendants.whereType<XmlElement>().firstWhereOrNull(
      (e) => e.name.local == 'blip',
    );
    final embed = blip != null ? _attrLocal(blip, 'embed') : null;
    if (embed != null) {
      // PART-AWARE RESOLUTION
      final src = _resolveMediaTarget(embed, ctx: ctx);
      if (src != null) {
        final docPr = drawing.descendants
            .whereType<XmlElement>()
            .firstWhereOrNull((e) => e.name.local == 'docPr');
        final cNvPr = drawing.descendants
            .whereType<XmlElement>()
            .firstWhereOrNull((e) => e.name.local == 'cNvPr');
        final alt = _firstNonEmptyAttr([
          _attrLocal(docPr, 'descr'),
          _attrLocal(cNvPr, 'descr'),
        ], fallback: 'Image');

        // `wp:docPr/@title` is Word's "Alt Text" title field. ImageInline renders
        // it as a Markdown link title: `![alt](src "title")`.
        final rawTitle = _attrLocal(docPr, 'title');
        final title = (rawTitle != null && rawTitle.isNotEmpty)
            ? rawTitle
            : null;

        return [ImageInline(src: src, alt: alt, title: title)];
      }
    }

    final txbxContent = drawing.descendants
        .whereType<XmlElement>()
        .firstWhereOrNull((e) => e.name.local == 'txbxContent');
    if (txbxContent != null) {
      _warn(
        code: 'textbox.flattened',
        message: 'Flattened textbox content into inline text.',
        location: loc,
      );

      final paras = txbxContent.children
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'p')
          .toList();
      final inlines = <Inline>[];

      for (var i = 0; i < paras.length; i++) {
        final p = paras[i];
        final pInlines = _parseInlinesFromParagraph(
          p,
          ctx: ctx,
          loc: '$loc:txbx:p[$i]',
        );
        inlines.addAll(pInlines);

        if (i != paras.length - 1) {
          inlines.add(const LineBreakInline());
          inlines.add(const LineBreakInline());
        }
      }

      return _mergeAdjacentText(inlines);
    }

    return null;
  }

  ImageInline? _parseVmlImage(
    XmlElement pict, {
    required _ParseContext ctx,
    required String loc,
  }) {
    final imgData = pict.descendants.whereType<XmlElement>().firstWhereOrNull(
      (e) => e.name.local == 'imagedata',
    );
    if (imgData == null) return null;

    final rid = _attrLocal(imgData, 'id');
    if (rid == null) return null;

    final src = _resolveMediaTarget(rid, ctx: ctx);
    if (src == null) return null;

    // Legacy VML stores an optional title on `v:imagedata/@o:title`.
    final rawTitle = _attrLocal(imgData, 'title');
    final title = (rawTitle != null && rawTitle.isNotEmpty) ? rawTitle : null;
    final alt = 'Image';
    return ImageInline(src: src, alt: alt, title: title);
  }

  // ===========================================================================
  // Tables
  // ===========================================================================

  /// Parses a table (`<w:tbl>`).
  ///
  /// Strategy:
  /// - If complex (merged cells) and [DocxToMarkdownConfig.tableMode] allows,
  ///   fall back to HTML to preserve structure.
  /// - Otherwise attempt a best-effort grid parse for Markdown tables.
  Block _parseTable(
    XmlElement tbl, {
    required _ParseContext ctx,
    required String loc,
  }) {
    final forceHtml = config.tableMode == TableMode.htmlOnly;

    final hasVMerge = tbl.descendants.whereType<XmlElement>().any(
      (e) => e.name.local == 'vMerge',
    );
    final hasGridSpan = tbl.descendants.whereType<XmlElement>().any(
      (e) => e.name.local == 'gridSpan',
    );

    final complex = hasVMerge || hasGridSpan;

    if (forceHtml || (config.tableMode == TableMode.auto && complex)) {
      return HtmlBlock(_renderTableAsHtml(tbl, ctx: ctx, loc: loc));
    }

    return _parseTableAsGridBestEffort(tbl, ctx: ctx, loc: loc);
  }

  String _renderTableAsHtml(
    XmlElement tbl, {
    required _ParseContext ctx,
    required String loc,
  }) {
    final sb = StringBuffer()..writeln('<table>');
    final rows = tbl.children
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'tr')
        .toList();

    final rowCells = <List<_HtmlTableCellInfo>>[];
    for (var r = 0; r < rows.length; r++) {
      final tr = rows[r];
      final tcs = tr.children
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'tc')
          .toList();

      var colIndex = 0;
      final cells = <_HtmlTableCellInfo>[];

      for (var c = 0; c < tcs.length; c++) {
        final tc = tcs[c];
        final tcPr = _firstChildByLocal(tc, 'tcPr');

        final gridSpan =
            int.tryParse(
              _attrLocal(_firstChildByLocal(tcPr, 'gridSpan'), 'val') ?? '1',
            ) ??
            1;

        final vMergeEl = _firstChildByLocal(tcPr, 'vMerge');
        final vMergeVal = _attrLocal(vMergeEl, 'val');
        final vMerge = vMergeEl == null
            ? _VMergeType.none
            : (vMergeVal == 'restart'
                  ? _VMergeType.restart
                  : _VMergeType.continueCell);

        cells.add(
          _HtmlTableCellInfo(
            tc: tc,
            rowIndex: r,
            cellIndex: c,
            colIndex: colIndex,
            colSpan: gridSpan,
            vMerge: vMerge,
          ),
        );

        colIndex += gridSpan;
      }

      rowCells.add(cells);
    }

    int? rowSpanForCell(_HtmlTableCellInfo cell) {
      if (cell.vMerge != _VMergeType.restart) return null;
      var span = 1;
      for (var r = cell.rowIndex + 1; r < rowCells.length; r++) {
        final nextRow = rowCells[r];
        final next = nextRow.firstWhereOrNull(
          (c) => c.colIndex == cell.colIndex,
        );
        if (next == null) break;
        if (next.vMerge != _VMergeType.continueCell) break;
        if (next.colSpan != cell.colSpan) break;
        span++;
      }
      return span > 1 ? span : null;
    }

    for (var r = 0; r < rowCells.length; r++) {
      sb.writeln('  <tr>');
      for (final cell in rowCells[r]) {
        if (cell.vMerge == _VMergeType.continueCell) continue;

        final attrs = <String>[];
        if (cell.colSpan > 1) attrs.add('colspan="${cell.colSpan}"');
        final rowSpan = rowSpanForCell(cell);
        if (rowSpan != null) attrs.add('rowspan="$rowSpan"');

        final cellBlocks = _parseBlocksFromContainer(
          cell.tc,
          ctx: ctx,
          loc: '$loc:tc[${cell.rowIndex},${cell.cellIndex}]',
        );
        final inner = _renderBlocksAsHtml(cellBlocks).trim();

        sb.writeln(
          '    <td${attrs.isEmpty ? '' : ' ${attrs.join(' ')}'}>$inner</td>',
        );
      }
      sb.writeln('  </tr>');
    }

    sb.writeln('</table>');
    return sb.toString();
  }

  TableBlock _parseTableAsGridBestEffort(
    XmlElement tbl, {
    required _ParseContext ctx,
    required String loc,
  }) {
    final rows = <TableRow>[];
    final alignments = <TableAlign>[];
    final trList = tbl.children
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'tr')
        .toList();

    for (var r = 0; r < trList.length; r++) {
      final tr = trList[r];
      final trPr = _firstChildByLocal(tr, 'trPr');
      final isHeader =
          trPr != null && _firstChildByLocal(trPr, 'tblHeader') != null;

      final cells = <TableCell>[];
      final tcList = tr.children
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'tc')
          .toList();

      for (var c = 0; c < tcList.length; c++) {
        final tc = tcList[c];
        final cellBlocks = _parseBlocksFromContainer(
          tc,
          ctx: ctx,
          loc: '$loc:tc[$r,$c]',
        );
        cells.add(TableCell(blocks: cellBlocks, isHeader: isHeader));
        if (r == 0) {
          alignments.add(_readTableCellAlignment(tc));
        }
      }

      rows.add(TableRow(cells: cells, isHeader: isHeader));
    }

    return TableBlock(
      grid: TableGrid(rows: rows),
      alignments: alignments,
    );
  }

  TableAlign _readTableCellAlignment(XmlElement tc) {
    final p = tc.children.whereType<XmlElement>().firstWhereOrNull(
      (e) => e.name.local == 'p',
    );
    final pPr = _firstChildByLocal(p, 'pPr');
    final jc = _attrLocal(_firstChildByLocal(pPr, 'jc'), 'val');
    return _tableAlignFromJc(jc);
  }

  TableAlign _tableAlignFromJc(String? val) {
    switch ((val ?? '').toLowerCase()) {
      case 'center':
        return TableAlign.center;
      case 'right':
        return TableAlign.right;
      case 'left':
        return TableAlign.left;
      default:
        return TableAlign.auto;
    }
  }

  List<Block> _parseBlocksFromContainer(
    XmlElement container, {
    required _ParseContext ctx,
    required String loc,
  }) {
    final builder = _TokenBuilder(warn: _warn, config: config);
    final kids = container.children.whereType<XmlElement>().toList();
    for (var i = 0; i < kids.length; i++) {
      builder.consumeAll(
        _tokenizeBodyElement(kids[i], ctx: ctx, loc: '$loc:child[$i]'),
      );
    }
    builder.finish();
    return builder.outputBlocks;
  }

  List<Block> _parseHeadersOrFooters(
    XmlElement body, {
    required bool isHeader,
  }) {
    final blocks = <Block>[];
    final sections = body.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'sectPr',
    );
    final processedIds = <String>{};

    for (final sect in sections) {
      final tag = isHeader ? 'headerReference' : 'footerReference';
      final ref =
          sect.children.whereType<XmlElement>().firstWhereOrNull(
            (e) => e.name.local == tag && _attrLocal(e, 'type') == 'default',
          ) ??
          sect.children.whereType<XmlElement>().firstWhereOrNull(
            (e) => e.name.local == tag,
          );

      if (ref != null) {
        final rId = _attrLocal(ref, 'id');
        if (rId != null && processedIds.add(rId)) {
          // PART-AWARE: Resolve relative to main document
          final target = package.resolveDocumentRelTarget(rId);
          if (target != null) {
            final xml = package.tryLoadXml(target);
            if (xml != null) {
              // Switch context to header/footer part
              final ctx = _ParseContext(partPath: target);
              blocks.addAll(
                _parseBlocksFromContainer(
                  xml.rootElement,
                  ctx: ctx,
                  loc: target,
                ),
              );
            }
          }
        }
      }
    }
    return blocks;
  }

  // ===========================================================================
  // Math
  // ===========================================================================

  Block _parseMathBlock(
    XmlElement math, {
    required _ParseContext ctx,
    required String loc,
  }) {
    final latex =
        config.hooks.ommlToLatex?.call(
          math.toXmlString(),
          HookContext(part: ctx.partPath, path: loc),
        ) ??
        _OmmlToLatex.convert(math);
    return MathBlock(latex);
  }

  Inline _parseMathInline(
    XmlElement math, {
    required _ParseContext ctx,
    required String loc,
  }) {
    final latex =
        config.hooks.ommlToLatex?.call(
          math.toXmlString(),
          HookContext(part: ctx.partPath, path: loc),
        ) ??
        _OmmlToLatex.convert(math);
    return HtmlInline('\$$latex\$');
  }

  // ===========================================================================
  // Footnotes / Endnotes
  // ===========================================================================

  Map<String, FootnoteDefinition> _parseFootnotes() {
    final xml = package.footnotesXml;
    if (xml == null) return {};

    // PART-AWARE
    final ctx = _ParseContext(partPath: package.footnotesPartPath!);

    final out = <String, FootnoteDefinition>{};
    final footnotes = xml.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'footnote')
        .toList();

    for (var i = 0; i < footnotes.length; i++) {
      final fn = footnotes[i];
      final id = _attrLocal(fn, 'id');
      if (id == null) continue;

      final numeric = int.tryParse(id) ?? -1;
      if (numeric <= 0) continue;

      final blocks = _parseBlocksFromContainer(
        fn,
        ctx: ctx,
        loc: 'footnotes.xml:footnote[$id]',
      );
      if (blocks.isEmpty) continue;
      out[id] = FootnoteDefinition(id: id, blocks: blocks);
    }

    return out;
  }

  Map<String, FootnoteDefinition> _parseEndnotesAsFootnotes() {
    final xml = package.endnotesXml;
    if (xml == null) return {};

    // PART-AWARE
    final ctx = _ParseContext(partPath: package.endnotesPartPath!);

    final out = <String, FootnoteDefinition>{};
    final endnotes = xml.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'endnote')
        .toList();

    for (var i = 0; i < endnotes.length; i++) {
      final en = endnotes[i];
      final id = _attrLocal(en, 'id');
      if (id == null) continue;

      final numeric = int.tryParse(id) ?? -1;
      if (numeric <= 0) continue;

      final blocks = _parseBlocksFromContainer(
        en,
        ctx: ctx,
        loc: 'endnotes.xml:endnote[$id]',
      );
      if (blocks.isEmpty) continue;

      final key = 'endnote:$id';
      out[key] = FootnoteDefinition(id: key, blocks: blocks);
    }

    return out;
  }

  // ===========================================================================
  // Unknown element fallbacks
  // ===========================================================================

  List<_Token> _unknownBlockTokens(
    XmlElement el, {
    required _ParseContext ctx,
    required String loc,
  }) {
    _warn(
      code: 'unsupported.block',
      message: 'Unsupported block element: ${el.name.qualified}',
      location: loc,
    );

    switch (config.unknownElementPolicy) {
      case UnknownElementPolicy.drop:
        return const [];

      case UnknownElementPolicy.keepText:
        final nested = _parseBlocksFromContainer(
          el,
          ctx: ctx,
          loc: '$loc:nested',
        );
        if (nested.isNotEmpty) {
          return nested.map((b) => _BlockToken(b, loc: loc)).toList();
        }

        final txt = el.innerText.trim();
        if (txt.isEmpty) return const [];
        return [
          _BlockToken(ParagraphBlock([TextInline(txt)]), loc: loc),
        ];

      case UnknownElementPolicy.keepHtml:
        final xmlString = _truncateXml(el.toXmlString(pretty: false));
        return [
          _BlockToken(HtmlBlock('<!-- Unsupported: $xmlString -->'), loc: loc),
        ];
    }
  }

  List<Inline> _unknownInline(XmlElement el, {required String loc}) {
    _warn(
      code: 'unsupported.inline',
      message: 'Unsupported inline element: ${el.name.qualified}',
      location: loc,
    );

    switch (config.unknownElementPolicy) {
      case UnknownElementPolicy.drop:
        return const [];

      case UnknownElementPolicy.keepText:
        final txt = el.innerText;
        if (txt.isEmpty) return const [];
        return [TextInline(txt)];

      case UnknownElementPolicy.keepHtml:
        final xmlString = _truncateXml(el.toXmlString(pretty: false));
        return [HtmlInline('<!-- $xmlString -->')];
    }
  }

  // ===========================================================================
  // Helpers
  // ===========================================================================

  // ... (keep _extractPlainTextFromParagraph, _isInlineListEffectivelyEmpty, _isHorizontalRuleParagraph, _readIndentLeftTwips)
  // Re-pasting for completeness in rewrite

  String _extractPlainTextFromParagraph(XmlElement p) {
    final sb = StringBuffer();

    void handleRun(XmlElement r) {
      for (final ch in r.children.whereType<XmlElement>()) {
        switch (ch.name.local) {
          case 't':
            sb.write(ch.innerText);
            break;
          case 'tab':
          case 'ptab':
            sb.write('\t');
            break;
          case 'br':
          case 'cr':
            sb.write('\n');
            break;
          case 'noBreakHyphen':
            sb.write('-');
            break;
          default:
            break;
        }
      }
    }

    // Simple extraction not recursive for code blocks (usually flat)
    for (final child in p.children.whereType<XmlElement>()) {
      switch (child.name.local) {
        case 'r':
          handleRun(child);
          break;
        case 'hyperlink':
          for (final r in child.children.whereType<XmlElement>().where(
            (e) => e.name.local == 'r',
          )) {
            handleRun(r);
          }
          break;
        default:
          break;
      }
    }
    return sb.toString();
  }

  /// Extracts the text of a `w:del` deletion. Word stores deleted runs in
  /// `w:delText`; we also accept `w:t` for lenient inputs.
  String _delText(XmlElement del) => del.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == 'delText' || e.name.local == 't')
      .map((e) => e.innerText)
      .join();

  bool _isInlineListEffectivelyEmpty(List<Inline> inlines) {
    if (inlines.isEmpty) return true;
    final txt = _inlineListToPlainText(inlines).trim();
    return txt.isEmpty;
  }

  bool _isHorizontalRuleParagraph(XmlElement p, {required XmlElement? pPr}) {
    final pBdr = _firstChildByLocal(pPr, 'pBdr');
    if (pBdr != null) {
      final bottom = _firstChildByLocal(pBdr, 'bottom');
      final top = _firstChildByLocal(pBdr, 'top');
      if (bottom != null || top != null) {
        final txt = p.descendants
            .whereType<XmlElement>()
            .where((e) => e.name.local == 't')
            .map((e) => e.innerText)
            .join();
        if (txt.trim().isEmpty) return true;
      }
    }
    final txt = p.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 't')
        .map((e) => e.innerText)
        .join()
        .trim();
    if (txt == '---' || txt == '***') return true;
    return false;
  }

  bool _hasPageBreak(XmlElement p) => p.descendants.whereType<XmlElement>().any(
    (e) => e.name.local == 'br' && _attrLocal(e, 'type') == 'page',
  );

  /// True when the only meaningful content of [p] is page break(s): no
  /// non-whitespace text and no embedded drawings or objects.
  bool _isPageBreakOnlyParagraph(XmlElement p) {
    final hasText = p.descendants.whereType<XmlElement>().any(
      (e) => e.name.local == 't' && e.innerText.trim().isNotEmpty,
    );
    if (hasText) return false;
    return !p.descendants.whereType<XmlElement>().any(
      (e) =>
          e.name.local == 'drawing' ||
          e.name.local == 'pict' ||
          e.name.local == 'object',
    );
  }

  int? _readIndentLeftTwips(XmlElement? pPr) {
    final ind = _firstChildByLocal(pPr, 'ind');
    if (ind == null) return null;
    final left = _attrLocal(ind, 'left');
    return int.tryParse(left ?? '');
  }

  String? _resolveMediaTarget(String rId, {required _ParseContext ctx}) {
    // PART-AWARE
    final target = package.resolveRelTarget(ctx.partPath, rId);
    if (target == null || target.isEmpty) return null;

    final uri = Uri.tryParse(target);
    if (uri != null && uri.hasScheme) {
      return target;
    }

    var t = target.replaceAll('\\', '/');
    while (t.startsWith('./')) {
      t = t.substring(2);
    }
    while (t.startsWith('../')) {
      t = t.substring(3);
    }

    final partPath = t.startsWith('word/') ? t : 'word/$t';
    final mapped = mediaMap[partPath];
    if (mapped != null && mapped.isNotEmpty) return mapped;
    return t.split('/').last;
  }

  List<Block> _applyHooksToBlocks(
    List<Block> blocks, {
    required String baseLoc,
  }) {
    final out = <Block>[];
    for (var i = 0; i < blocks.length; i++) {
      final b = _applyHooksToBlock(blocks[i], loc: '$baseLoc:block[$i]');
      if (b != null) out.add(b);
    }
    return out;
  }

  Block? _applyHooksToBlock(Block block, {required String loc}) {
    final normalized = switch (block) {
      ParagraphBlock() => ParagraphBlock(
        _applyHooksToInlines(block.inlines, loc: '$loc:para'),
      ),
      HeadingBlock() => HeadingBlock(
        level: block.level,
        inlines: _applyHooksToInlines(block.inlines, loc: '$loc:heading'),
      ),
      QuoteBlock() => QuoteBlock(
        _applyHooksToBlocks(block.blocks, baseLoc: '$loc:quote'),
      ),
      ListBlock() => ListBlock(
        ordered: block.ordered,
        start: block.start,
        numberFormat: block.numberFormat,
        tightness: block.tightness,
        items: block.items
            .mapIndexed(
              (idx, it) => ListItem(
                blocks: _applyHooksToBlocks(
                  it.blocks,
                  baseLoc: '$loc:listItem[$idx]',
                ),
              ),
            )
            .toList(),
      ),
      TableBlock() => TableBlock(
        grid: TableGrid(
          rows: block.grid.rows
              .mapIndexed(
                (r, row) => TableRow(
                  cells: row.cells
                      .mapIndexed(
                        (c, cell) => TableCell(
                          blocks: _applyHooksToBlocks(
                            cell.blocks,
                            baseLoc: '$loc:cell[$r,$c]',
                          ),
                          colSpan: cell.colSpan,
                          rowSpan: cell.rowSpan,
                          isHeader: cell.isHeader,
                        ),
                      )
                      .toList(),
                  isHeader: row.isHeader,
                ),
              )
              .toList(),
        ),
        alignments: block.alignments,
      ),
      _ => block,
    };
    final transformed = config.hooks.transformBlock?.call(
      normalized,
      HookContext(location: loc),
    );
    return transformed ?? normalized;
  }

  List<Inline> _applyHooksToInlines(
    List<Inline> inlines, {
    required String loc,
  }) {
    final out = <Inline>[];
    for (var i = 0; i < inlines.length; i++) {
      final n = _applyHooksToInline(inlines[i], loc: '$loc:inline[$i]');
      if (n != null) out.add(n);
    }
    return _mergeAdjacentText(out);
  }

  Inline? _applyHooksToInline(Inline node, {required String loc}) {
    final normalized = switch (node) {
      StrongInline() => StrongInline(
        _applyHooksToInlines(node.children, loc: '$loc:strong'),
      ),
      EmphInline() => EmphInline(
        _applyHooksToInlines(node.children, loc: '$loc:emph'),
      ),
      StrikeInline() => StrikeInline(
        _applyHooksToInlines(node.children, loc: '$loc:strike'),
      ),
      UnderlineInline() => UnderlineInline(
        _applyHooksToInlines(node.children, loc: '$loc:underline'),
      ),
      LinkInline() => LinkInline(
        url: node.url,
        children: _applyHooksToInlines(node.children, loc: '$loc:link'),
      ),
      SupInline() => SupInline(
        _applyHooksToInlines(node.children, loc: '$loc:sup'),
      ),
      SubInline() => SubInline(
        _applyHooksToInlines(node.children, loc: '$loc:sub'),
      ),
      _ => node,
    };
    return config.hooks.transformInline?.call(
          normalized,
          HookContext(location: loc),
        ) ??
        normalized;
  }

  void _warn({
    required String code,
    required String message,
    required String location,
  }) {
    var part = 'unknown';
    var path = location;
    final idx = location.indexOf(':');
    if (idx != -1) {
      part = location.substring(0, idx);
      path = location.substring(idx + 1);
    }
    final w = DocWarning(
      code: code,
      message: message,
      location: SourceLocation(part: part, path: path),
    );
    _warnings.add(w);
    onWarning(w);
  }

  XmlElement? _firstChildByLocal(XmlElement? parent, String local) {
    if (parent == null) return null;
    return parent.children.whereType<XmlElement>().firstWhereOrNull(
      (e) => e.name.local == local,
    );
  }

  XmlElement? _firstDescendantByLocal(XmlNode parent, String local) {
    return parent.descendants.whereType<XmlElement>().firstWhereOrNull(
      (e) => e.name.local == local,
    );
  }

  String? _attrLocal(XmlElement? el, String localName) {
    if (el == null) return null;
    final a = el.attributes.firstWhereOrNull((a) => a.name.local == localName);
    return a?.value;
  }

  String _firstNonEmptyAttr(
    Iterable<String?> values, {
    required String fallback,
  }) {
    for (final value in values) {
      if (value == null) continue;
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return fallback;
  }

  String? _decodeHexChar(String? hex) {
    if (hex == null) return null;
    final cleaned = hex.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
    if (cleaned.isEmpty) return null;
    final v = int.tryParse(cleaned, radix: 16);
    if (v == null) return null;
    return String.fromCharCode(v);
  }

  String _truncateXml(String xml, {int maxLen = 2000}) {
    if (xml.length <= maxLen) return xml;
    return '${xml.substring(0, maxLen)}…';
  }

  String _escapeForComment(String s) {
    return s.replaceAll('\n', ' ').replaceAll('\r', ' ').trim();
  }

  String _inlineToPlainText(Inline i) => switch (i) {
    TextInline() => i.text,
    CodeInline() => i.text,
    LineBreakInline() => '\n',
    FootnoteRefInline() => '[^${i.id}]',
    ImageInline() => i.alt,
    LinkInline() => _inlineListToPlainText(i.children),
    StrongInline() => _inlineListToPlainText(i.children),
    EmphInline() => _inlineListToPlainText(i.children),
    StrikeInline() => _inlineListToPlainText(i.children),
    UnderlineInline() => _inlineListToPlainText(i.children),
    SupInline() => _inlineListToPlainText(i.children),
    SubInline() => _inlineListToPlainText(i.children),
    HighlightInline() => _inlineListToPlainText(i.children),
    ColorInline() => _inlineListToPlainText(i.children),
    HtmlInline() => i.html,
    _ => '',
  };

  String _inlineListToPlainText(List<Inline> list) =>
      list.map(_inlineToPlainText).join();

  List<Inline> _mergeAdjacentText(List<Inline> inlines) {
    if (inlines.isEmpty) return inlines;
    final out = <Inline>[];
    TextInline? pending;
    void flush() {
      if (pending != null) {
        out.add(pending!);
        pending = null;
      }
    }

    for (final i in inlines) {
      if (i is TextInline) {
        if (pending == null) {
          pending = TextInline(i.text);
        } else {
          pending = TextInline('${pending!.text}${i.text}');
        }
      } else {
        flush();
        out.add(i);
      }
    }
    flush();
    return out;
  }

  String _renderBlocksAsHtml(List<Block> blocks) {
    final sb = StringBuffer();
    for (final b in blocks) {
      switch (b) {
        case ParagraphBlock():
          sb.write(_escapeHtml(_inlineListToPlainText(b.inlines)));
          sb.write('<br/>');
          break;
        case HeadingBlock():
          sb.write(
            '<strong>${_escapeHtml(_inlineListToPlainText(b.inlines))}</strong><br/>',
          );
          break;
        case CodeBlock():
          sb.write('<pre><code>${_escapeHtml(b.text)}</code></pre>');
          break;
        case ListBlock():
          sb.write(b.ordered ? '<ol>' : '<ul>');
          for (final it in b.items) {
            sb.write('<li>${_renderBlocksAsHtml(it.blocks)}</li>');
          }
          sb.write(b.ordered ? '</ol>' : '</ul>');
          break;
        case QuoteBlock():
          sb.write('<blockquote>${_renderBlocksAsHtml(b.blocks)}</blockquote>');
          break;
        case TableBlock():
          sb.write('<table>');
          for (final row in b.grid.rows) {
            sb.write('<tr>');
            for (final cell in row.cells) {
              sb.write('<td>${_renderBlocksAsHtml(cell.blocks)}</td>');
            }
            sb.write('</tr>');
          }
          sb.write('</table>');
          break;
        case HorizontalRuleBlock():
          sb.write('<hr/>');
          break;
        case HtmlBlock():
          sb.write(b.html);
          break;
        case MathBlock():
          sb.write('<span class="math">${_escapeHtml(b.latexOrText)}</span>');
          break;
        default:
          break;
      }
    }
    return sb.toString();
  }

  String _escapeHtml(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }

  String _escapeHtmlAttr(String s) {
    return _escapeHtml(s).replaceAll('"', '&quot;');
  }

  Set<String> _collectTargetedAnchors(XmlElement body) {
    final anchors = <String>{};
    for (final el in body.descendants.whereType<XmlElement>()) {
      if (el.name.local == 'hyperlink') {
        final anchor = _attrLocal(el, 'anchor');
        if (anchor != null && anchor.isNotEmpty) anchors.add(anchor);
      }
      if (el.name.local == 'fldSimple') {
        _collectAnchorsFromInstr(_attrLocal(el, 'instr'), anchors);
      }
      if (el.name.local == 'instrText') {
        _collectAnchorsFromInstr(el.innerText, anchors);
      }
    }
    return anchors;
  }

  void _collectAnchorsFromInstr(String? instr, Set<String> anchors) {
    if (instr == null || instr.isEmpty) return;
    final hyperlinkAnchor = _extractHyperlinkAnchor(instr);
    if (hyperlinkAnchor != null && hyperlinkAnchor.isNotEmpty) {
      anchors.add(hyperlinkAnchor);
    }
    final refAnchor = _extractRefBookmark(instr);
    if (refAnchor != null && refAnchor.isNotEmpty) anchors.add(refAnchor);
  }
}

// ============================================================================
// Token builder (groups list items + code lines into structured IR blocks)
// ============================================================================

sealed class _Token {}

class _BlockToken extends _Token {
  _BlockToken(this.block, {required this.loc, this.canContinueList = false});
  final Block block;
  final String loc;
  final bool canContinueList;
}

class _ListItemToken extends _Token {
  _ListItemToken({
    required this.ordered,
    required this.level,
    required this.numId,
    this.start,
    this.numberFormat = ListNumberFormat.decimal,
    required this.itemBlocks,
    required this.loc,
  });

  final bool ordered;
  final int level;
  final String numId;

  /// The resolved starting number for this level (instance restart override if
  /// present, else the abstract `w:start`). Sets the list's first number only;
  /// it never forces a per-item restart.
  final int? start;
  final ListNumberFormat numberFormat;
  final List<Block> itemBlocks;
  final String loc;
}

class _CodeLineToken extends _Token {
  _CodeLineToken(
    this.line, {
    required this.loc,
    required this.continuationIndentTwips,
    this.language,
  });
  final String line;
  final String loc;
  final int? continuationIndentTwips;
  final String? language;
}

class _AnchorToken extends _Token {
  _AnchorToken(this.html, {required this.name, required this.loc});
  final String name;
  final String html;
  final String loc;
}

typedef _PendingAnchor = ({String name, String html});

// ============================================================================
// Builder nodes (mutable) -> converted to immutable IR Blocks at the end.
// ============================================================================

sealed class _BNode {
  Block toBlock();
}

final class _BLeaf implements _BNode {
  _BLeaf(this.block);
  final Block block;

  @override
  Block toBlock() => block;
}

final class _BList implements _BNode {
  _BList({
    required this.ordered,
    required this.start,
    required this.numberFormat,
    required this.tightness,
  });

  bool ordered;
  int start;
  ListNumberFormat numberFormat;
  ListTightness tightness;

  final List<_BListItem> items = [];

  @override
  Block toBlock() {
    return ListBlock(
      ordered: ordered,
      start: start,
      numberFormat: numberFormat,
      tightness: tightness,
      items: items.map((it) => it.toListItem()).toList(growable: false),
    );
  }
}

final class _BListItem {
  _BListItem({Iterable<_BNode> blocks = const []}) {
    this.blocks.addAll(blocks);
  }

  final List<_BNode> blocks = [];

  ListItem toListItem() {
    return ListItem(
      blocks: blocks.map((b) => b.toBlock()).toList(growable: false),
    );
  }
}

final class _BListEntry {
  _BListEntry({required this.list, required this.numId});
  final _BList list;
  final String numId;
}

final class _CodeAccumulator {
  _CodeAccumulator(this.container, {this.language});
  final List<_BNode> container;
  String? language;
  final StringBuffer buffer = StringBuffer();
  void addLine(String line) => buffer.writeln(line);
}

/// Consumes a stream of tokens to build a structured [Block] tree.
///
/// Why: This state machine groups list items into [ListBlock]s, merges
/// consecutive code lines into a single [CodeBlock], and normalizes list
/// nesting levels for renderer-friendly output.
class _TokenBuilder {
  _TokenBuilder({required this.warn, required this.config});

  final void Function({
    required String code,
    required String message,
    required String location,
  })
  warn;
  final DocxToMarkdownConfig config;
  final List<_BNode> _top = [];
  final List<_BListEntry> _listStack = [];
  final List<_PendingAnchor> _pendingAnchors = [];
  _CodeAccumulator? _code;

  List<Block> get outputBlocks =>
      _top.map((n) => n.toBlock()).toList(growable: false);

  void consumeAll(List<_Token> tokens) {
    for (final t in tokens) {
      _consume(t);
    }
  }

  void finish() {
    _flushCode();
    _closeAllLists();
    _flushPendingAnchorsTo(_top);
  }

  void _consume(_Token t) {
    switch (t) {
      case _ListItemToken():
        _flushCode();
        _addListItem(t);
        return;
      case _CodeLineToken():
        _handleCodeLine(t);
        return;
      case _AnchorToken():
        _flushCode();
        _pendingAnchors.add((name: t.name, html: t.html));
        return;
      case _BlockToken():
        if (_listStack.isNotEmpty && t.canContinueList) {
          _flushCode();
          _addBlockToCurrentListItem(t.block);
          return;
        }
        _flushCode();
        _closeAllLists();
        _flushPendingAnchorsTo(_top, beforeBlock: t.block);
        _top.add(_BLeaf(t.block));
        return;
    }
  }

  void _handleCodeLine(_CodeLineToken t) {
    final inList =
        _listStack.isNotEmpty && (t.continuationIndentTwips ?? 0) > 0;
    final container = inList ? _currentListItemBlocks() : _top;
    if (_code != null && !identical(_code!.container, container)) _flushCode();
    if (_code != null &&
        t.language != null &&
        _code!.language != null &&
        _code!.language != t.language) {
      _flushCode();
    }
    _code ??= _CodeAccumulator(container, language: t.language);
    if (_code!.language == null && t.language != null) {
      _code!.language = t.language;
    }
    _code!.addLine(t.line);
  }

  void _flushCode() {
    final c = _code;
    if (c == null) return;
    final text = c.buffer.toString().replaceAll(RegExp(r'\n+$'), '');
    if (text.isNotEmpty) {
      c.container.add(_BLeaf(CodeBlock(text: text, language: c.language)));
    }
    _code = null;
  }

  void _addListItem(_ListItemToken t) {
    var level = math.max(0, t.level);

    if (_listStack.isEmpty && level > 0) {
      warn(
        code: 'list.level.normalized',
        message:
            'List starts at level $level; normalized to level 0 for stability.',
        location: t.loc,
      );
      level = 0;
    }

    // Reduce stack if deeper than needed
    while (_listStack.length > level + 1) {
      _listStack.removeLast();
    }

    // Ordered lists restart when the numbering instance (numId) changes.
    // Unordered lists do not carry visible numbering state, and Word often
    // swaps bullet numIds only to vary glyph definitions. Keep adjacent bullets
    // at the same level together unless a real non-list block interrupts them.
    if (_listStack.length == level + 1) {
      final top = _listStack.last;
      final sameListKind = top.list.ordered == t.ordered;
      final numIdRequiresRestart = t.ordered && top.numId != t.numId;
      if (!sameListKind || numIdRequiresRestart) _listStack.removeLast();
    }

    // Open missing list levels
    while (_listStack.length < level + 1) {
      final atItemLevel = _listStack.length == level;
      final ordered = atItemLevel ? t.ordered : false;
      final start = (t.start != null && atItemLevel) ? t.start! : 1;
      final numberFormat = atItemLevel
          ? t.numberFormat
          : ListNumberFormat.decimal;

      final listBlock = _BList(
        ordered: ordered,
        start: start,
        numberFormat: numberFormat,
        tightness: ListTightness.auto,
      );

      if (_listStack.isEmpty) {
        _top.add(listBlock);
      } else {
        _currentListItemBlocks().add(listBlock);
      }

      _listStack.add(_BListEntry(list: listBlock, numId: t.numId));
    }

    final itemBlocks = _consumePendingAnchorsIntoListItem(t.itemBlocks);
    final item = _BListItem(blocks: itemBlocks.map((b) => _BLeaf(b)));
    _listStack.last.list.items.add(item);
  }

  void _addBlockToCurrentListItem(Block block) {
    final itemBlocks = _currentListItemBlocks();
    if (_pendingAnchors.isEmpty) {
      itemBlocks.add(_BLeaf(block));
      return;
    }
    final blocks = _consumePendingAnchorsIntoListItem([block]);
    itemBlocks.addAll(blocks.map((b) => _BLeaf(b)));
  }

  List<Block> _consumePendingAnchorsIntoListItem(List<Block> blocks) {
    if (_pendingAnchors.isEmpty) return blocks;
    final anchorInlines = _pendingAnchors
        .map<Inline>((anchor) => HtmlInline(anchor.html))
        .toList(growable: false);
    final anchorHtml = _pendingAnchors.map((anchor) => anchor.html).join();
    _pendingAnchors.clear();

    if (blocks.isEmpty) return [HtmlBlock(anchorHtml)];
    final first = blocks.first;
    if (first is ParagraphBlock) {
      return [
        ParagraphBlock([...anchorInlines, ...first.inlines], meta: first.meta),
        ...blocks.skip(1),
      ];
    }
    return [HtmlBlock(anchorHtml), ...blocks];
  }

  void _flushPendingAnchorsTo(List<_BNode> container, {Block? beforeBlock}) {
    if (_pendingAnchors.isEmpty) return;
    final anchors = beforeBlock is HeadingBlock
        ? _pendingAnchors
              .where(
                (anchor) =>
                    !_bookmarkSatisfiedByHeading(anchor.name, beforeBlock),
              )
              .toList(growable: false)
        : List<_PendingAnchor>.of(_pendingAnchors);
    if (anchors.isNotEmpty) {
      container.add(_BLeaf(HtmlBlock(anchors.map((a) => a.html).join())));
    }
    _pendingAnchors.clear();
  }

  bool _bookmarkSatisfiedByHeading(String bookmarkName, HeadingBlock heading) {
    return _githubHeadingSlug(_plainTextForHeadingSlug(heading.inlines)) ==
        bookmarkName;
  }

  void _closeAllLists() {
    _listStack.clear();
  }

  List<_BNode> _currentListItemBlocks() {
    final list = _listStack.last.list;
    if (list.items.isEmpty) {
      list.items.add(_BListItem());
    }
    return list.items.last.blocks;
  }
}

String _plainTextForHeadingSlug(List<Inline> inlines) {
  final buffer = StringBuffer();
  for (final inline in inlines) {
    switch (inline) {
      case TextInline():
        buffer.write(inline.text);
      case CodeInline():
        buffer.write(inline.text);
      case LineBreakInline():
      case SoftBreakInline():
        buffer.write(' ');
      case FootnoteRefInline():
        break;
      case ImageInline():
        buffer.write(inline.alt);
      case LinkInline():
        buffer.write(_plainTextForHeadingSlug(inline.children));
      case StrongInline():
        buffer.write(_plainTextForHeadingSlug(inline.children));
      case EmphInline():
        buffer.write(_plainTextForHeadingSlug(inline.children));
      case StrikeInline():
        buffer.write(_plainTextForHeadingSlug(inline.children));
      case UnderlineInline():
        buffer.write(_plainTextForHeadingSlug(inline.children));
      case SupInline():
        buffer.write(_plainTextForHeadingSlug(inline.children));
      case SubInline():
        buffer.write(_plainTextForHeadingSlug(inline.children));
      case HighlightInline():
        buffer.write(_plainTextForHeadingSlug(inline.children));
      case ColorInline():
        buffer.write(_plainTextForHeadingSlug(inline.children));
      case HtmlInline():
        break;
    }
  }
  return buffer.toString();
}

String _githubHeadingSlug(String text) {
  final buffer = StringBuffer();
  var lastWasSpace = false;
  for (final rune in text.trim().toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    if (char.trim().isEmpty) {
      if (!lastWasSpace && buffer.isNotEmpty) {
        buffer.write('-');
        lastWasSpace = true;
      }
      continue;
    }
    if (char == '-' || char == '_' || _isSlugLetterOrDigit(rune)) {
      buffer.write(char);
      lastWasSpace = false;
    }
  }
  final slug = buffer.toString();
  return slug.endsWith('-') ? slug.substring(0, slug.length - 1) : slug;
}

bool _isSlugLetterOrDigit(int rune) {
  return (rune >= 0x30 && rune <= 0x39) ||
      (rune >= 0x61 && rune <= 0x7A) ||
      rune > 0x7F;
}

enum _VMergeType { none, restart, continueCell }

class _HtmlTableCellInfo {
  _HtmlTableCellInfo({
    required this.tc,
    required this.rowIndex,
    required this.cellIndex,
    required this.colIndex,
    required this.colSpan,
    required this.vMerge,
  });

  final XmlElement tc;
  final int rowIndex;
  final int cellIndex;
  final int colIndex;
  final int colSpan;
  final _VMergeType vMerge;
}

// ... (keep _NumberingModel, _LevelInfo, _CommentIndex, _CommentData, _FieldState)
// Re-pasting for completeness in rewrite

class _NumberingModel {
  _NumberingModel();
  final Map<String, String> _numIdToAbstractId = {};
  final Map<String, Map<int, _LevelInfo>> _abstractLevels = {};
  final Map<String, Map<int, int>> _instanceOverrides = {};

  static _NumberingModel fromXml(XmlDocument? numberingXml) {
    final m = _NumberingModel();
    if (numberingXml == null) return m;

    final abstracts = numberingXml.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'abstractNum')
        .toList();
    for (final abs in abstracts) {
      final absId = abs.attributes
          .firstWhereOrNull((a) => a.name.local == 'abstractNumId')
          ?.value;
      if (absId == null) continue;
      final levelMap = <int, _LevelInfo>{};
      final lvls = abs.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'lvl')
          .toList();
      for (final lvl in lvls) {
        final ilvlStr = lvl.attributes
            .firstWhereOrNull((a) => a.name.local == 'ilvl')
            ?.value;
        final ilvl = int.tryParse(ilvlStr ?? '');
        if (ilvl == null) continue;
        final numFmt =
            lvl.descendants
                .whereType<XmlElement>()
                .firstWhereOrNull((e) => e.name.local == 'numFmt')
                ?.attributes
                .firstWhereOrNull((a) => a.name.local == 'val')
                ?.value ??
            'bullet';

        // The abstract level's starting number (w:lvl/w:start). This only sets
        // where the list begins; it must NOT be treated as a restart signal
        // (genuine restarts arrive as instance lvlOverride/startOverride below).
        final start = lvl.descendants
            .whereType<XmlElement>()
            .firstWhereOrNull((e) => e.name.local == 'start')
            ?.attributes
            .firstWhereOrNull((a) => a.name.local == 'val')
            ?.value;
        final startInt = int.tryParse(start ?? '');

        levelMap[ilvl] = _LevelInfo(numFmt: numFmt, start: startInt);
      }
      m._abstractLevels[absId] = levelMap;
    }

    final nums = numberingXml.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'num')
        .toList();
    for (final num in nums) {
      final numId = num.attributes
          .firstWhereOrNull((a) => a.name.local == 'numId')
          ?.value;
      if (numId == null) continue;
      final absId = num.descendants
          .whereType<XmlElement>()
          .firstWhereOrNull((e) => e.name.local == 'abstractNumId')
          ?.attributes
          .firstWhereOrNull((a) => a.name.local == 'val')
          ?.value;
      if (absId != null) m._numIdToAbstractId[numId] = absId;

      final overrides = num.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == 'lvlOverride',
      );
      for (final ov in overrides) {
        final ilvlStr = ov.attributes
            .firstWhereOrNull((a) => a.name.local == 'ilvl')
            ?.value;
        final ilvl = int.tryParse(ilvlStr ?? '');
        if (ilvl == null) continue;

        final startOverride = ov.descendants
            .whereType<XmlElement>()
            .firstWhereOrNull((e) => e.name.local == 'startOverride')
            ?.attributes
            .firstWhereOrNull((a) => a.name.local == 'val')
            ?.value;
        final startInt = int.tryParse(startOverride ?? '');
        if (startInt == null) continue;

        (m._instanceOverrides[numId] ??= <int, int>{})[ilvl] = startInt;
      }
    }
    return m;
  }

  _LevelInfo? levelInfo({required String numId, required int ilvl}) {
    final absId = _numIdToAbstractId[numId];
    if (absId == null) return null;
    final info = _abstractLevels[absId]?[ilvl];
    if (info == null) return null;
    final override = _instanceOverrides[numId]?[ilvl];
    if (override == null) return info;
    return _LevelInfo(
      numFmt: info.numFmt,
      start: info.start,
      startOverride: override,
    );
  }
}

class _LevelInfo {
  _LevelInfo({required this.numFmt, this.start, this.startOverride});
  final String numFmt;

  /// The abstract level's starting number (`w:lvl/w:start`). Present on most
  /// ordered lists; it sets where the list begins and is NOT a restart signal.
  final int? start;

  /// An instance restart override (`w:num/w:lvlOverride/w:startOverride`).
  /// Distinct from [start] so that an ordinary `w:start` is never mistaken for
  /// a mid-list restart.
  final int? startOverride;

  bool get ordered {
    final f = numFmt.toLowerCase();
    if (f == 'decimal') return true;
    if (f.contains('roman')) return true;
    if (f.contains('letter')) return true;
    if (f == 'upperletter' || f == 'lowerletter') return true;
    if (f == 'upperroman' || f == 'lowerroman') return true;
    return false;
  }

  /// Maps the OOXML `w:numFmt` value to an IR [ListNumberFormat].
  ///
  /// Unrecognized or decimal-like formats fall back to
  /// [ListNumberFormat.decimal].
  ListNumberFormat get numberFormat {
    switch (numFmt.toLowerCase()) {
      case 'lowerletter':
        return ListNumberFormat.lowerAlpha;
      case 'upperletter':
        return ListNumberFormat.upperAlpha;
      case 'lowerroman':
        return ListNumberFormat.lowerRoman;
      case 'upperroman':
        return ListNumberFormat.upperRoman;
      default:
        return ListNumberFormat.decimal;
    }
  }
}

class _CommentIndex {
  _CommentIndex(this._byId);
  final Map<String, _CommentData> _byId;
  static _CommentIndex fromXml(XmlDocument? commentsXml) {
    if (commentsXml == null) return _CommentIndex(const {});
    final map = <String, _CommentData>{};
    final comments = commentsXml.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'comment')
        .toList();
    for (final c in comments) {
      final id = c.attributes
          .firstWhereOrNull((a) => a.name.local == 'id')
          ?.value;
      if (id == null) continue;
      final author =
          c.attributes
              .firstWhereOrNull((a) => a.name.local == 'author')
              ?.value ??
          'Unknown';
      final text = c.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 't')
          .map((e) => e.innerText)
          .join();
      map[id] = _CommentData(author: author, text: text.trim());
    }
    return _CommentIndex(map);
  }

  _CommentData? byId(String id) => _byId[id];
}

class _CommentData {
  _CommentData({required this.author, required this.text});
  final String author;
  final String text;
}

// ---------------------------------------------------------------------------
// Shared hyperlink instruction parsing helpers
// ---------------------------------------------------------------------------

/// Pre-compiled regexes for hyperlink field parsing (avoid recompiling in hot paths)
final _hyperlinkQuotedRe = RegExp(
  r'HYPERLINK\s+"([^"]+)"',
  caseSensitive: false,
);
final _hyperlinkUnquotedRe = RegExp(
  r'HYPERLINK\s+([^\s]+)',
  caseSensitive: false,
);
final _hyperlinkAnchorRe = RegExp(
  r'HYPERLINK\s+\\l\s+"([^"]+)"',
  caseSensitive: false,
);

/// Extracts the URL from a HYPERLINK field instruction.
String? _extractHyperlinkUrl(String instr) {
  final upper = instr.toUpperCase();
  if (!upper.contains('HYPERLINK')) return null;
  final quoted = _hyperlinkQuotedRe.firstMatch(instr);
  if (quoted != null) return quoted.group(1);
  final unquoted = _hyperlinkUnquotedRe.firstMatch(instr);
  if (unquoted != null) {
    final v = unquoted.group(1);
    if (v != null && !v.startsWith(r'\l')) return v;
  }
  return null;
}

/// Extracts the anchor from a HYPERLINK \l field instruction.
String? _extractHyperlinkAnchor(String instr) {
  return _hyperlinkAnchorRe.firstMatch(instr)?.group(1);
}

/// Matches a REF or PAGEREF cross-reference field, capturing the bookmark name.
///
/// The word boundary prevents the `REF` alternative from matching inside
/// `PAGEREF`; the character class stops before field switches like `\h`.
final _refFieldRe = RegExp(
  r'\b(?:REF|PAGEREF)\s+"?([^\s"\\]+)',
  caseSensitive: false,
);

/// Extracts the target bookmark name from a REF/PAGEREF field instruction.
String? _extractRefBookmark(String instr) =>
    _refFieldRe.firstMatch(instr)?.group(1);

class _FieldState {
  final List<_FieldEntry> _stack = [];

  bool get isActive => _stack.isNotEmpty;
  bool get inResult => isActive && _stack.last.inResult;
  bool get sawEnd => isActive && _stack.last.sawEnd;

  List<Inline> get displayInlines => _stack.last.displayInlines;

  void begin({required String loc}) {
    _stack.add(_FieldEntry());
  }

  void separate({required String loc}) {
    if (!isActive) return;
    _stack.last.inResult = true;
  }

  void end({required String loc}) {
    if (!isActive) return;
    _stack.last.sawEnd = true;
  }

  void appendInstr(String t) {
    if (!isActive || inResult) return;
    _stack.last.instr.write(t);
  }

  _FieldResult? finalizeTop({required String loc}) {
    if (!isActive) return null;
    final entry = _stack.removeLast();
    final s = entry.instr.toString();
    final url = _extractHyperlinkUrl(s);
    final anchor = _extractHyperlinkAnchor(s);

    Inline? produced;
    if (url != null) {
      final children = entry.displayInlines.isEmpty
          ? [TextInline(url)]
          : entry.displayInlines;
      produced = LinkInline(url: url, children: children);
    } else if (anchor != null) {
      final children = entry.displayInlines.isEmpty
          ? [TextInline(anchor)]
          : entry.displayInlines;
      produced = LinkInline(url: '#$anchor', children: children);
    } else {
      final ref = _extractRefBookmark(s);
      if (ref != null) {
        final children = entry.displayInlines.isEmpty
            ? [TextInline(ref)]
            : entry.displayInlines;
        produced = LinkInline(url: '#$ref', children: children);
      }
    }

    return _FieldResult(
      produced: produced,
      displayInlines: entry.displayInlines,
    );
  }
}

class _FieldEntry {
  final StringBuffer instr = StringBuffer();
  final List<Inline> displayInlines = [];
  bool inResult = false;
  bool sawEnd = false;
}

class _FieldResult {
  _FieldResult({required this.produced, required this.displayInlines});
  final Inline? produced;
  final List<Inline> displayInlines;
}

// ============================================================================
// NEW: Native OMML to LaTeX Engine
// ============================================================================

class _OmmlToLatex {
  static String convert(XmlElement root) {
    final sb = StringBuffer();
    _walk(root, sb);
    return sb.toString();
  }

  static void _walk(XmlNode n, StringBuffer sb) {
    if (n is! XmlElement) {
      if (n is XmlText) sb.write(n.value);
      return;
    }
    switch (n.name.local) {
      case 't':
        sb.write(n.innerText);
        break;
      case 'f':
        sb.write(r'\frac{');
        _writeChild(n, 'num', sb);
        sb.write(r'}{');
        _writeChild(n, 'den', sb);
        sb.write(r'}');
        break;
      case 'sSup':
        _writeChild(n, 'e', sb);
        sb.write(r'^{');
        _writeChild(n, 'sup', sb);
        sb.write(r'}');
        break;
      case 'sSub':
        _writeChild(n, 'e', sb);
        sb.write(r'_{');
        _writeChild(n, 'sub', sb);
        sb.write(r'}');
        break;
      case 'sSubSup':
        _writeChild(n, 'e', sb);
        sb.write(r'_{');
        _writeChild(n, 'sub', sb);
        sb.write(r'}^{');
        _writeChild(n, 'sup', sb);
        sb.write(r'}');
        break;
      case 'rad':
        final degree = _renderChild(n, 'deg');
        if (degree.isEmpty) {
          sb.write(r'\sqrt{');
        } else {
          sb.write(r'\sqrt[');
          sb.write(degree);
          sb.write(r']{');
        }
        _writeChild(n, 'e', sb);
        sb.write(r'}');
        break;
      case 'nary':
        final naryPr = _childEl(n, 'naryPr');
        sb.write(_naryOp(_attrVal(_childEl(naryPr, 'chr')) ?? '∫'));
        if (_attrVal(_childEl(naryPr, 'subHide')) != '1') {
          final sub = _renderChild(n, 'sub');
          if (sub.isNotEmpty) sb.write('_{$sub}');
        }
        if (_attrVal(_childEl(naryPr, 'supHide')) != '1') {
          final sup = _renderChild(n, 'sup');
          if (sup.isNotEmpty) sb.write('^{$sup}');
        }
        sb.write(r'{');
        _writeChild(n, 'e', sb);
        sb.write(r'}');
        break;
      case 'd':
        final dPr = _childEl(n, 'dPr');
        sb.write('\\left${_delimLatex(dPr, 'begChr', '(')} ');
        final es = _childEls(n, 'e').toList();
        final sep = _delimLatex(dPr, 'sepChr', '|');
        for (var i = 0; i < es.length; i++) {
          if (i > 0) sb.write(sep);
          _walk(es[i], sb);
        }
        sb.write(' \\right${_delimLatex(dPr, 'endChr', ')')}');
        break;
      case 'm':
        sb.write(r'\begin{matrix}');
        final rows = _childEls(n, 'mr').toList();
        for (var r = 0; r < rows.length; r++) {
          final cells = _childEls(rows[r], 'e').toList();
          for (var c = 0; c < cells.length; c++) {
            if (c > 0) sb.write(' & ');
            _walk(cells[c], sb);
          }
          if (r < rows.length - 1) sb.write(r' \\ ');
        }
        sb.write(r'\end{matrix}');
        break;
      case 'acc':
        sb.write(_accentCmd(_attrVal(_childEl(_childEl(n, 'accPr'), 'chr'))));
        sb.write(r'{');
        _writeChild(n, 'e', sb);
        sb.write(r'}');
        break;
      case 'bar':
        final barPos = _attrVal(_childEl(_childEl(n, 'barPr'), 'pos'));
        sb.write(barPos == 'bot' ? r'\underline{' : r'\overline{');
        _writeChild(n, 'e', sb);
        sb.write(r'}');
        break;
      case 'groupChr':
        final gPr = _childEl(n, 'groupChrPr');
        final under =
            (_attrVal(_childEl(gPr, 'pos')) ?? 'bot') != 'top' &&
            _attrVal(_childEl(gPr, 'chr')) != '⏞';
        sb.write(under ? r'\underbrace{' : r'\overbrace{');
        _writeChild(n, 'e', sb);
        sb.write(r'}');
        break;
      case 'func':
        _writeChild(n, 'fName', sb);
        sb.write(' ');
        _writeChild(n, 'e', sb);
        break;
      case 'limLow':
        _writeChild(n, 'e', sb);
        sb.write(r'_{');
        _writeChild(n, 'lim', sb);
        sb.write(r'}');
        break;
      case 'limUpp':
        _writeChild(n, 'e', sb);
        sb.write(r'^{');
        _writeChild(n, 'lim', sb);
        sb.write(r'}');
        break;
      default:
        for (final c in n.children) {
          _walk(c, sb);
        }
    }
  }

  static String _renderChild(XmlElement parent, String localName) {
    final sb = StringBuffer();
    _writeChild(parent, localName, sb);
    return sb.toString();
  }

  static void _writeChild(
    XmlElement parent,
    String localName,
    StringBuffer sb,
  ) {
    final child = parent.children.whereType<XmlElement>().firstWhereOrNull(
      (e) => e.name.local == localName,
    );
    if (child != null) {
      _walk(child, sb);
    }
  }

  static XmlElement? _childEl(XmlElement? parent, String localName) {
    if (parent == null) return null;
    return parent.children.whereType<XmlElement>().firstWhereOrNull(
      (e) => e.name.local == localName,
    );
  }

  static Iterable<XmlElement> _childEls(XmlElement parent, String localName) {
    return parent.children.whereType<XmlElement>().where(
      (e) => e.name.local == localName,
    );
  }

  static String? _attrVal(XmlElement? el, [String localName = 'val']) {
    if (el == null) return null;
    return el.attributes
        .firstWhereOrNull((a) => a.name.local == localName)
        ?.value;
  }

  /// Maps an OMML n-ary operator character to its LaTeX command.
  static String _naryOp(String chr) {
    switch (chr) {
      case '∑':
        return r'\sum';
      case '∏':
        return r'\prod';
      case '∐':
        return r'\coprod';
      case '∫':
        return r'\int';
      case '∬':
        return r'\iint';
      case '∭':
        return r'\iiint';
      case '∮':
        return r'\oint';
      case '⋀':
        return r'\bigwedge';
      case '⋁':
        return r'\bigvee';
      case '⋂':
        return r'\bigcap';
      case '⋃':
        return r'\bigcup';
      default:
        return r'\int';
    }
  }

  /// Maps an OMML accent character to its LaTeX accent command.
  static String _accentCmd(String? chr) {
    switch (chr) {
      case '̃': // combining tilde
        return r'\tilde';
      case '̄': // combining macron
      case '̅': // combining overline
        return r'\bar';
      case '̇': // combining dot above
        return r'\dot';
      case '̈': // combining diaeresis
        return r'\ddot';
      case '⃗': // combining right arrow above
        return r'\vec';
      case '̌': // combining caron
        return r'\check';
      case '̆': // combining breve
        return r'\breve';
      default: // combining circumflex (OMML default) and unknowns
        return r'\hat';
    }
  }

  /// Maps an OMML delimiter character to a LaTeX-safe delimiter.
  static String _delimLatex(XmlElement? pr, String attr, String fallback) {
    final raw = _attrVal(_childEl(pr, attr)) ?? fallback;
    switch (raw) {
      case '':
        return '.';
      case '{':
        return r'\{';
      case '}':
        return r'\}';
      case '|':
        return '|';
      case '‖':
        return r'\|';
      case '⟨':
        return r'\langle';
      case '⟩':
        return r'\rangle';
      case '⌈':
        return r'\lceil';
      case '⌉':
        return r'\rceil';
      case '⌊':
        return r'\lfloor';
      case '⌋':
        return r'\rfloor';
      default:
        return raw;
    }
  }
}
