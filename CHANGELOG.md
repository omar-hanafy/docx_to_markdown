# Changelog

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
