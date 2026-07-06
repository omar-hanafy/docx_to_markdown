// Capability list, reused by the home "what survives" grid and /features.
// Icon names map to src/components/Icon.astro.
export interface Capability {
  icon: string;
  title: string;
  desc: string;
}

export const CAPABILITIES: Capability[] = [
  {
    icon: 'hash',
    title: 'Headings & structure',
    desc: 'Outline levels and heading styles become # through ###### with the hierarchy intact.',
  },
  {
    icon: 'list',
    title: 'Lists, nested & mixed',
    desc: 'Deeply nested ordered, unordered and task lists keep their levels and markers.',
  },
  {
    icon: 'table',
    title: 'Tables',
    desc: 'Simple tables become Markdown pipes; merged-cell tables fall back to clean HTML.',
  },
  {
    icon: 'image',
    title: 'Images',
    desc: 'Embedded images are extracted in your browser, previewed inline, and exported in a .zip.',
  },
  {
    icon: 'wand',
    title: 'Rich formatting',
    desc: 'Bold, italic, strikethrough, underline, super/subscript, highlight and color - faithfully.',
  },
  {
    icon: 'file-check',
    title: 'Footnotes & endnotes',
    desc: 'Footnotes convert to GFM [^1] syntax; endnotes can be included on request.',
  },
  {
    icon: 'quote',
    title: 'Blockquotes',
    desc: 'Word quote styles are turned into > blockquotes.',
  },
  {
    icon: 'code',
    title: 'Code detection',
    desc: 'Monospace runs, shaded text and code styles become inline code or fenced blocks.',
  },
  {
    icon: 'layers',
    title: 'Definition lists',
    desc: 'Definition term / definition styles render as <dl>, Pandoc, or plain paragraphs.',
  },
  {
    icon: 'sigma',
    title: 'Math (OMML)',
    desc: 'Office equations are extracted with a readable fallback, or routed to LaTeX via a hook.',
  },
  {
    icon: 'sparkles',
    title: 'Metadata front matter',
    desc: 'Core and custom document properties can be emitted as a YAML front-matter block.',
  },
  {
    icon: 'shield',
    title: 'Safe by default',
    desc: 'Malformed or non-DOCX files degrade to partial output with notes instead of crashing.',
  },
];
