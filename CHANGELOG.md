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
  - Document metadata: parses `docProps/core.xml` and `docProps/custom.xml`
    into `Document.metadata`, with optional Pandoc-style YAML front matter via
    `MetadataMode.yamlFrontMatter` (off by default).
- Configurable hooks for custom transformations.