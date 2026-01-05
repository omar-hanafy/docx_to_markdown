// src/styles.dart
//
// Production-grade StyleRegistry for OOXML (DOCX) styles.xml.
// - Namespace-safe parsing (does not rely on "w:" prefix).
// - Style inheritance traversal with cycle protection.
// - Heuristics for headings, code blocks, and quotes.
// - Fast: caches analysis per styleId.
// - Convenience: resolve styleId by visible name.
//
// Requires:
//   - package:xml
//   - package:collection (for firstOrNull)

import 'package:xml/xml.dart';

/// Maximum depth when traversing w:basedOn chains.
const int _maxStyleChainDepth = 32;

/// The type of a Word style definition.
///
/// Word documents contain different style types that apply to different
/// content scopes. Only [paragraph] and [character] styles affect text
/// conversion; [table] and [numbering] styles are parsed but used indirectly.
enum StyleType {
  /// A paragraph-level style (affects entire paragraphs).
  paragraph,

  /// A character-level style (affects text runs within paragraphs).
  character,

  /// A table style (affects table formatting).
  table,

  /// A numbering style (defines list bullet/number formats).
  numbering,

  /// An unrecognized or unsupported style type.
  unknown,
}

StyleType _parseStyleType(String? raw) {
  switch ((raw ?? '').toLowerCase()) {
    case 'paragraph':
      return StyleType.paragraph;
    case 'character':
      return StyleType.character;
    case 'table':
      return StyleType.table;
    case 'numbering':
      return StyleType.numbering;
    default:
      return StyleType.unknown;
  }
}

/// Run-level properties extracted from a style definition.
///
/// These properties help detect code-style formatting (monospace fonts,
/// shading) even when the style is not explicitly named "Code".
class StyleRunProperties {
  /// Creates run properties with the given font and shading information.
  const StyleRunProperties({
    this.asciiFont,
    this.hAnsiFont,
    this.csFont,
    this.hasShading = false,
  });

  /// The ASCII font family name (used for Latin characters).
  final String? asciiFont;

  /// The high-ANSI font family name (used for extended Latin characters).
  final String? hAnsiFont;

  /// The complex-script font family name (used for RTL/complex scripts).
  final String? csFont;

  /// Whether the style has background shading applied.
  ///
  /// Shading combined with a monospace font is a strong indicator of code.
  final bool hasShading;

  /// Returns `true` if any of the fonts appear to be monospace.
  ///
  /// Uses heuristic matching against common monospace font names.
  bool get isProbablyMonospace {
    return _isMonospaceFont(asciiFont) ||
        _isMonospaceFont(hAnsiFont) ||
        _isMonospaceFont(csFont);
  }

  static bool _isMonospaceFont(String? font) {
    if (font == null) return false;
    final f = font.trim().toLowerCase();

    // Common monospace fonts across platforms and Word templates.
    const monospaceHints = <String>[
      'consolas',
      'courier',
      'courier new',
      'menlo',
      'monaco',
      'source code',
      'fira code',
      'jetbrains mono',
      'dejavu sans mono',
      'ubuntu mono',
      'lucida console',
      'inconsolata',
      'monospace',
      'mono',
    ];

    // Exact matches or substring hints.
    return monospaceHints.any((hint) => f == hint || f.contains(hint));
  }
}

/// A parsed style definition from styles.xml.
///
/// Contains the raw style metadata needed for semantic analysis:
/// style ID, type, name, inheritance chain, and formatting properties.
class StyleDefinition {
  /// Creates a style definition with the given properties.
  StyleDefinition({
    required this.id,
    required this.type,
    this.name,
    this.basedOn,
    this.linkedStyleId,
    this.outlineLevel,
    this.runProps,
    this.numId,
    this.ilvl,
  });

  /// w:styleId
  final String id;

  /// w:type
  final StyleType type;

  /// w:name/@w:val (user-visible style name)
  final String? name;

  /// w:basedOn/@w:val
  final String? basedOn;

  /// w:link/@w:val (linked character/paragraph style pair)
  final String? linkedStyleId;

  /// w:pPr/w:outlineLvl/@w:val (0-based in Word; H1 => 0, H2 => 1 ...)
  final int? outlineLevel;

  /// w:rPr hints for code-ish detection
  final StyleRunProperties? runProps;

  /// w:pPr/w:numPr/w:numId/@w:val - list numbering definition ID
  final String? numId;

  /// w:pPr/w:numPr/w:ilvl/@w:val - list indentation level (0-based)
  final int? ilvl;
}

