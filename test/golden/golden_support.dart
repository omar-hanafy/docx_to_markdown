// Shared helpers for the DOCX golden-file test suite.
//
// Golden cases live as flat files under `test/docx_golden/`:
//   <name>.docx          - the input document (required)
//   <name>.md            - the expected Markdown output (generated, then reviewed)
//   <name>.config.json   - optional per-case DocxToMarkdownConfig (serializable subset)
//
// Both the test runner (`test/docx_golden_test.dart`) and the regeneration tool
// (`tool/update_goldens.dart`) import this file so conversion and comparison can
// never diverge.

import 'dart:convert';
import 'dart:io';

import 'package:docx_to_markdown/docx_to_markdown.dart';
import 'package:path/path.dart' as p;

/// Absolute path to the golden-fixtures directory, resolved from the package
/// root. `dart test` and `dart run` both execute from the package root.
final String goldenDir = p.join(Directory.current.path, 'test', 'docx_golden');

/// A single golden case discovered on disk.
class GoldenCase {
  /// Creates a case from its base [name] (the `.docx` filename without extension).
  GoldenCase(this.name);

  /// The case name (input filename without the `.docx` extension).
  final String name;

  /// Absolute path to the input `.docx`.
  String get inputPath => p.join(goldenDir, '$name.docx');

  /// Absolute path to the expected Markdown file.
  String get expectedPath => p.join(goldenDir, '$name.md');

  /// Absolute path to the optional per-case config JSON.
  String get configPath => p.join(goldenDir, '$name.config.json');
}

/// Discovers every `<name>.docx` under [goldenDir], sorted by name.
List<GoldenCase> discoverCases() {
  final dir = Directory(goldenDir);
  if (!dir.existsSync()) return const [];
  return dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.docx'))
      // Skip Word lock files (`~$name.docx`), created while a document is open.
      // They are not valid DOCX archives and must not become golden cases.
      .where((f) => !p.basename(f.path).startsWith(r'~$'))
      .map((f) => GoldenCase(p.basenameWithoutExtension(f.path)))
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));
}

/// Loads a case's [DocxToMarkdownConfig], or [DocxToMarkdownConfig.defaults]
/// when no `<name>.config.json` is present.
DocxToMarkdownConfig loadConfig(GoldenCase c) {
  final f = File(c.configPath);
  if (!f.existsSync()) return DocxToMarkdownConfig.defaults;
  final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  return configFromJson(json);
}

/// The result of converting a case in a throwaway image directory.
class GoldenResult {
  /// Creates a result holding the produced [markdown] and its [imageDir].
  GoldenResult(this.markdown, this.imageDir);

  /// The produced Markdown (already normalized).
  final String markdown;

  /// The temp directory images were extracted into; the caller deletes it.
  final Directory imageDir;
}

/// Converts a case into a per-case temp image directory and returns the
/// normalized Markdown plus that directory (which the caller must delete).
Future<GoldenResult> convertCase(GoldenCase c) async {
  final bytes = await File(c.inputPath).readAsBytes();
  final config = loadConfig(c);
  final imageDir = await Directory.systemTemp.createTemp('golden_${c.name}_');
  final md = await DocxConverter(
    bytes,
    config: config,
  ).convert(imageOutputDirectory: imageDir.path);
  return GoldenResult(normalize(md), imageDir);
}

/// Normalizes Markdown for stable comparison: CRLF -> LF, strip per-line
/// trailing whitespace, and end with exactly one trailing newline.
///
/// Markdown hard line breaks (a content line ending in two-or-more spaces) are
/// preserved as exactly two trailing spaces. Stripping them unconditionally
/// would make goldens lossy - a hard break would look identical to a soft
/// break - and blind the suite to hard-break regressions.
String normalize(String s) {
  final hardBreak = RegExp(r'\S {2,}$');
  final trailing = RegExp(r'[ \t]+$');
  final lines = s.replaceAll('\r\n', '\n').split('\n').map((l) {
    if (hardBreak.hasMatch(l)) {
      return '${l.replaceAll(trailing, '')}  ';
    }
    return l.replaceAll(trailing, '');
  });
  return '${lines.join('\n').trimRight()}\n';
}

/// Local image targets referenced by the Markdown (`![alt](target)` and
/// `<img src="...">`), excluding `data:`/`http(s):` URIs.
Iterable<String> imageTargets(String md) sync* {
  for (final m in RegExp(r'!\[[^\]]*\]\(([^)\s]+)').allMatches(md)) {
    yield m.group(1)!;
  }
  for (final m in RegExp('<img[^>]*src="([^"]+)"').allMatches(md)) {
    yield m.group(1)!;
  }
}

