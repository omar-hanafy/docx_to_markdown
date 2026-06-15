# DOCX to Markdown

Pure Dart library for converting DOCX (OOXML) documents to Markdown.

[![pub package](https://img.shields.io/pub/v/docx_to_markdown.svg)](https://pub.dev/packages/docx_to_markdown)

Designed for reliability and extensibility, this package parses Word documents into a structured intermediate representation (IR) before rendering them as clean, deterministic Markdown. It handles complex nesting, tables, images, and custom styles with ease.

## Getting Started

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  docx_to_markdown: ^<LATEST_VERSION>
```

## Usage

### Basic Conversion

```dart
import 'dart:io';
import 'package:docx_to_markdown/docx_to_markdown.dart';

void main() async {
  // 1. Read the DOCX file into bytes
  final file = File('document.docx');
  final bytes = await file.readAsBytes();

  // 2. Initialize the converter
  final converter = DocxConverter(bytes);

  // 3. Convert to Markdown
  final markdown = await converter.convert();
  
  print(markdown);
}
```

### Advanced Configuration

Customize the output with `DocxToMarkdownConfig`:

```dart
final config = DocxToMarkdownConfig(
  // Output format
  flavor: MarkdownFlavor.gfm, // Use GitHub Flavored Markdown
  trimTrailingWhitespace: true,
  
  // Content handling
  extractImages: true,
  includeFootnotes: true,
  includeComments: false,
  
  // Table handling
  tableMode: TableMode.auto, // Use Markdown tables where possible, HTML for complex ones

  // Custom style mappings
  paragraphStyleOverrides: {
    'CodeBlock': ParagraphStyleOverride(isCodeBlock: true, codeLanguage: 'dart'),
    'Quote': ParagraphStyleOverride(isQuote: true),
  },
);

final converter = DocxConverter(bytes, config: config);

// Convert and extract images to a directory
final markdown = await converter.convert(imageOutputDirectory: 'assets/images');
```

### Using Hooks

Intercept and modify content during conversion:

```dart
final hooks = DocxToMarkdownHooks(
  // Rewriting links (e.g., to fix relative paths)
  rewriteLinkTarget: (url, ctx) {
    if (url.startsWith('/')) return 'https://mysite.com$url';
    return url;
  },

  // Custom logic for converting math equations
  ommlToLatex: (omml, ctx) {
    // Return custom LaTeX for the given OMML XML
    return null; // Use default fallback
  },
  
  // Filter or transform blocks
  transformBlock: (block, ctx) {
    // Remove all tables from output
    if (block is TableBlock) return null; 
    return block;
  },
);

final config = DocxToMarkdownConfig(hooks: hooks);
```

### Document Metadata

The converter always parses document properties (`docProps/core.xml` and
`docProps/custom.xml`) into `Document.metadata`. By default nothing is rendered,
so Markdown output is unchanged. Set `metadataMode` to emit a Pandoc-style YAML
front matter block before the body:

```dart
final config = DocxToMarkdownConfig(
  metadataMode: MetadataMode.yamlFrontMatter,
);
final markdown = await DocxConverter(bytes, config: config).convert();
```

```yaml
---
title: Testing custom properties
author: A. M.
subject: This is the subject
description: |-
  Long description spanning several lines.
  This is a second line.
keywords:
  - keyword 1
  - keyword 2
lang: en-US
category: My Category
created: "2025-08-04T18:53:49Z"
modified: "2025-08-04T18:53:49Z"
custom:
  Company: My Company
  subtitle: This is a subtitle
---
```

Core properties map to Pandoc-friendly keys (`creator` becomes `author`,
`language` becomes `lang`); `keywords` is split into a list, and custom
properties are nested under `custom`. Front matter is emitted only when metadata
is present, scalars are quoted when needed, and multiline values use YAML block
scalars. Producer statistics from `docProps/app.xml` (page/word counts) are
intentionally excluded.

## Supported Elements

| Word Element | Markdown Output          | Notes                                             |
|--------------|--------------------------|---------------------------------------------------|
| Paragraphs   | Text                     | Blank lines preserved if configured.              |
| Headings 1-6 | `# Heading`              | Mapped from style outline levels or names.        |
| Lists        | `- Item` / `1. Item`     | Handles deep nesting and mixed types.             |
| Tables       | `\| Col \|` or `<table>` | Simple tables use pipes; complex ones use HTML.   |
| Images       | `![alt](src)`            | Can extract files and rewrite paths via hooks.    |
| Links        | `[text](url)`            | Supports web links and internal bookmarks.        |
| Bold/Italic  | `**bold**`, `*italic*`   | Standard syntax.                                  |
| Code         | `` `code` ``             | Detected by font (e.g., Consolas) or style name.  |
| Blockquotes  | `> text`                 | Mapped from styles containing "Quote".            |
| Footnotes    | `[^1]: ...`              | GFM syntax.                                       |
| Metadata     | YAML front matter        | Opt-in via `MetadataMode.yamlFrontMatter`.        |

## Philosophy

This package aims for "Pandoc-level" quality in pure Dart. It treats the DOCX format not just as text, but as a structured hierarchy. 
We prioritize:
1.  **Correctness**: Lists and tables shouldn't break the layout.
2.  **Safety**: Malformed documents shouldn't crash the parser.
3.  **Flexibility**: You should be able to tweak the output to match your CMS or renderer.

## Contributing

Contributions are welcome! Please see the `docs_guide.md` for our documentation philosophy ("Describe the Behavior, Not Just the Data").

## License

MIT
