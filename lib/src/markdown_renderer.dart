// markdown_renderer.dart
//
// Production-grade Markdown renderer for the Docx IR.
// - Deterministic output (stable spacing)
// - Handles nested lists, blockquotes, code fences safely
// - Renders Markdown tables when safe, otherwise HTML tables
// - Emits GFM-style footnotes
//
// Assumes the following exist (from your earlier skeleton):
//   - config.dart: DocxToMarkdownConfig, TableMode, UnderlineMode, MarkdownFlavor, hooks
//   - ir.dart: Document, Block/Inline types, TableBlock/TableGrid, FootnoteDefinition
//
// This file intentionally has ZERO OOXML/XML knowledge.

import 'package:docx_to_markdown/src/config.dart';
import 'package:docx_to_markdown/src/ir.dart';

/// Renders the intermediate [Document] structure into a Markdown string.
///
/// Design goals:
/// - **Isolation:** Has zero knowledge of OOXML; it only understands the IR.
/// - **Determinism:** Produces stable output with consistent spacing.
/// - **Safety:** Escapes or normalizes content to prevent Markdown injection.
class MarkdownRenderer {
  /// Creates a renderer with the given configuration.
  ///
  /// The [config] controls all rendering decisions: output flavor, table mode,
  /// underline handling, line breaks, and more.
  MarkdownRenderer({required this.config});

  /// The configuration controlling rendering behavior.
  ///
  /// Immutable once set. To change settings, create a new [MarkdownRenderer].
  final DocxToMarkdownConfig config;

  // Pre-compiled regexes to avoid recompilation in hot paths
  static final _urlNeedsAngleRe = RegExp(r'[\s()]');
  static final _blankLineRe = RegExp(r'^\s*>+\s*$');
  static final _trailingWhitespaceRe = RegExp(r'\s+$');
  static final _atxHeadingRe = RegExp(r'^(#{1,6})\s');
  static final _blockquoteRe = RegExp(r'^>\s');
  static final _unorderedListRe = RegExp(r'^(-|\*|\+)\s');
  static final _orderedListRe = RegExp(r'^\d+[.)]\s');
  static final _fencedCodeRe = RegExp(r'^```');
  static final _horizontalRuleRe = RegExp(r'^(---|\*\*\*|___)\s*$');

  /// Converts the document to a Markdown string using the configured settings.
  ///
  /// Process:
  /// 1. Traverses blocks and renders them into a line writer.
  /// 2. Appends footnote definitions (if enabled).
  /// 3. Emits warnings as HTML comments when configured.
  String render(Document document) {
    final w = _LineWriter(
      trimTrailingWhitespace: config.trimTrailingWhitespace,
      preserveHardBreaks: config.lineBreakStyle == LineBreakStyle.hardBreak,
    );
    final root = _RenderContext.root();

    _renderBlocks(document.blocks, w, root, separateWithBlankLine: true);

    // Footnotes (GFM extension; many renderers support it even if flavor=commonmark)
    if (config.includeFootnotes && document.footnotes.isNotEmpty) {
      w.ensureBlankLine(root);
      w.writelnRaw('---');
      w.ensureBlankLine(root);

      final keys = document.footnotes.keys.toList()
        ..sort((a, b) {
          final ai = int.tryParse(a);
          final bi = int.tryParse(b);
          if (ai != null && bi != null) return ai.compareTo(bi);
          if (ai != null) return -1;
          if (bi != null) return 1;
          return a.compareTo(b);
        });

      for (final id in keys) {
        _renderFootnoteDefinition(id, document.footnotes[id]!, w);
      }
    }

    if (config.emitWarningsAsHtmlComments && document.warnings.isNotEmpty) {
      w.ensureBlankLine(root);
      for (final warning in document.warnings) {
        final text = _escapeHtmlComment(
          '${warning.severity} ${warning.code} ${warning.location}: ${warning.message}',
        );
        w.writelnRaw('<!-- $text -->');
      }
    }

    return w.toString();
  }

  // ---------------------------------------------------------------------------
  // Blocks
  // ---------------------------------------------------------------------------

  void _renderBlocks(
    List<Block> blocks,
    _LineWriter w,
    _RenderContext ctx, {
    required bool separateWithBlankLine,
  }) {
    for (var i = 0; i < blocks.length; i++) {
      if (i > 0 && separateWithBlankLine) {
        w.ensureBlankLine(ctx);
      }
      _renderBlock(blocks[i], w, ctx);
    }
  }

