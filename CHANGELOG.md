# Changelog

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