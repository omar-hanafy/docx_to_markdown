// ooxml_vocabulary.dart
//
// Canonical OOXML element vocabularies shared by the block and inline
// tokenizers in parser.dart.
//
// A name encoded here must have exactly one definition. A second copy in a
// `switch` arm is a defect, not an optimization: the block tokenizer drifted
// from the inline tokenizer precisely because the same fact was written twice
// and only one copy was maintained.

/// WordprocessingML elements that carry no document content.
///
/// Two kinds, per ECMA-376 Part 1:
///
/// - **Property containers** (`CT_*Pr` types) hold formatting only.
/// - **Markers** (`EG_RangeMarkupElements` and the empty members of
///   `EG_RunLevelElts`) are empty elements denoting a position or a range
///   boundary.
///
/// Neither kind may be converted to a block or an inline, recursed into, or
/// reported as `unsupported.block` / `unsupported.inline`.
///
/// ### Scope: roots only
///
/// Only elements that can appear as a *direct child of a content container*
/// (`w:body`, `w:tc`, `w:tr`, `w:tbl`, `w:sdtContent`, `w:customXml`,
/// `w:smartTag`, `w:hdr`, `w:ftr`, `w:footnote`, `w:endnote`, `w:comment`,
/// `w:txbxContent`) belong here - plus `w:pPr` and `w:rPr`, which the inline
/// tokenizer must also skip.
///
/// Descendants of these roots (`w:tcW`, `w:shd`, `w:tcMar`, `w:top`,
/// `w:start`, ...) are deliberately absent. Once a root is skipped its subtree
/// is unreachable, so listing descendants would be an unbounded denylist over
/// the whole OOXML property vocabulary. Several of those names (`top`,
/// `bottom`, `left`, `right`, `start`, `end`) are also generic enough to
/// collide across namespaces, and matching here is by local name.
///
/// ### Deliberately absent: content-bearing elements
///
/// `w:ins`, `w:del`, `w:moveFrom` and `w:moveTo` are run-level *containers*
/// that wrap real content. Adding them here would silently delete tracked
/// changes; only their `*RangeStart` / `*RangeEnd` markers belong.
/// `w:bookmarkStart` is absent because it emits an anchor, and `w:altChunk`
/// because it is genuinely unsupported content.
const Set<String> contentlessOoxmlElements = <String>{
  // --- Property containers (CT_*Pr) ---
  'pPr', // CT_P
  'rPr', // CT_R, CT_ParaRPr
  'sectPr', // CT_Body, CT_PPr
  'tblPr', // CT_Tbl
  'tblPrEx', // CT_Row
  'tblGrid', // CT_Tbl
  'trPr', // CT_Row
  'tcPr', // CT_Tc
  'sdtPr', // CT_SdtBlock / CT_SdtRun
  'sdtEndPr', // CT_SdtBlock / CT_SdtRun
  'customXmlPr', // CT_CustomXmlBlock / CT_CustomXmlRun
  'smartTagPr', // CT_SmartTagRun
  // --- Markers: empty members of EG_RunLevelElts ---
  'proofErr',
  'permStart',
  'permEnd',

  // --- Markers: EG_RangeMarkupElements ---
  // (w:bookmarkStart is excluded: it emits an anchor.)
  'bookmarkEnd',
  'commentRangeStart',
  'commentRangeEnd',
  'moveFromRangeStart',
  'moveFromRangeEnd',
  'moveToRangeStart',
  'moveToRangeEnd',
  'customXmlInsRangeStart',
  'customXmlInsRangeEnd',
  'customXmlDelRangeStart',
  'customXmlDelRangeEnd',
  'customXmlMoveFromRangeStart',
  'customXmlMoveFromRangeEnd',
  'customXmlMoveToRangeStart',
  'customXmlMoveToRangeEnd',

  // --- Layout hint, run-level only; always ignored. ---
  'lastRenderedPageBreak',
};

/// Whether [localName] names a contentless OOXML element.
///
/// Matching is by local name, consistent with the rest of the parser.
bool isContentlessOoxmlElement(String localName) =>
    contentlessOoxmlElements.contains(localName);