  /// Dispatches rendering for a single block.
  ///
  /// Each block type handles its own escaping and formatting.
  void _renderBlock(Block block, _LineWriter w, _RenderContext ctx) {
    if (block is ParagraphBlock) {
      final lines = _renderParagraphLines(block.inlines, canBreak: true);
      for (final line in lines) {
        final safe = _escapeParagraphLineStartIfNeeded(line);
        w.writeln(safe, ctx);
      }
      return;
    }

    if (block is HeadingBlock) {
      final lvl = block.level.clamp(1, 6);
      final hashes = '#' * lvl;

      // Headings should not contain hard line breaks; render breaks as <br>
      final text = _renderInlineGroupAsText(
        block.inlines,
        canBreak: false,
        breakAsBr: true,
      ).trimRight();

      w.writeln('$hashes ${_escapeParagraphLineStartIfNeeded(text)}', ctx);
      return;
    }

    if (block is HorizontalRuleBlock) {
      w.writeln('---', ctx);
      return;
    }

    if (block is CodeBlock) {
      _renderFencedCodeBlock(w, ctx, block.text, language: block.language);
      return;
    }

    if (block is QuoteBlock) {
      // Add a blockquote marker AFTER any existing prefix (works for list->quote and quote->list nesting)
      final qCtx = ctx.addPrefix('> ', entersBlockQuote: true);
      _renderBlocks(block.blocks, w, qCtx, separateWithBlankLine: true);
      return;
    }

    if (block is ListBlock) {
      _renderListBlock(block, w, ctx);
      return;
    }

    if (block is TableBlock) {
      _renderTableBlock(block, w, ctx);
      return;
    }

    if (block is MathBlock) {
      _renderMathBlock(block, w, ctx);
      return;
    }

    if (block is HtmlBlock) {
      final lines = block.html.split('\n');
      for (final line in lines) {
        // HTML blocks are passed through
        w.writeln(line, ctx);
      }
      return;
    }

    // Defensive fallback (should be rare if IR is complete)
    w.writeln('<!-- Unsupported block ${block.runtimeType} -->', ctx);
  }

  void _renderMathBlock(MathBlock block, _LineWriter w, _RenderContext ctx) {
    final content = block.latexOrText;
    // If content already includes $$, use \[ \] to avoid fence conflicts.
    final useBracket = content.contains(r'$$');

    if (useBracket) {
      w.writeln(r'\[', ctx);
      for (final line in content.split('\n')) {
        w.writeln(line, ctx);
      }
      w.writeln(r'\]', ctx);
      return;
    }

    // $$ ... $$ block
    w.writeln(r'$$', ctx);
    for (final line in content.split('\n')) {
      w.writeln(line, ctx);
    }
    w.writeln(r'$$', ctx);
  }

  void _renderFencedCodeBlock(
    _LineWriter w,
    _RenderContext ctx,
    String code, {
    String? language,
  }) {
    // Choose a fence longer than any run of backticks in code.
    final longestRun = _longestRunOf(code, '`');
    final fenceLen = (longestRun + 1).clamp(3, 99);
    final fence = '`' * fenceLen;

    final lang = (language ?? '').trim();
    w.writeln(lang.isEmpty ? fence : '$fence $lang', ctx);

    // Preserve code lines as-is (no Markdown escaping)
    // Normalize newlines to \n for stable output.
    final normalized = code.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');

    for (final line in lines) {
      w.writeln(line, ctx);
    }

    w.writeln(fence, ctx);
  }

  // ---------------------------------------------------------------------------
  // Lists
  // ---------------------------------------------------------------------------

  /// Renders a list with correct indentation and spacing.
  ///
  /// - Respects [OrderedListNumbering] configuration.
  /// - Decides tight vs loose spacing based on item content.
  /// - Recursively renders nested lists with increased indentation.
  void _renderListBlock(ListBlock list, _LineWriter w, _RenderContext ctx) {
    // Decide if list should be "loose" (blank line between items / block separation)
    final loose = _isLooseList(list);
    final depth = ctx.listDepth;

    for (var i = 0; i < list.items.length; i++) {
      final item = list.items[i];
      final index = _orderedListIndexForItem(list, i);

      if (i > 0 && loose) {
        w.ensureBlankLine(ctx);
      }

      _renderListItem(
        item,
        w,
        ctx,
        ordered: list.ordered,
        index: index,
        listDepth: depth,
        loose: loose,
      );
    }
  }

  int _orderedListIndexForItem(ListBlock list, int itemIndex) {
    if (!list.ordered) return itemIndex + 1;
    if (config.orderedListNumbering == OrderedListNumbering.alwaysOne) {
      return 1;
    }
    return list.start + itemIndex;
  }

  bool _isLooseList(ListBlock list) {
    if (list.tightness == ListTightness.tight) return false;
    if (list.tightness == ListTightness.loose) return true;
    if (config.tightLists) return false;

    // CommonMark-ish heuristic:
    // A list is loose if ANY item has multiple blocks, or any paragraph contains a hard line break.
    for (final item in list.items) {
      if (item.blocks.length > 1) return true;

      if (item.blocks.length == 1 && item.blocks.first is ParagraphBlock) {
        final p = item.blocks.first as ParagraphBlock;
        if (_containsHardBreak(p.inlines)) return true;
      }
    }
    return false;
  }

