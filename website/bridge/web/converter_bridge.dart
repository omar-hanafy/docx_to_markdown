// DOCX -> Markdown browser bridge.
//
// Compiled to JavaScript with `dart compile js` and loaded by the converter
// website. It exposes exactly one entry point on the global scope:
//
//   globalThis.docxToMarkdownConvert(Uint8Array bytes, options) : Promise<{
//     markdown : string,
//     images   : Array<{ partPath, filename, path, mimeType, bytes: Uint8Array }>,
//     warnings : Array<{ code, message, location, severity }>,
//   }>
//
// All conversion runs in the browser via the real docx_to_markdown package; no
// bytes are ever uploaded. `options` is a plain JS object whose known keys are
// mapped onto DocxToMarkdownConfig; unknown keys are ignored (forward-safe).

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:docx_to_markdown/docx_to_markdown.dart';

void main() {
  globalContext.setProperty('docxToMarkdownConvert'.toJS, _convert.toJS);
  // Lets the page know the (async-loaded) bridge finished registering.
  globalContext.setProperty('docxToMarkdownReady'.toJS, true.toJS);
}

/// JS-facing entry point. Returns a Promise so the caller can `await` it.
JSPromise<JSObject> _convert(JSUint8Array bytes, JSObject? options) {
  return _convertAsync(bytes.toDart, options ?? JSObject()).toJS;
}

Future<JSObject> _convertAsync(Uint8List bytes, JSObject options) async {
  final warnings = <JSObject>[];
  final images = <JSObject>[];
  final result = JSObject();

  // Resolve with a structured `{ error }` rather than rejecting, so the caller
  // gets a clean, human-readable message instead of a boxed dart2js exception.
  try {
    final config = _buildConfig(
      options,
      onWarning: (warning, ctx) => warnings.add(_warningToJs(warning, ctx)),
    );

    final markdown = await DocxConverter(bytes, config: config).convert(
      imageAssetSink: (asset) {
        final path = 'images/${asset.suggestedFilename}';
        images.add(_imageToJs(asset, path));
        return path;
      },
    );

    result.setProperty('markdown'.toJS, markdown.toJS);
    result.setProperty('images'.toJS, images.toJS);
    result.setProperty('warnings'.toJS, warnings.toJS);
  } on DocxPackageException catch (e) {
    result.setProperty('error'.toJS, e.message.toJS);
  } catch (e) {
    result.setProperty('error'.toJS, 'Conversion failed: $e'.toJS);
  }
  return result;
}

JSObject _imageToJs(DocxImageAsset asset, String path) {
  final o = JSObject();
  o.setProperty('partPath'.toJS, asset.partPath.toJS);
  o.setProperty('filename'.toJS, asset.suggestedFilename.toJS);
  o.setProperty('path'.toJS, path.toJS);
  o.setProperty('mimeType'.toJS, asset.contentType.toJS);
  o.setProperty('bytes'.toJS, asset.bytes.toJS);
  return o;
}

JSObject _warningToJs(DocWarning warning, HookContext ctx) {
  final o = JSObject();
  o.setProperty('code'.toJS, warning.code.toJS);
  o.setProperty('message'.toJS, warning.message.toJS);
  o.setProperty('location'.toJS, ctx.location.toJS);
  o.setProperty('severity'.toJS, warning.severity.name.toJS);
  return o;
}

// ---------------------------------------------------------------------------
// Options object -> DocxToMarkdownConfig
// ---------------------------------------------------------------------------

