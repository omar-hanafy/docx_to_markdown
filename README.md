# docx_to_markdown

[![pub version](https://img.shields.io/pub/v/docx_to_markdown.svg)](https://pub.dev/packages/docx_to_markdown) [![pub points](https://img.shields.io/pub/points/docx_to_markdown.svg)](https://pub.dev/packages/docx_to_markdown/score) [![downloads](https://img.shields.io/pub/dm/docx_to_markdown.svg)](https://pub.dev/packages/docx_to_markdown) [![style: lints](https://img.shields.io/badge/style-lints-40c4ff.svg)](https://pub.dev/packages/lints) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Convert Word `.docx` (OOXML) files to clean, deterministic Markdown - in pure Dart.

`docx_to_markdown` parses a document into a structured intermediate representation (IR) and *then* renders it, rather than scraping text run by run. That extra step is what buys **Pandoc-level structural fidelity** - deeply nested lists, complex tables, footnotes, math, and definition lists survive the trip - while keeping the package **100% pure Dart with zero native dependencies**. It runs anywhere Dart runs: server, CLI, and Flutter on Android, iOS, macOS, Windows, and Linux.

```dart
final bytes = File('report.docx').readAsBytesSync();
final markdown = await DocxConverter(bytes).convert();
```

## Features

**Content** - paragraphs, headings (1-6), blockquotes, ordered/unordered/nested/mixed lists, task lists, tables (with HTML fallback for merged cells), images, links, internal bookmarks, footnotes, endnotes, comments, headers/footers, definition lists, and horizontal rules.

**Formatting** - bold, italic, strikethrough, underline, sub/superscript, inline code, highlight, and text color, with faithful handling of style-inherited and character-style run properties.

**Output targeting** - one input, tuned output: GitHub Flavored Markdown or strict CommonMark, with switchable conventions for tables, underline, images (Obsidian / Pandoc sizing), definition lists, and ordered-list markers.

**Math** - OMML equations are extracted with a readable text fallback, or routed through your own OMML-to-LaTeX converter via a hook.

**Metadata** - document properties (`docProps/core.xml` and `docProps/custom.xml`) are always parsed, and can optionally be emitted as a Pandoc-style YAML front matter block.

**Extensible** - rewrite links and image targets, transform or drop blocks and inlines, collect warnings, and reach the full IR - all without forking.

**Safe** - malformed archives, non-DOCX ZIPs, and missing parts degrade to partial output and warnings instead of crashing (opt into `strict` mode to throw instead).

## Install

```bash
dart pub add docx_to_markdown
# Flutter:
flutter pub add docx_to_markdown
```

Or add it to your `pubspec.yaml`:

```yaml
dependencies:
  docx_to_markdown: ^0.1.0
```

## Quick start

```dart
import 'dart:io';
import 'package:docx_to_markdown/docx_to_markdown.dart';

Future<void> main() async {
  // The converter works on bytes, so load the file however you like.
  final bytes = await File('document.docx').readAsBytes();

  // Defaults: GitHub Flavored Markdown, footnotes on, tables auto.
  final markdown = await DocxConverter(bytes).convert();

  print(markdown);
}
```

`DocxConverter` never touches the disk or network on its own - you supply the bytes, and it returns a Markdown `String`. Invalid input (empty bytes or a non-ZIP file) throws a `DocxPackageException`.

## Configuration

Pass a `DocxToMarkdownConfig` to control the output. Every option has a sensible default, so override only what you need:

```dart
final config = DocxToMarkdownConfig(
  flavor: MarkdownFlavor.gfm,            // or .commonmark
  tableMode: TableMode.auto,             // pipes for simple tables, HTML for complex
  extractImages: true,
  imageSizeMode: ImageSizeMode.obsidian, // ![alt](img.png =300x200)
  includeComments: false,
  metadataMode: MetadataMode.yamlFrontMatter,
  trackChangesMode: TrackChangesMode.showDeletionsAsStrikethrough,

  // Map your template's custom paragraph styles onto Markdown constructs.
  paragraphStyleOverrides: {
    'CodeExample': ParagraphStyleOverride(isCodeBlock: true, codeLanguage: 'dart'),
    'Callout': ParagraphStyleOverride(isQuote: true),
    'ChapterTitle': ParagraphStyleOverride(headingLevel: 1),
  },
);

final converter = DocxConverter(bytes, config: config);

// Provide a directory to write extracted images; references become relative paths.
final markdown = await converter.convert(imageOutputDirectory: 'assets/images');
```

Configs are immutable; use `config.copyWith(...)` to derive variants.

### Key options

**Output and format**

| Option | Default | Notes |
|---|---|---|
| `flavor` | `gfm` | `gfm` or `commonmark`. CommonMark renders tables as HTML. |
| `tableMode` | `auto` | `auto`, `markdownOnly`, or `htmlOnly`. |
| `definitionListMode` | `html` | `html` (`<dl>`), `pandoc`, or `paragraphs`. |
| `pageBreakMode` | `ignore` | `ignore`, `thematicBreak` (`---`), or `htmlComment`. |
| `metadataMode` | `none` | Set to `yamlFrontMatter` to emit front matter. |

**Content**

| Option | Default | Notes |
|---|---|---|
| `extractImages` | `true` | Pair with `imageOutputDirectory` on `convert()`. |
| `imageSizeMode` | `none` | `none`, `obsidian` (`=WxH`), or `pandoc` (`{ width=... }`). |
| `includeFootnotes` | `true` | GFM `[^1]` footnote syntax. |
| `includeEndnotes` | `false` | Treated like footnotes when enabled. |
| `includeComments` | `false` | Rendered as HTML comments. |
| `includeHeadersFooters` | `false` | Rendered as separate sections. |
| `unknownElementPolicy` | `keepText` | `drop`, `keepText`, or `keepHtml` for unsupported XML. |

**Formatting**

| Option | Default | Notes |
|---|---|---|
| `underlineMode` | `html` | `<u>`, `++text++`, or `ignore`. |
| `highlightMode` | `none` | `mark` wraps in `<mark>`. |
| `textColorMode` | `none` | `htmlSpan` wraps in `<span style="color:...">`. |
| `trackChangesMode` | `acceptAll` | Accept, reject, or show deletions as `~~strikethrough~~`. |
| `lineBreakStyle` | `hardBreak` | `hardBreak`, `htmlBr`, or `newline`. |

**Lists**

| Option | Default | Notes |
|---|---|---|
| `orderedListNumbering` | `alwaysOne` | `keep` preserves source numbers; `alwaysOne` emits `1.`. |
| `orderedListMarker` | `decimal` | `preserveFormat` emits Pandoc Roman/alpha markers. |
| `tightLists` | `true` | No blank lines between items. |

**Diagnostics**

| Option | Default | Notes |
|---|---|---|
| `strict` | `false` | Throw on structural problems instead of warning. |
| `emitWarningsAsHtmlComments` | `false` | Inline `<!-- Warning: ... -->` markers. |

> This is the common subset. See the [full API reference](https://pub.dev/documentation/docx_to_markdown/latest/) for every option (code detection via `monospaceFonts` / `codeBlockStyleName` / `treatShadedRunsAsCode`, `bulletMarkers`, `listIndent`, `maxImageWidth`, `preserveEmptyParagraphs`, and more).

### Document metadata

Parsing always populates `Document.metadata`. By default nothing is rendered, so the Markdown body is unchanged. Set `metadataMode` to prepend a Pandoc-style YAML front matter block:

```dart
final config = DocxToMarkdownConfig(metadataMode: MetadataMode.yamlFrontMatter);
final markdown = await DocxConverter(bytes, config: config).convert();
```

```yaml
---
title: Quarterly Report
author: A. M.
subject: This is the subject
keywords:
  - keyword 1
  - keyword 2
lang: en-US
created: "2025-08-04T18:53:49Z"
modified: "2025-08-04T18:53:49Z"
custom:
  Company: My Company
---
```

Core properties map to Pandoc-friendly keys (`creator` becomes `author`, `language` becomes `lang`), `keywords` is split into a list, and custom properties are nested under `custom`. Front matter is emitted only when metadata is present; producer statistics from `docProps/app.xml` (page/word counts) are intentionally excluded.

## Hooks and the IR

Hooks let you intercept conversion without forking the library. The package exports the full IR (`Document`, `Block`, `Inline` and friends), so transforms can match on concrete node types:

```dart
final hooks = DocxToMarkdownHooks(
  // Fix relative links.
  rewriteLinkTarget: (url, [ctx]) =>
      url.startsWith('/') ? 'https://example.com$url' : url,

  // Send extracted images to a CDN.
  rewriteImageTarget: (src, [ctx]) => 'https://cdn.example.com/${src.split('/').last}',

  // Drop every table from the output.
  transformBlock: (block, ctx) => block is TableBlock ? null : block,

  // Supply your own OMML -> LaTeX conversion (return null to use the text fallback).
  ommlToLatex: (ommlXml, [ctx]) => null,

  // Observe non-fatal issues.
  onWarning: (warning, ctx) => print('[${warning.code}] ${warning.message} @ ${ctx.location}'),
);

final markdown =
    await DocxConverter(bytes, config: DocxToMarkdownConfig(hooks: hooks)).convert();
```

## Supported elements

| Word element | Markdown output | Notes |
|---|---|---|
| Paragraphs | text | Empty paragraphs collapsed unless `preserveEmptyParagraphs`. |
| Headings 1-6 | `# Heading` | From outline levels, style names, or overrides. |
| Lists | `- item` / `1. item` | Deep nesting, mixed and ordered/unordered. |
| Task lists | `- [ ]` / `- [x]` | GFM checkboxes. |
| Tables | `\| col \|` or `<table>` | Simple tables use pipes; complex ones fall back to HTML. |
| Images | `![alt](src)` | Extracted to disk and/or rewritten via hooks; optional sizing. |
| Links | `[text](url)` | Web links and internal bookmarks. |
| Bold / italic | `**bold**`, `*italic*` | Plus `~~strikethrough~~` and sub/superscript. |
| Underline | `<u>` / `++..++` | Configurable via `underlineMode`. |
| Highlight / color | `<mark>` / `<span>` | Opt-in via `highlightMode` / `textColorMode`. |
| Inline / block code | `` `code` `` / fenced | Detected by font, shading, or style name. |
| Blockquotes | `> text` | From styles containing "Quote". |
| Footnotes / endnotes | `[^1]: ...` | GFM syntax; endnotes opt-in. |
| Definition lists | `<dl>` / Pandoc / flat | Configurable via `definitionListMode`. |
| Math (OMML) | text or LaTeX | Text fallback by default; LaTeX via `ommlToLatex` hook. |
| Metadata | YAML front matter | Opt-in via `MetadataMode.yamlFrontMatter`. |

## Limitations

Worth knowing before you adopt:

- **No Flutter web.** Image extraction relies on `dart:io`, so the package targets the Dart VM and Flutter on mobile/desktop, not the web platform.
- **SmartArt, charts, and embedded objects** cannot be cleanly represented in Markdown. By default their text content is preserved (`unknownElementPolicy: keepText`) and a warning is emitted; the visual structure is lost.
- **Page geometry** - sections, columns, margins, and page size - has no Markdown equivalent and is not modeled. Explicit page breaks can optionally become a thematic break or an HTML comment.
- **Headers, footers, comments, and endnotes** are off by default; enable them explicitly when you want them in the output.

Warnings are surfaced through `DocxToMarkdownHooks.onWarning` (or inlined with `emitWarningsAsHtmlComments`), so you can always see what was downgraded.

## Philosophy

This package aims for "Pandoc-level" quality in pure Dart. It treats a `.docx` not as a bag of text but as a structured hierarchy, and prioritizes:

1. **Correctness** - lists and tables should not break the surrounding layout.
2. **Safety** - a malformed document should never crash the parser.
3. **Flexibility** - you should be able to tune the output to match your CMS, wiki, or renderer.

## Contributing

Contributions are welcome. See [`docs_guide.md`](docs_guide.md) for the documentation philosophy this codebase follows ("Describe the Behavior, Not Just the Data").

## License

[MIT](LICENSE) - Copyright 2025 Omar Khaled Hanafy.