  bool _containsHardBreak(List<Inline> inlines) {
    for (final i in inlines) {
      if (i is LineBreakInline) return true;

      if (i is StrongInline && _containsHardBreak(i.children)) return true;
      if (i is EmphInline && _containsHardBreak(i.children)) return true;
      if (i is StrikeInline && _containsHardBreak(i.children)) return true;
      if (i is UnderlineInline && _containsHardBreak(i.children)) return true;
      if (i is SupInline && _containsHardBreak(i.children)) return true;
      if (i is SubInline && _containsHardBreak(i.children)) return true;
      if (i is LinkInline && _containsHardBreak(i.children)) return true;
    }
    return false;
  }

  void _renderListItem(
    ListItem item,
    _LineWriter w,
    _RenderContext ctx, {
    required bool ordered,
    required int index,
    required int listDepth,
    required bool loose,
  }) {
    final marker = ordered
        ? '$index.'
        : config.bulletMarkers[listDepth % config.bulletMarkers.length];
    final markerPrefix = '${ctx.prefix}$marker ';
    final hangingPrefix = ctx.prefix + ' ' * (marker.length + 1);
    final listIndent = _listIndentForMarker(marker);

    if (item.blocks.isEmpty) {
      w.writelnRaw(markerPrefix.trimRight());
      return;
    }

    // First block special-case: if it's a paragraph, put it on the same line as the marker.
    final first = item.blocks.first;
    var startAt = 0;

    if (first is ParagraphBlock) {
      final paraLines = _renderParagraphLines(first.inlines, canBreak: true);
      if (paraLines.isEmpty) {
        w.writelnRaw(markerPrefix.trimRight());
      } else {
        // First line
        w.writelnRaw(
          markerPrefix + _escapeParagraphLineStartIfNeeded(paraLines.first),
        );
        // Continuation lines aligned under text
        for (final line in paraLines.skip(1)) {
          w.writelnRaw(hangingPrefix + _escapeParagraphLineStartIfNeeded(line));
        }
      }
      startAt = 1;
    } else {
      // Non-paragraph first block: render it starting on the next line under hanging indent.
      w.writelnRaw(markerPrefix.trimRight());
    }

    // Render remaining blocks (and/or the first block if it wasn't a paragraph)
    final itemCtx = ctx
        .withPrefix(' ' * listIndent)
        .withListDepth(ctx.listDepth + 1);

    for (var i = startAt; i < item.blocks.length; i++) {
      final b = item.blocks[i];

      // Separate blocks inside list items.
      // For tight lists (loose=false), avoid extra blank lines unless necessary.
      if (i > startAt) {
        w.ensureBlankLine(itemCtx);
      } else if (startAt == 0) {
        // If the first block wasn't a paragraph (marker-only first line), separate marker and content.
        w.ensureBlankLine(itemCtx);
      }

      // For tight list items with a single paragraph only, we never reach here.
      _renderBlock(b, w, itemCtx);
    }

    // If the list is tight, don't force blank lines between items.
    // Parent caller handles inter-item separation when loose==true.
    if (loose) {
      // Nothing here; caller inserts blank line between items.
    }
  }

  int _listIndentForMarker(String marker) {
    final minIndent = marker.length + 1;
    if (config.listIndent <= minIndent) return minIndent;
    return config.listIndent;
  }

  // ---------------------------------------------------------------------------
  // Tables
  // ---------------------------------------------------------------------------

  /// Renders a table, choosing Markdown or HTML based on [TableMode].
  ///
  /// - `htmlOnly` => always HTML
  /// - `markdownOnly` => always Markdown (may lose merged cells)
  /// - `auto` => Markdown for simple tables, HTML for complex tables
  void _renderTableBlock(TableBlock table, _LineWriter w, _RenderContext ctx) {
    var mode = config.tableMode;
    if (config.flavor == MarkdownFlavor.commonmark &&
        config.tableMode == TableMode.auto) {
      mode = TableMode.htmlOnly;
    }

    final canMarkdown = _canRenderMarkdownTable(table);

    if (mode == TableMode.htmlOnly) {
      _renderHtmlTable(table, w, ctx);
      return;
    }

    if (mode == TableMode.markdownOnly) {
      _renderMarkdownTable(table, w, ctx, force: true);
      return;
    }

    // auto
    if (mode == TableMode.auto) {
      if (canMarkdown) {
        _renderMarkdownTable(table, w, ctx, force: false);
      } else {
        _renderHtmlTable(table, w, ctx);
      }
    }
  }