/// Semantic analysis result for a paragraph style.
///
/// Produced by [StyleRegistry.analyzeParagraphStyle] after walking the
/// style inheritance chain. Used by the parser to determine how to
/// convert a paragraph to the IR.
class StyleAnalysis {
  /// Creates an analysis result with the given semantic flags.
  const StyleAnalysis({
    this.isHeading = false,
    this.headingLevel = 0,
    this.isCodeBlock = false,
    this.isQuote = false,
  });

  /// Whether the style represents a heading.
  final bool isHeading;

  /// The heading level (1–9), clamped to 1–6 during rendering.
  ///
  /// Only meaningful when [isHeading] is `true`.
  final int headingLevel;

  /// Whether the style represents a code block.
  final bool isCodeBlock;

  /// Whether the style represents a block quote.
  final bool isQuote;
}

/// Parses styles.xml and provides "semantic" answers for paragraphs.
///
/// Design goals:
/// - Robust parsing: does not assume "w:" prefix is used.
/// - Conservative heuristics: prefer outlineLvl for headings; name-based fallback.
/// - Stable: never throws for malformed style chains (cycles/missing refs).
///
/// Why: Word styles are hierarchical and often encode semantics indirectly.
/// This registry walks style inheritance to infer meaning (heading, code,
/// quote) without requiring perfect DOCX input.
class StyleRegistry {
  final Map<String, StyleDefinition> _stylesById = <String, StyleDefinition>{};
  final Map<String, List<String>> _styleIdsByNameNorm =
      <String, List<String>>{};

  final Map<String, StyleAnalysis> _analysisCache = <String, StyleAnalysis>{};

  final Set<String> _codeStyleNamesNorm = <String>{};
  final Set<String> _codeStyleIdsNorm = <String>{};
  List<String> _extraMonospaceHints = <String>[];

  /// Clears all internal state.
  void clear() {
    _stylesById.clear();
    _styleIdsByNameNorm.clear();
    _analysisCache.clear();
    _codeStyleNamesNorm.clear();
    _codeStyleIdsNorm.clear();
    _extraMonospaceHints = <String>[];
  }

  /// Loads style definitions from styles.xml.
  ///
  /// Safe to call multiple times. Resets previous state.
  void load(XmlDocument? stylesXml) {
    _stylesById.clear();
    _styleIdsByNameNorm.clear();
    _analysisCache.clear();

    if (stylesXml == null) return;

    final styleElements = stylesXml.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'style',
    );