DocxToMarkdownConfig _buildConfig(
  JSObject o, {
  required WarningHandler onWarning,
}) {
  return DocxToMarkdownConfig(
    // Output flavor / policies
    flavor: _enum(_str(o, 'flavor'), _flavors, MarkdownFlavor.gfm),
    tableMode: _enum(_str(o, 'tableMode'), _tableModes, TableMode.auto),
    definitionListMode: _enum(
      _str(o, 'definitionListMode'),
      _definitionListModes,
      DefinitionListMode.html,
    ),
    underlineMode: _enum(
      _str(o, 'underlineMode'),
      _underlineModes,
      UnderlineMode.html,
    ),
    highlightMode: _enum(
      _str(o, 'highlightMode'),
      _highlightModes,
      HighlightMode.none,
    ),
    textColorMode: _enum(
      _str(o, 'textColorMode'),
      _textColorModes,
      TextColorMode.none,
    ),
    pageBreakMode: _enum(
      _str(o, 'pageBreakMode'),
      _pageBreakModes,
      PageBreakMode.ignore,
    ),
    metadataMode: _enum(
      _str(o, 'metadataMode'),
      _metadataModes,
      MetadataMode.none,
    ),
    imageSizeMode: _enum(
      _str(o, 'imageSizeMode'),
      _imageSizeModes,
      ImageSizeMode.none,
    ),
    trackChangesMode: _enum(
      _str(o, 'trackChangesMode'),
      _trackChangesModes,
      TrackChangesMode.acceptAll,
    ),
    unknownElementPolicy: _enum(
      _str(o, 'unknownElementPolicy'),
      _unknownElementPolicies,
      UnknownElementPolicy.keepText,
    ),
    // Lists
    orderedListNumbering: _enum(
      _str(o, 'orderedListNumbering'),
      _orderedListNumberings,
      OrderedListNumbering.alwaysOne,
    ),
    orderedListMarker: _enum(
      _str(o, 'orderedListMarker'),
      _orderedListMarkers,
      OrderedListMarker.decimal,
    ),
    tightLists: _bool(o, 'tightLists') ?? true,
    // Content toggles
    extractImages: _bool(o, 'extractImages') ?? true,
    includeFootnotes: _bool(o, 'includeFootnotes') ?? true,
    includeEndnotes: _bool(o, 'includeEndnotes') ?? false,
    includeComments: _bool(o, 'includeComments') ?? false,
    includeHeadersFooters: _bool(o, 'includeHeadersFooters') ?? false,
    preserveEmptyParagraphs: _bool(o, 'preserveEmptyParagraphs') ?? false,
    hooks: DocxToMarkdownHooks(onWarning: onWarning),
  );
}

// ---------------------------------------------------------------------------
// Small JS-interop reading helpers
// ---------------------------------------------------------------------------

String? _str(JSObject o, String key) {
  final v = o.getProperty<JSAny?>(key.toJS);
  if (v.isUndefinedOrNull) return null;
  return (v! as JSString).toDart;
}

bool? _bool(JSObject o, String key) {
  final v = o.getProperty<JSAny?>(key.toJS);
  if (v.isUndefinedOrNull) return null;
  return (v! as JSBoolean).toDart;
}

/// Resolves [value] against a name->enum [table], falling back to [fallback].
T _enum<T>(String? value, Map<String, T> table, T fallback) {
  if (value == null) return fallback;
  return table[value] ?? fallback;
}

const _flavors = <String, MarkdownFlavor>{
  'gfm': MarkdownFlavor.gfm,
  'commonmark': MarkdownFlavor.commonmark,
};

const _tableModes = <String, TableMode>{
  'auto': TableMode.auto,
  'markdownOnly': TableMode.markdownOnly,
  'htmlOnly': TableMode.htmlOnly,
};

const _definitionListModes = <String, DefinitionListMode>{
  'html': DefinitionListMode.html,
  'pandoc': DefinitionListMode.pandoc,
  'paragraphs': DefinitionListMode.paragraphs,
};

const _underlineModes = <String, UnderlineMode>{
  'html': UnderlineMode.html,
  'plusPlus': UnderlineMode.plusPlus,
  'ignore': UnderlineMode.ignore,
};

const _highlightModes = <String, HighlightMode>{
  'none': HighlightMode.none,
  'mark': HighlightMode.mark,
};

const _textColorModes = <String, TextColorMode>{
  'none': TextColorMode.none,
  'htmlSpan': TextColorMode.htmlSpan,
};

const _pageBreakModes = <String, PageBreakMode>{
  'ignore': PageBreakMode.ignore,
  'thematicBreak': PageBreakMode.thematicBreak,
  'htmlComment': PageBreakMode.htmlComment,
};

const _metadataModes = <String, MetadataMode>{
  'none': MetadataMode.none,
  'yamlFrontMatter': MetadataMode.yamlFrontMatter,
};

const _imageSizeModes = <String, ImageSizeMode>{
  'none': ImageSizeMode.none,
  'obsidian': ImageSizeMode.obsidian,
  'pandoc': ImageSizeMode.pandoc,
};

const _trackChangesModes = <String, TrackChangesMode>{
  'acceptAll': TrackChangesMode.acceptAll,
  'showDeletionsAsStrikethrough': TrackChangesMode.showDeletionsAsStrikethrough,
  'rejectChanges': TrackChangesMode.rejectChanges,
};

const _unknownElementPolicies = <String, UnknownElementPolicy>{
  'drop': UnknownElementPolicy.drop,
  'keepText': UnknownElementPolicy.keepText,
  'keepHtml': UnknownElementPolicy.keepHtml,
};

const _orderedListNumberings = <String, OrderedListNumbering>{
  'alwaysOne': OrderedListNumbering.alwaysOne,
  'keep': OrderedListNumbering.keep,
};

const _orderedListMarkers = <String, OrderedListMarker>{
  'decimal': OrderedListMarker.decimal,
  'preserveFormat': OrderedListMarker.preserveFormat,
};