  bool _canRenderMarkdownTable(TableBlock table) {
    final rows = table.grid.rows;
    if (rows.isEmpty) return false;

    final cols = rows.first.cells.length;
    if (cols == 0) return false;

    // Rectangular
    if (rows.any((r) => r.cells.length != cols)) return false;

    // No spans
    for (final row in rows) {
      for (final cell in row.cells) {
        if (cell.rowSpan != 1 || cell.colSpan != 1) return false;
      }
    }

    // Only simple content: paragraphs only
    for (final row in rows) {
      for (final cell in row.cells) {
        for (final b in cell.blocks) {
          if (b is! ParagraphBlock) return false;
        }
      }
    }

    return true;
  }

  void _renderMarkdownTable(
    TableBlock table,
    _LineWriter w,
    _RenderContext ctx, {
    required bool force,
  }) {
    final rows = table.grid.rows;
    if (rows.isEmpty) return;

    final cols = rows.first.cells.length;
    if (cols == 0) return;

    final headerIndex = rows.indexWhere(
      (row) => row.isHeader || row.cells.any((c) => c.isHeader),
    );
    final header = headerIndex == -1 ? rows.first : rows[headerIndex];
    final headerCells = header.cells.map(_renderTableCellMarkdown).toList();
    while (headerCells.length < cols) {
      headerCells.add('');
    }
    if (headerCells.length > cols && !force) {
      headerCells.removeRange(cols, headerCells.length);
    }
    w.writeln('| ${headerCells.join(' | ')} |', ctx);

    // Separator row
    final sep = <String>[];
    for (var i = 0; i < cols; i++) {
      final align = i < table.alignments.length
          ? table.alignments[i]
          : TableAlign.auto;
      switch (align) {
        case TableAlign.center:
          sep.add(':---:');
          break;
        case TableAlign.right:
          sep.add('---:');
          break;
        case TableAlign.left:
          sep.add(':---');
          break;
        case TableAlign.auto:
          sep.add('---');
          break;
      }
    }
    w.writeln('|${sep.join('|')}|', ctx);

    final bodyRows = <TableRow>[];
    if (headerIndex == -1) {
      bodyRows.addAll(rows.skip(1));
    } else {
      for (var i = 0; i < rows.length; i++) {
        if (i == headerIndex) continue;
        bodyRows.add(rows[i]);
      }
    }
    for (final row in bodyRows) {
      final cells = row.cells.map(_renderTableCellMarkdown).toList();
      // Defensive: normalize column count
      while (cells.length < cols) {
        cells.add('');
      }
      if (cells.length > cols) {
        // Force mode keeps extra columns; auto mode should have prevented this.
        if (!force) cells.removeRange(cols, cells.length);
      }
      w.writeln('| ${cells.join(' | ')} |', ctx);
    }
  }

  String _renderTableCellMarkdown(TableCell cell) {
    // Convert paragraphs to inline text, using <br> for hard breaks and paragraph separation.
    final parts = <String>[];

    for (final b in cell.blocks) {
      if (b is ParagraphBlock) {
        final txt = _renderInlineGroupAsText(
          b.inlines,
          canBreak: false,
          breakAsBr: true,
        ).trim();

        if (txt.isNotEmpty) parts.add(txt);
      } else if (b is ListBlock) {
        // Flatten nested lists to pseudo-HTML lists (Markdown tables don't support blocks).
        for (final item in b.items) {
          final itemText = item.blocks.map(_renderBlockAsPlainText).join(' ');
          final marker = b.ordered ? '1.' : '&bull;';
          parts.add('$marker $itemText');
        }
      } else {
        // Fallback: render as plain text, then treat as a single chunk
        parts.add(_renderBlockAsPlainText(b).trim());
      }
    }

    var joined = parts.join('<br>');

    // Escape table pipe and normalize whitespace
    joined = joined.replaceAll('|', r'\|').replaceAll('\n', '<br>');

    return joined;
  }

  void _renderHtmlTable(TableBlock table, _LineWriter w, _RenderContext ctx) {
    final rows = table.grid.rows;
    if (rows.isEmpty) return;

    w.writeln('<table>', ctx);

    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      w.writeln('  <tr>', ctx);

      for (final cell in row.cells) {
        final tag = (r == 0) ? 'th' : 'td';

        final attrs = StringBuffer();
        if (cell.colSpan != 1) attrs.write(' colspan="${cell.colSpan}"');
        if (cell.rowSpan != 1) attrs.write(' rowspan="${cell.rowSpan}"');

        final html = _renderCellHtml(cell);

        w.writeln('    <$tag${attrs.toString()}>$html</$tag>', ctx);
      }

      w.writeln('  </tr>', ctx);
    }

