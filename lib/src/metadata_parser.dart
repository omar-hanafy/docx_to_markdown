// metadata_parser.dart
//
// Parses OOXML document metadata (docProps/core.xml + docProps/custom.xml)
// into the structured [DocumentMetadata] IR value.
//
// Lives in the package/parser layer (not the renderer): metadata is structured
// data, not a rendering concern. Producer statistics (docProps/app.xml) are
// intentionally out of scope - they are frequently stale.

import 'package:xml/xml.dart';

import 'package:docx_to_markdown/src/ir.dart';
import 'package:docx_to_markdown/src/ooxml_package.dart';

/// Parses `docProps/core.xml` and `docProps/custom.xml` from [package] into a
/// [DocumentMetadata].
///
/// Resolution uses the package-root relationships, falling back to the
/// conventional `docProps/*.xml` paths. Missing parts yield empty fields rather
/// than an error.
///
/// Text is XML-entity decoded (by the XML parser), then OOXML `_xHHHH_` escapes
/// are decoded and line endings normalized to `\n`. An empty or whitespace-only
/// core element is treated as absent (`null`).
///
/// Malformed XML is handled per [strict]: when `true`, the underlying
/// [DocxXmlParseException] propagates; when `false`, a `metadata.malformed`
/// [DocWarning] is reported via [onWarning] and that part is skipped so the
/// other part is still parsed.
DocumentMetadata parseDocumentMetadata(
  DocxPackage package, {
  void Function(DocWarning warning)? onWarning,
  bool strict = false,
}) {
  final core = _loadPart(
    package,
    package.corePropertiesPartPath,
    onWarning: onWarning,
    strict: strict,
  );
  final customDoc = _loadPart(
    package,
    package.customPropertiesPartPath,
    onWarning: onWarning,
    strict: strict,
  );

  String? title;
  String? creator;
  String? subject;
  String? description;
  var keywords = const <String>[];
  String? language;
  String? category;
  String? created;
  String? modified;
  String? lastModifiedBy;
  String? revision;
  final extra = <String, String>{};

  if (core != null) {
    for (final el in core.rootElement.childElements) {
      final value = _nullIfBlank(_decodeOoxmlText(el.innerText));
      switch (el.name.local) {
        case 'title':
          title = value;
        case 'creator':
          creator = value;
        case 'subject':
          subject = value;
        case 'description':
          description = value;
        case 'language':
          language = value;
        case 'category':
          category = value;
        case 'keywords':
          keywords = _splitKeywords(value);
        case 'lastModifiedBy':
          lastModifiedBy = value;
        case 'revision':
          revision = value;
        case 'created':
          created = value;
        case 'modified':
          modified = value;
        default:
          // Preserve any other recognized core element rather than drop it.
          if (value != null) extra[el.name.local] = value;
      }
    }
  }

  final custom = <String, String>{};
  if (customDoc != null) {
    for (final prop in customDoc.rootElement.childElements) {
      if (prop.name.local != 'property') continue;
      final name = prop.getAttribute('name');
      if (name == null || name.isEmpty) continue;
      final firstChild = prop.childElements.firstOrNull;
      final raw = firstChild?.innerText ?? '';
      custom[name] = _decodeOoxmlText(raw);
    }
  }

  return DocumentMetadata(
    title: title,
    creator: creator,
    subject: subject,
    description: description,
    keywords: keywords,
    language: language,
    category: category,
    created: created,
    modified: modified,
    lastModifiedBy: lastModifiedBy,
    revision: revision,
    custom: custom,
    extra: extra,
  );
}

/// Loads and parses an optional docProps part, honoring [strict] on failure.
XmlDocument? _loadPart(
  DocxPackage package,
  String? partPath, {
  required void Function(DocWarning warning)? onWarning,
  required bool strict,
}) {
  if (partPath == null) return null;
  try {
    return package.loadXml(partPath);
  } on DocxPackageException {
    if (strict) rethrow;
    onWarning?.call(
      DocWarning(
        code: 'metadata.malformed',
        message: 'Could not parse metadata part; skipped.',
        location: SourceLocation(part: partPath, path: ''),
      ),
    );
    return null;
  }
}

/// Splits a `cp:keywords` value on commas and semicolons, trimming each entry
/// and dropping empties. Returns an empty list for blank input.
List<String> _splitKeywords(String? value) {
  if (value == null) return const [];
  return value
      .split(RegExp('[,;]'))
      .map((k) => k.trim())
      .where((k) => k.isNotEmpty)
      .toList(growable: false);
}

/// `null` if [value] is `null` or whitespace-only, else [value] unchanged.
String? _nullIfBlank(String? value) {
  if (value == null) return null;
  return value.trim().isEmpty ? null : value;
}

final RegExp _ooxmlEscape = RegExp('_x([0-9A-Fa-f]{4})_');

/// Decodes OOXML `_xHHHH_` character escapes (e.g. `_x000d_` -> CR) and
/// normalizes `\r\n`/`\r` to `\n`.
///
/// Decoding happens left-to-right and non-overlapping, so an escaped literal
/// underscore (`_x005f_`) correctly leaves a following `x000d_` untouched.
String _decodeOoxmlText(String input) {
  final decoded = input.contains('_x')
      ? input.replaceAllMapped(
          _ooxmlEscape,
          (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
        )
      : input;
  return decoded.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}