/// Decodes the serializable subset of [DocxToMarkdownConfig] from a golden
/// `config.json` map. Hooks and closures are intentionally unsupported.
///
/// Throws [FormatException] on an unrecognized key so a typo in a golden config
/// fails loudly instead of silently doing nothing.
DocxToMarkdownConfig configFromJson(Map<String, dynamic> json) {
  const known = <String>{
    'flavor',
    'tableMode',
    'underlineMode',
    'highlightMode',
    'textColorMode',
    'pageBreakMode',
    'unknownElementPolicy',
    'extractImages',
    'includeFootnotes',
    'includeEndnotes',
    'includeComments',
    'includeHeadersFooters',
    'preserveEmptyParagraphs',
    'trimTrailingWhitespace',
    'orderedListNumbering',
    'orderedListMarker',
    'lineBreakStyle',
    'trackChangesMode',
    'imageSizeMode',
    'listIndent',
    'tightLists',
    'treatShadedRunsAsCode',
    'maxImageWidth',
    'codeBlockStyleName',
    'bulletMarkers',
    'monospaceFonts',
    'strict',
    'emitWarningsAsHtmlComments',
  };
  final unknown = json.keys.toSet().difference(known);
  if (unknown.isNotEmpty) {
    throw FormatException('Unknown golden config keys: ${unknown.join(', ')}');
  }

  T enumByName<T extends Enum>(List<T> values, String key, T fallback) {
    final name = json[key] as String?;
    if (name == null) return fallback;
    return values.firstWhere(
      (e) => e.name == name,
      orElse: () => throw FormatException('Bad $key: "$name"'),
    );
  }

  final defaults = DocxToMarkdownConfig.defaults;
  return DocxToMarkdownConfig(
    flavor: enumByName(MarkdownFlavor.values, 'flavor', defaults.flavor),
    tableMode: enumByName(TableMode.values, 'tableMode', defaults.tableMode),
    underlineMode: enumByName(
      UnderlineMode.values,
      'underlineMode',
      defaults.underlineMode,
    ),
    highlightMode: enumByName(
      HighlightMode.values,
      'highlightMode',
      defaults.highlightMode,
    ),
    textColorMode: enumByName(
      TextColorMode.values,
      'textColorMode',
      defaults.textColorMode,
    ),
    pageBreakMode: enumByName(
      PageBreakMode.values,
      'pageBreakMode',
      defaults.pageBreakMode,
    ),
    unknownElementPolicy: enumByName(
      UnknownElementPolicy.values,
      'unknownElementPolicy',
      defaults.unknownElementPolicy,
    ),
    orderedListNumbering: enumByName(
      OrderedListNumbering.values,
      'orderedListNumbering',
      defaults.orderedListNumbering,
    ),
    orderedListMarker: enumByName(
      OrderedListMarker.values,
      'orderedListMarker',
      defaults.orderedListMarker,
    ),
    lineBreakStyle: enumByName(
      LineBreakStyle.values,
      'lineBreakStyle',
      defaults.lineBreakStyle,
    ),
    trackChangesMode: enumByName(
      TrackChangesMode.values,
      'trackChangesMode',
      defaults.trackChangesMode,
    ),
    imageSizeMode: enumByName(
      ImageSizeMode.values,
      'imageSizeMode',
      defaults.imageSizeMode,
    ),
    extractImages: json['extractImages'] as bool? ?? defaults.extractImages,
    includeFootnotes:
        json['includeFootnotes'] as bool? ?? defaults.includeFootnotes,
    includeEndnotes:
        json['includeEndnotes'] as bool? ?? defaults.includeEndnotes,
    includeComments:
        json['includeComments'] as bool? ?? defaults.includeComments,
    includeHeadersFooters:
        json['includeHeadersFooters'] as bool? ??
        defaults.includeHeadersFooters,
    preserveEmptyParagraphs:
        json['preserveEmptyParagraphs'] as bool? ??
        defaults.preserveEmptyParagraphs,
    trimTrailingWhitespace:
        json['trimTrailingWhitespace'] as bool? ??
        defaults.trimTrailingWhitespace,
    tightLists: json['tightLists'] as bool? ?? defaults.tightLists,
    treatShadedRunsAsCode:
        json['treatShadedRunsAsCode'] as bool? ??
        defaults.treatShadedRunsAsCode,
    listIndent: json['listIndent'] as int? ?? defaults.listIndent,
    maxImageWidth: json['maxImageWidth'] as int? ?? defaults.maxImageWidth,
    codeBlockStyleName:
        json['codeBlockStyleName'] as String? ?? defaults.codeBlockStyleName,
    strict: json['strict'] as bool? ?? defaults.strict,
    emitWarningsAsHtmlComments:
        json['emitWarningsAsHtmlComments'] as bool? ??
        defaults.emitWarningsAsHtmlComments,
    bulletMarkers:
        (json['bulletMarkers'] as List?)?.cast<String>() ??
        defaults.bulletMarkers.toList(),
    monospaceFonts:
        (json['monospaceFonts'] as List?)?.cast<String>() ??
        defaults.monospaceFonts.toList(),
  );
}