    w.writeln('</table>', ctx);
  }

  String _renderCellHtml(TableCell cell) {
    // Render blocks into HTML suitable inside <td>/<th>.
    // We keep it simple and safe (HTML-escape text nodes, emit basic tags for formatting).
    final parts = <String>[];

    for (final b in cell.blocks) {
      if (b is ParagraphBlock) {
        final html = _renderInlineGroupAsHtml(b.inlines).trim();
        if (html.isNotEmpty) parts.add(html);
      } else if (b is CodeBlock) {
        final escaped = _escapeHtml(b.text);
        parts.add('<pre><code>$escaped</code></pre>');
      } else if (b is ListBlock) {
        // Minimal HTML list fallback inside table cell
        parts.add(_renderListAsHtml(b));
      } else {
        parts.add(_escapeHtml(_renderBlockAsPlainText(b)));
      }
    }

    return parts.join('<br/>');
  }

  String _renderListAsHtml(ListBlock list) {
    final tag = list.ordered ? 'ol' : 'ul';
    final sb = StringBuffer()..write('<$tag>');

    for (final item in list.items) {
      sb.write('<li>');

      // Flatten item blocks to HTML
      final blocksHtml = <String>[];
      for (final b in item.blocks) {
        if (b is ParagraphBlock) {
          final html = _renderInlineGroupAsHtml(b.inlines);
          if (html.trim().isNotEmpty) blocksHtml.add(html);
        } else if (b is ListBlock) {
          blocksHtml.add(_renderListAsHtml(b));
        } else if (b is CodeBlock) {
          blocksHtml.add('<pre><code>${_escapeHtml(b.text)}</code></pre>');
        } else {
          blocksHtml.add(_escapeHtml(_renderBlockAsPlainText(b)));
        }
      }

      sb.write(blocksHtml.join('<br/>'));
      sb.write('</li>');
    }

    sb.write('</$tag>');
    return sb.toString();
  }

  // ---------------------------------------------------------------------------
  // Inlines
  // ---------------------------------------------------------------------------

  List<String> _renderParagraphLines(
    List<Inline> inlines, {
    required bool canBreak,
  }) {
    // Produces multiple lines when encountering LineBreakInline.
    final b = _InlineBuffer();

    for (final node in inlines) {
      _emitInline(node, b, canBreak: canBreak);
    }

    return b.lines;
  }

  /// Renders a group of inlines into a single string.
  /// - If canBreak=false, LineBreakInline becomes <br> (or ignored depending on breakAsBr)
  String _renderInlineGroupAsText(
    List<Inline> inlines, {
    required bool canBreak,
    required bool breakAsBr,
  }) {
    final b = _InlineBuffer();

    for (final node in inlines) {
      _emitInline(
        node,
        b,
        canBreak: canBreak,
        breakAsBrWhenNoBreakAllowed: breakAsBr,
      );
    }

    // If canBreak was true, buffer may contain multiple lines. For single-string rendering,
    // join them with newline (rare for headings). Caller decides; here we join with '\n'.
    return b.lines.join('\n');
  }

  void _emitInline(
    Inline node,
    _InlineBuffer out, {
    required bool canBreak,
    bool breakAsBrWhenNoBreakAllowed = true,
  }) {
    if (node is TextInline) {
      out.write(_escapeMarkdownText(node.text));
      return;
    }

    if (node is HtmlInline) {
      out.write(node.html);
      return;
    }

    if (node is LineBreakInline) {
      if (canBreak) {
        switch (config.lineBreakStyle) {
          case LineBreakStyle.hardBreak:
            out.hardBreak();
            break;
          case LineBreakStyle.htmlBr:
            out.write('<br/>');
            out.softBreak();
            break;
          case LineBreakStyle.newline:
            out.softBreak();
            break;
        }
      } else {
        out.write(breakAsBrWhenNoBreakAllowed ? '<br>' : ' ');
      }
      return;
    }

    if (node is CodeInline) {
      out.write(_renderCodeSpan(node.text));
      return;
    }

    if (node is FootnoteRefInline) {
      out.write('[^${node.id}]');
      return;
    }

    if (node is LinkInline) {
      final text = _renderInlineGroupAsText(
        node.children,
        canBreak: false,
        breakAsBr: true,
      );
      final url = config.hooks.rewriteLinkTarget?.call(node.url) ?? node.url;
      out.write('[${_escapeLinkText(text)}](${_escapeLinkDestination(url)})');
      return;
    }

    if (node is ImageInline) {
      final alt = _escapeLinkText(node.alt);
      final src0 = config.hooks.rewriteImageTarget?.call(node.src) ?? node.src;
      final src = _escapeLinkDestination(src0);

      if (config.maxImageWidth > 0 &&
          config.imageSizeMode != ImageSizeMode.none) {
        switch (config.imageSizeMode) {
          case ImageSizeMode.obsidian:
            out.write('![$alt]($src =${config.maxImageWidth}x)');
            break;
          case ImageSizeMode.pandoc:
            out.write('![$alt]($src){ width=${config.maxImageWidth}px }');
            break;
          case ImageSizeMode.none:
            break;
        }
      } else if (config.maxImageWidth > 0) {
        // If user requested max width, emit HTML <img> for portability.
        out.write(
          '<img src="${_escapeHtmlAttr(src0)}" alt="${_escapeHtmlAttr(node.alt)}" '
          'width="${config.maxImageWidth}"/>',
        );
      } else {
        out.write('![$alt]($src)');
      }
      return;
    }

    // Formatting wrappers
    if (node is StrongInline) {
      final inner = _renderInlineGroupAsText(
        node.children,
        canBreak: false,
        breakAsBr: true,
      );
      out.write('**$inner**');
      return;
    }

    if (node is EmphInline) {
      final inner = _renderInlineGroupAsText(
        node.children,
        canBreak: false,
        breakAsBr: true,
      );
      out.write('*$inner*');
      return;
    }

    if (node is StrikeInline) {
      final inner = _renderInlineGroupAsText(
        node.children,
        canBreak: false,
        breakAsBr: true,
      );
      out.write('~~$inner~~');
      return;
    }

    if (node is UnderlineInline) {
      final inner = _renderInlineGroupAsText(
        node.children,
        canBreak: false,
        breakAsBr: true,
      );

      switch (config.underlineMode) {
        case UnderlineMode.ignore:
          out.write(inner);
          return;
        case UnderlineMode.plusPlus:
          out.write('++$inner++');
          return;
        case UnderlineMode.html:
          out.write('<u>$inner</u>');
          return;
      }
    }

    if (node is SupInline) {
      final inner = _renderInlineGroupAsText(
        node.children,
        canBreak: false,
        breakAsBr: true,
      );
      out.write('<sup>$inner</sup>');
      return;
    }

    if (node is SubInline) {
      final inner = _renderInlineGroupAsText(
        node.children,
        canBreak: false,
        breakAsBr: true,
      );
      out.write('<sub>$inner</sub>');
      return;
    }

    // Defensive fallback
    out.write('');
  }

  // HTML inline renderer (used for HTML tables)
  String _renderInlineGroupAsHtml(List<Inline> inlines) {
    final sb = StringBuffer();
    for (final node in inlines) {
      sb.write(_renderInlineAsHtml(node));
    }
    return sb.toString();
  }

  String _renderInlineAsHtml(Inline node) {
    if (node is TextInline) return _escapeHtml(node.text);
    if (node is HtmlInline) return node.html;
    if (node is LineBreakInline) return '<br/>';
    if (node is CodeInline) return '<code>${_escapeHtml(node.text)}</code>';
    if (node is FootnoteRefInline) return _escapeHtml('[^${node.id}]');

    if (node is StrongInline) {
      return '<strong>${_renderInlineGroupAsHtml(node.children)}</strong>';
    }
    if (node is EmphInline) {
      return '<em>${_renderInlineGroupAsHtml(node.children)}</em>';
    }
    if (node is StrikeInline) {
      return '<del>${_renderInlineGroupAsHtml(node.children)}</del>';
    }
    if (node is UnderlineInline) {
      return '<u>${_renderInlineGroupAsHtml(node.children)}</u>';
    }
    if (node is SupInline) {
      return '<sup>${_renderInlineGroupAsHtml(node.children)}</sup>';
    }
    if (node is SubInline) {
      return '<sub>${_renderInlineGroupAsHtml(node.children)}</sub>';
    }

    if (node is LinkInline) {
      final url0 = config.hooks.rewriteLinkTarget?.call(node.url) ?? node.url;
      final url = _escapeHtmlAttr(url0);
      final text = _renderInlineGroupAsHtml(node.children);
      return '<a href="$url">$text</a>';
    }

    if (node is ImageInline) {
      final src0 = config.hooks.rewriteImageTarget?.call(node.src) ?? node.src;
      final src = _escapeHtmlAttr(src0);
      final alt = _escapeHtmlAttr(node.alt);

      if (config.maxImageWidth > 0) {
        return '<img src="$src" alt="$alt" width="${config.maxImageWidth}"/>';
      }
      return '<img src="$src" alt="$alt"/>';
    }

    return '';
  }

  // ---------------------------------------------------------------------------
  // Footnotes
  // ---------------------------------------------------------------------------

  void _renderFootnoteDefinition(
    String id,
    FootnoteDefinition def,
    _LineWriter w,
  ) {
    // Render footnote blocks to lines (tight separation inside footnote is okay).
    final tmp = _LineWriter(
      trimTrailingWhitespace: config.trimTrailingWhitespace,
      preserveHardBreaks: config.lineBreakStyle == LineBreakStyle.hardBreak,
    );
    final ctx = _RenderContext.root();
    _renderBlocks(def.blocks, tmp, ctx, separateWithBlankLine: true);

    final lines = tmp.linesTrimmedForFootnotes();
    if (lines.isEmpty) {
      w.writelnRaw('[^$id]:');
      return;
    }

    // First line after the label
    w.writelnRaw('[^$id]: ${lines.first}');

    // Continuations: indent by 4 spaces (including blank lines to keep content inside the footnote)
    for (final line in lines.skip(1)) {
      w.writelnRaw(line.isEmpty ? '    ' : '    $line');
    }
  }

  // ---------------------------------------------------------------------------
  // Escaping + helpers
  // ---------------------------------------------------------------------------

  String _escapeMarkdownText(String text) {
    // Conservative escaping for Markdown inline text.
    // Note: we intentionally do NOT escape '>' here because it’s only special at line start.
    return text
        .replaceAll('\\', r'\\')
        .replaceAll('`', r'\`')
        .replaceAll('*', r'\*')
        .replaceAll('_', r'\_')
        .replaceAll('[', r'\[')
        .replaceAll(']', r'\]')
        .replaceAll('~', r'\~')
        .replaceAll('&', r'\&')
        .replaceAll('<', r'\<')
        .replaceAll('>', r'\>');
  }

  String _escapeLinkText(String text) {
    // Text inside [...] needs at least bracket escaping; reuse full escape.
    return _escapeMarkdownText(text);
  }

  String _escapeLinkDestination(String url) {
    // Keep it robust:
    // - trim
    // - wrap in <...> if it contains whitespace or parentheses (common Markdown pitfall)
    // - encode literal < and > to avoid breaking wrapper
    final u = url.trim();
    final needsAngle = _urlNeedsAngleRe.hasMatch(u);

    if (!needsAngle) return u;

    final safe = u
        .replaceAll('<', '%3C')
        .replaceAll('>', '%3E')
        .replaceAll(' ', '%20');

    return '<$safe>';
  }

  String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  String _escapeHtmlAttr(String text) => _escapeHtml(text);

  String _escapeHtmlComment(String text) {
    var cleaned = text.replaceAll('\n', ' ').replaceAll('\r', ' ').trim();
    cleaned = cleaned.replaceAll('--', '- -');
    if (cleaned.endsWith('-')) cleaned = '$cleaned ';
    return cleaned;
  }

  String _renderCodeSpan(String code) {
    // Inline code spans: choose a fence longer than any run of backticks.
    var normalized = code.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    // Code spans must not contain newlines in many renderers; normalize to spaces.
    normalized = normalized.replaceAll('\n', ' ');

    final longestRun = _longestRunOf(normalized, '`');
    final fenceLen = (longestRun + 1).clamp(1, 99);
    final fence = '`' * fenceLen;

    // If code starts/ends with space, pad with a space inside fences (CommonMark rule)
    final needsPadding = normalized.startsWith(' ') || normalized.endsWith(' ');
    final content = needsPadding ? ' $normalized ' : normalized;

    return '$fence$content$fence';
  }

  int _longestRunOf(String s, String char) {
    var best = 0;
    var cur = 0;

    for (var i = 0; i < s.length; i++) {
      if (s[i] == char) {
        cur++;
        if (cur > best) best = cur;
      } else {
        cur = 0;
      }
    }

    return best;
  }

  String _renderBlockAsPlainText(Block block) {
    // Best-effort plain text extraction for fallbacks (e.g., forced markdown tables).
    if (block is ParagraphBlock) {
      return _renderInlineGroupAsText(
        block.inlines,
        canBreak: false,
        breakAsBr: false,
      );
    }
    if (block is HeadingBlock) {
      return _renderInlineGroupAsText(
        block.inlines,
        canBreak: false,
        breakAsBr: false,
      );
    }
    if (block is CodeBlock) return block.text;
    if (block is MathBlock) return block.latexOrText;
    if (block is HtmlBlock) return block.html;
    if (block is QuoteBlock) {
      return block.blocks.map(_renderBlockAsPlainText).join('\n');
    }
    if (block is ListBlock) {
      final lines = <String>[];
      var i = 1;
      for (final item in block.items) {
        final marker = block.ordered ? '${i++}.' : '-';
        final text = item.blocks.map(_renderBlockAsPlainText).join(' ');
        lines.add('$marker $text');
      }
      return lines.join('\n');
    }
    if (block is TableBlock) {
      return '[table]';
    }
    if (block is HorizontalRuleBlock) return '---';

    return '';
  }

  String _escapeParagraphLineStartIfNeeded(String line) {
    // Prevent accidental block-level constructs when a paragraph line starts with them.
    // Applies to paragraph lines only (not headings/lists/etc).
    final s = line;
    if (s.isEmpty) return s;

    // Already escaped
    if (s.startsWith(r'\')) return s;

    final triggers = <RegExp>[
      _atxHeadingRe,
      _blockquoteRe,
      _unorderedListRe,
      _orderedListRe,
      _fencedCodeRe,
      _horizontalRuleRe,
    ];

    for (final re in triggers) {
      if (re.hasMatch(s)) return r'\' + s;
    }

    return s;
  }
}

// -----------------------------------------------------------------------------
// Internal helpers
// -----------------------------------------------------------------------------

class _RenderContext {
  const _RenderContext._({
    required this.prefix,
    required this.inBlockQuote,
    required this.listDepth,
  });

  factory _RenderContext.root() =>
      const _RenderContext._(prefix: '', inBlockQuote: false, listDepth: 0);

  final String prefix;
  final bool inBlockQuote;
  final int listDepth;

  _RenderContext withPrefix(String extra) => _RenderContext._(
    prefix: prefix + extra,
    inBlockQuote: inBlockQuote,
    listDepth: listDepth,
  );

  _RenderContext addPrefix(String extra, {required bool entersBlockQuote}) =>
      _RenderContext._(
        prefix: prefix + extra,
        inBlockQuote: inBlockQuote || entersBlockQuote,
        listDepth: listDepth,
      );

  _RenderContext withListDepth(int depth) => _RenderContext._(
    prefix: prefix,
    inBlockQuote: inBlockQuote,
    listDepth: depth,
  );

  /// A “blank line” inside a blockquote must keep the quote marker(s),
  /// otherwise the blockquote may terminate.
  String get blankLineToken {
    if (!inBlockQuote) return '';
    // Trim right so "> " becomes ">" and we don't emit trailing spaces.
    return prefix.trimRight();
  }
}

class _LineWriter {
  /// Manages line output, whitespace trimming, and hard breaks.
  ///
  /// Why: Direct string concatenation is error-prone for nested block types.
  /// This class keeps spacing and blank-line rules consistent.
  _LineWriter({
    required this.trimTrailingWhitespace,
    required this.preserveHardBreaks,
  });

  final bool trimTrailingWhitespace;
  final bool preserveHardBreaks;
  final List<String> _lines = [];

  void writeln(String line, _RenderContext ctx) {
    if (line.isEmpty) {
      // Preserve blockquote context if needed.
      _lines.add(ctx.blankLineToken);
      return;
    }
    _lines.add('${ctx.prefix}${_applyTrim(line)}');
  }

  void writelnRaw(String line) {
    _lines.add(_applyTrim(line));
  }

  void ensureBlankLine(_RenderContext ctx) {
    if (_lines.isEmpty) {
      _lines.add(ctx.blankLineToken);
      return;
    }

    final last = _lines.last;

    // Treat both "" and quote-blank markers (like ">") as "already blank".
    final alreadyBlank =
        last.isEmpty || MarkdownRenderer._blankLineRe.hasMatch(last);

    if (!alreadyBlank) {
      _lines.add(ctx.blankLineToken);
    }
  }

  /// Used for footnotes: remove trailing blank/quote-blank lines safely.
  List<String> linesTrimmedForFootnotes() {
    final lines = List<String>.from(_lines);
    while (lines.isNotEmpty) {
      final last = lines.last;
      final blankish =
          last.isEmpty || MarkdownRenderer._blankLineRe.hasMatch(last);
      if (!blankish) break;
      lines.removeLast();
    }
    return lines;
  }

  @override
  String toString() {
    // Trim trailing blank-ish lines for clean output.
    final lines = List<String>.from(_lines);
    while (lines.isNotEmpty) {
      final last = lines.last;
      final blankish =
          last.isEmpty || MarkdownRenderer._blankLineRe.hasMatch(last);
      if (!blankish) break;
      lines.removeLast();
    }
    return lines.join('\n');
  }

  String _applyTrim(String line) {
    if (!trimTrailingWhitespace) return line;
    if (preserveHardBreaks && line.endsWith('  ')) return line;
    return line.replaceFirst(MarkdownRenderer._trailingWhitespaceRe, '');
  }
}

class _InlineBuffer {
  final List<String> lines = [''];

  void write(String s) {
    lines[lines.length - 1] = lines.last + s;
  }

  void softBreak() {
    lines.add('');
  }

  void hardBreak() {
    // Ensure a hard line break: two spaces at end of line + newline.
    final cur = lines.last;
    if (cur.endsWith('  ')) {
      // ok
    } else if (cur.endsWith(' ')) {
      lines[lines.length - 1] = '$cur ';
    } else {
      lines[lines.length - 1] = '$cur  ';
    }
    lines.add('');
  }
}
