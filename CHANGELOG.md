# Changelog

## 0.2.0

This release changes the Markdown produced for documents that already converted; review the notes below before upgrading pinned output.

- Fixed emphasis that Word pads with whitespace rendering as literal asterisks: a bold `"1.  "` produced `**1.  **`, which no CommonMark or GFM parser treats as bold. Whitespace is now hoisted outside the delimiters (`**1.**  `), and a span holding only whitespace drops its delimiters entirely. Affects bold, italic, strikethrough, and `++underline++`.
- Stopped re-emitting a paragraph style's own typography as inline emphasis once that style has become a Markdown block marker: a `Heading1` whose style carries `<w:b/>` now yields `# Title` instead of `# **Title**`. Quote styles and definition terms are affected the same way. Bold and italic that the author applied directly, or through a character style, are unchanged. Wrap `HeadingBlock.inlines` in a `StrongInline` from `transformBlock` to restore the previous rendering.
- Unified monospace detection across runs and styles, which previously consulted separate font lists, so `Liberation Mono` was inline code through a character style but plain text through a direct `w:rFonts`. The `monospaceFonts` default now covers the families modern exports use - Liberation Mono, DejaVu Sans Mono, JetBrains Mono, Fira Code, IBM Plex Mono, Cascadia Code, SF Mono, Roboto Mono, Inconsolata, Hack, Iosevka, and more - and matches on whole words, so `Monotype Corsiva` is no longer taken for a monospace face. Expect more text to render as inline code.
- Fixed merged-cell tables, and every table under `TableMode.htmlOnly`, losing all inline formatting: a second HTML renderer inside the parser flattened cells to plain text, discarding bold, italic, links, and images, emitted `<td>` for header cells, and appended a stray `<br/>` to every cell. The parser now always produces a `TableBlock` carrying real `colSpan` and `rowSpan`, so `transformBlock` receives a `TableBlock` where it previously received an `HtmlBlock` for those tables.
- Stopped treating a monospace document body font as a code signal, which turned entire documents into inline code; detection now requires contrast with the document's default font.
- Stopped letting the complex-script font slot (`w:cs`) trigger code detection, so an Arabic fallback of Courier New no longer renders a Calibri paragraph as inline code.
- Dropped tables whose cells carry no content, such as the 1x1 shaded table Word uses as a decorative rule, which previously emitted an empty `<table>`. A cell counts as content when it holds text, an image, a link, a bookmark anchor, a footnote or endnote reference, a comment, math, a page break, or a non-empty nested table. Set `preserveEmptyTables: true` to keep them; each drop reports a new `table.emptyDropped` warning.
- Fixed line-start escaping emitting a visible backslash: a paragraph beginning `1. text` was escaped as `\1.`, but CommonMark honours a backslash only before ASCII punctuation. The delimiter now carries the escape (`1\. text`), and headings are no longer escaped at all.
- Stopped reporting OOXML property and marker elements - `w:tcPr`, `w:tblPr`, `w:trPr`, `w:proofErr`, and the range markers - as unsupported content. A real Word document raised thousands of spurious `unsupported.block` warnings, and with `emitWarningsAsHtmlComments: true` those became thousands of comment lines in the output.
- Added `preserveEmptyTables` and `monospaceMatcher` to `DocxToMarkdownConfig`, `hasRenderableContent` to `Block`, `Inline`, `TableCell`, and `TableGrid`, and exported `kDefaultMonospaceFonts`, `MonospaceFontMatcher`, and `normalizeFontName`.
- Added a browser-based converter demo at [omar-hanafy.github.io/docx_to_markdown](https://omar-hanafy.github.io/docx_to_markdown/).

## 0.1.0

- Updated the minimum Dart SDK requirement to 3.12.
- Added document metadata parsing with optional Pandoc YAML front matter output.
- Added definition-list parsing and configurable HTML, Pandoc, or paragraph rendering.
- Added web-safe image export via `imageAssetSink`, plus explicit image opt-out with `extractImages: false`.
- Added rendering controls for highlights, text color, page breaks, tracked changes, source ordered-list markers, metadata, and image dimensions.
- Expanded DOCX fidelity for comments, endnotes, headers and footers, task lists, internal bookmarks, VML images, text boxes, horizontal rules, complex tables, nested lists, and table-cell footnotes.
- Improved formatting fidelity for style-inherited run properties, character styles, complex-script bold and italic, underline/color/highlight composition, same-run images and notes, and explicit shading resets.
- Improved OMML math fallback rendering for common structures, including superscripts, subscripts, radicals, n-ary operators, matrices, delimiters, and accents.
- Improved hooks and integration APIs with full IR exports and richer warning, link, image, and OMML context.
- Improved package validation and relationship handling for malformed DOCX input, non-DOCX ZIPs, media, links, and metadata parts.

## 0.0.1

- Initial release of `docx_to_markdown`.
- Supports parsing DOCX files into a structured Intermediate Representation (IR).
- Renders Markdown (GFM or CommonMark) with configurable options.
- Features:
  - Paragraphs, Headings (1-6), Blockquotes.
  - Lists (ordered, unordered, nested, mixed).
  - Tables (Markdown pipes or HTML fallback for merged cells).
  - Images (extraction, resizing syntax support).
  - Text formatting (bold, italic, strikethrough, underline, sub/superscript).
  - Links and Footnotes.
  - Math equations (OMML to LaTeX hooks).
  - Code blocks (fenced, with language detection).
- Configurable hooks for custom transformations.
