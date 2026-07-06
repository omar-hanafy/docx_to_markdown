// Shared FAQ content. Rendered on the page AND emitted as FAQPage JSON-LD, so
// the answers must read as plain, self-contained prose (no markup).
export interface Faq {
  q: string;
  a: string;
}

export const FAQS: Faq[] = [
  {
    q: 'Is this DOCX to Markdown converter free?',
    a: 'Yes. It is completely free and open source under the MIT license. There are no accounts, no limits, and no watermarks.',
  },
  {
    q: 'Are my files uploaded to a server?',
    a: 'No. The conversion runs entirely in your browser using WebAssembly-grade compiled Dart. Your document never leaves your device, which makes it safe for confidential and internal files.',
  },
  {
    q: 'What Markdown does it produce?',
    a: 'You can choose GitHub Flavored Markdown (GFM) or strict CommonMark. GFM adds tables, task lists, strikethrough and footnotes; CommonMark is maximally portable and renders tables as HTML.',
  },
  {
    q: 'What does it preserve from the Word document?',
    a: 'Headings, ordered and nested lists, task lists, tables (with an HTML fallback for merged cells), images, links, footnotes and endnotes, bold, italic, strikethrough, inline code, blockquotes, definition lists, math, and document metadata as YAML front matter.',
  },
  {
    q: 'Does it handle images?',
    a: 'Yes. Embedded images are extracted in your browser. You can preview them inline and download everything as a .zip with the Markdown file and an images folder alongside it.',
  },
  {
    q: 'Is there a file size limit?',
    a: 'There is no hard limit. Because everything runs locally, a very large document simply takes a moment longer to convert - nothing is queued or throttled by a server.',
  },
  {
    q: 'Can I convert an old .doc file?',
    a: 'Only the modern .docx format (Office Open XML) is supported. If you have a legacy .doc file, open it in Word or Google Docs and save a copy as .docx first.',
  },
  {
    q: 'Can I use this converter in my own app?',
    a: 'Yes. The tool is powered by docx_to_markdown, an open-source Dart package. You can add it to any Dart or Flutter project - server, CLI, desktop, mobile, or web - and get the same conversion in your own code.',
  },
];