    for (final styleEl in styleElements) {
      final id = _attrLocal(styleEl, 'styleId');
      if (id == null || id.isEmpty) continue;

      final typeRaw = _attrLocal(styleEl, 'type');
      final type = _parseStyleType(typeRaw);

      final name = _attrLocal(_childLocal(styleEl, 'name'), 'val');

      final basedOn = _attrLocal(_childLocal(styleEl, 'basedOn'), 'val');

      final linkedStyleId = _attrLocal(_childLocal(styleEl, 'link'), 'val');

      final pPr = _childLocal(styleEl, 'pPr');
      final outlineLvlStr = _attrLocal(_childLocal(pPr, 'outlineLvl'), 'val');
      final outlineLvl = int.tryParse(outlineLvlStr ?? '');

      // Parse numbering properties from style
      final numPr = _childLocal(pPr, 'numPr');
      final numId = _attrLocal(_childLocal(numPr, 'numId'), 'val');
      final ilvlStr = _attrLocal(_childLocal(numPr, 'ilvl'), 'val');
      final ilvl = int.tryParse(ilvlStr ?? '');

      final runProps = _parseRunProps(_childLocal(styleEl, 'rPr'));

      final def = StyleDefinition(
        id: id,
        type: type,
        name: name,
        basedOn: basedOn,
        linkedStyleId: linkedStyleId,
        outlineLevel: outlineLvl,
        runProps: runProps,
        numId: numId,
        ilvl: ilvl,
      );

      _stylesById[id] = def;

      // Name -> ids mapping (names are not guaranteed unique)
      final normName = _normName(name);
      if (normName != null) {
        (_styleIdsByNameNorm[normName] ??= <String>[]).add(id);
      }
    }
  }

  /// Sets the *visible* name of the paragraph style you want treated as a code block style.
  ///
  /// Example: "Code", "Source Code", "Preformatted".
  ///
  /// You can call this multiple times; the registry will keep all names.
  void addCodeStyleName(String styleName) {
    final n = _normName(styleName);
    if (n == null) return;
    _codeStyleNamesNorm.add(n);
    _analysisCache.clear(); // analysis depends on this
  }

  /// Convenience: replaces existing code-style names with a single name.
  void setCodeStyleName(String styleName) {
    _codeStyleNamesNorm
      ..clear()
      ..add(_normName(styleName) ?? '');
    _codeStyleNamesNorm.remove('');
    _analysisCache.clear();
  }

  /// Optional: mark a specific styleId as a code-block style (advanced users).
  void addCodeStyleId(String styleId) {
    final n = styleId.trim().toLowerCase();
    if (n.isEmpty) return;
    _codeStyleIdsNorm.add(n);
    _analysisCache.clear();
  }

  /// Sets additional font names to treat as monospace (code indicators).
  ///
  /// These fonts are checked in addition to the built-in monospace font list.
  /// Font matching is case-insensitive and uses substring matching.
  void setMonospaceFonts(List<String> fonts) {
    _extraMonospaceHints = fonts
        .map((f) => f.trim().toLowerCase())
        .where((f) => f.isNotEmpty)
        .toList(growable: false);
    _analysisCache.clear();
  }

  /// Returns the raw style definition, if present.
  StyleDefinition? getById(String styleId) => _stylesById[styleId];

  /// Resolves the first styleId with the given visible style name.
  /// If [type] is provided, restricts to that style type.
  String? resolveStyleIdByName(String styleName, {StyleType? type}) {
    final norm = _normName(styleName);
    if (norm == null) return null;

    final ids = _styleIdsByNameNorm[norm];
    if (ids == null || ids.isEmpty) return null;

    if (type == null) return ids.first;

    for (final id in ids) {
      final def = _stylesById[id];
      if (def != null && def.type == type) return id;
    }
    return null;
  }

  /// Returns semantic analysis for a paragraph styleId.
  ///
  /// Traverses w:basedOn (and linked style if relevant) to infer:
  /// - heading level
  /// - code-block style
  /// - quote-ish style
  ///
  /// Never throws. Unknown/missing/cyclic styles simply return default analysis.
  ///
  /// Why: heading and code detection often live in ancestor styles, not the
  /// paragraph itself. This method walks the chain to surface that intent.
  StyleAnalysis analyzeParagraphStyle(String? styleId) {
    if (styleId == null || styleId.isEmpty) return const StyleAnalysis();

    final cached = _analysisCache[styleId];
    if (cached != null) return cached;

    final visited = <String>{};
    StyleDefinition? current = _stylesById[styleId];

    bool isHeading = false;
    int headingLevel = 0;

    bool isCode = false;
    bool isQuote = false;

    int depth = 0;

    while (current != null && depth++ < _maxStyleChainDepth) {
      if (!visited.add(current.id)) {
        // Cycle detected
        break;
      }

      // Prefer outlineLvl for headings (most reliable)
      final outline = current.outlineLevel;
      if (!isHeading && outline != null) {
        isHeading = true;
        headingLevel = outline + 1;
        // Don't break: still want to discover code/quote flags up the chain.
      }

      final idNorm = current.id.trim().toLowerCase();
      final nameNorm = _normName(current.name);

      // Code: explicit style name/id or heuristic on names
      if (!isCode) {
        if (_codeStyleIdsNorm.contains(idNorm)) {
          isCode = true;
        } else if (nameNorm != null && _codeStyleNamesNorm.contains(nameNorm)) {
          isCode = true;
        } else if (_looksLikeCodeStyle(current)) {
          isCode = true;
        }
      }

      // Quote: conservative heuristic
      if (!isQuote && _looksLikeQuoteStyle(current)) {
        isQuote = true;
      }

      // Heading fallback if outline is missing
      if (!isHeading) {
        final derived = _inferHeadingLevelFromIdOrName(
          current.id,
          current.name,
        );
        if (derived != null) {
          isHeading = true;
          headingLevel = derived;
        }
      }

      // Walk up basedOn chain
      if (current.basedOn == null) break;
      current = _stylesById[current.basedOn!];
    }

    final result = StyleAnalysis(
      isHeading: isHeading,
      headingLevel: headingLevel,
      isCodeBlock: isCode,
      isQuote: isQuote,
    );

    _analysisCache[styleId] = result;
    return result;
  }

  /// Resolves effective numbering properties for a paragraph style.
  ///
  /// Walks the basedOn chain to find inherited numId/ilvl.
  /// Returns null if no numbering is defined in the style chain.
  ///
  /// Why: list numbering is frequently defined on a parent style such as
  /// "List Paragraph". This method recovers that inherited numbering.
  ({String numId, int ilvl})? resolveNumberingForStyle(String? styleId) {
    if (styleId == null || styleId.isEmpty) return null;

    final visited = <String>{};
    StyleDefinition? current = _stylesById[styleId];
    int depth = 0;

    while (current != null && depth++ < _maxStyleChainDepth) {
      if (!visited.add(current.id)) {
        // Cycle detected
        break;
      }

      // If this style has numbering, return it
      if (current.numId != null) {
        return (numId: current.numId!, ilvl: current.ilvl ?? 0);
      }

      // Walk up basedOn chain
      if (current.basedOn == null) break;
      current = _stylesById[current.basedOn!];
    }

    return null;
  }

  // -----------------------
  // Heuristics
  // -----------------------

  bool _looksLikeCodeStyle(StyleDefinition def) {
    final name = (def.name ?? '').trim().toLowerCase();
    final id = def.id.trim().toLowerCase();

    // Name/id hints
    const codeHints = <String>[
      'code',
      'source',
      'preformatted',
      'mono',
      'monospace',
      'snippet',
    ];
    final hinted = codeHints.any((h) => name.contains(h) || id.contains(h));
    if (hinted) return true;

    // Run properties hints (monospace + shading is a strong signal)
    final rp = def.runProps;
    if (rp == null) return false;

    final isMonospace = rp.isProbablyMonospace || _hasExtraMonospaceHint(rp);
    if (isMonospace && rp.hasShading) return true;

    // Monospace alone is a weaker signal; keep it conservative.
    // Uncomment if you want more aggressive detection:
    // if (rp.isProbablyMonospace) return true;

    return false;
  }

  bool _looksLikeQuoteStyle(StyleDefinition def) {
    final name = (def.name ?? '').trim().toLowerCase();
    final id = def.id.trim().toLowerCase();

    const quoteHints = <String>[
      'quote',
      'blockquote',
      'intense quote',
      'citation',
      'epigraph',
    ];
    return quoteHints.any((h) => name.contains(h) || id.contains(h));
  }

  int? _inferHeadingLevelFromIdOrName(String styleId, String? styleName) {
    // Example ids: Heading1, heading2, HEADING_3
    // Names: "Heading 1", "heading 2"
    final id = styleId.trim().toLowerCase();
    final name = (styleName ?? '').trim().toLowerCase();

    // Robust regex for various "heading 1" forms
    final re = RegExp(r'(?:^|[^a-z])heading\s*[_-]?\s*(\d+)(?:$|[^0-9])');
    final idMatch = re.firstMatch(id);
    if (idMatch != null) {
      final n = int.tryParse(idMatch.group(1) ?? '');
      if (n != null && n > 0) return n;
    }

    final nameMatch = RegExp(r'heading\s*(\d+)').firstMatch(name);
    if (nameMatch != null) {
      final n = int.tryParse(nameMatch.group(1) ?? '');
      if (n != null && n > 0) return n;
    }

    // Some templates use "Title" / "Subtitle" as heading-like
    if (name == 'title' || id == 'title') return 1;
    if (name == 'subtitle' || id == 'subtitle') return 2;

    return null;
  }

  // -----------------------
  // Parsing helpers
  // -----------------------

  StyleRunProperties? _parseRunProps(XmlElement? rPr) {
    if (rPr == null) return null;

    final rFonts = _childLocal(rPr, 'rFonts');
    final ascii = _attrLocal(rFonts, 'ascii');
    final hAnsi = _attrLocal(rFonts, 'hAnsi');
    final cs = _attrLocal(rFonts, 'cs');

    final hasShading = _childLocal(rPr, 'shd') != null;

    if (ascii == null && hAnsi == null && cs == null && !hasShading) {
      return null;
    }

    return StyleRunProperties(
      asciiFont: ascii,
      hAnsiFont: hAnsi,
      csFont: cs,
      hasShading: hasShading,
    );
  }

  bool _hasExtraMonospaceHint(StyleRunProperties rp) {
    if (_extraMonospaceHints.isEmpty) return false;
    return _extraMonospaceHints.any((hint) {
      return _fontContainsHint(rp.asciiFont, hint) ||
          _fontContainsHint(rp.hAnsiFont, hint) ||
          _fontContainsHint(rp.csFont, hint);
    });
  }

  bool _fontContainsHint(String? font, String hint) {
    if (font == null) return false;
    final f = font.trim().toLowerCase();
    if (f.isEmpty) return false;
    return f == hint || f.contains(hint);
  }

  XmlElement? _childLocal(XmlElement? parent, String local) {
    if (parent == null) return null;
    for (final child in parent.children) {
      if (child is XmlElement && child.name.local == local) return child;
    }
    return null;
  }

  String? _attrLocal(XmlElement? el, String localName) {
    if (el == null) return null;
    for (final a in el.attributes) {
      if (a.name.local == localName) return a.value;
    }
    return null;
  }

  static String? _normName(String? name) {
    if (name == null) return null;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;

    // Collapse whitespace and lower-case to normalize.
    return trimmed.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }
}
