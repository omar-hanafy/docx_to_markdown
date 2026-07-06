/** Site-wide constants. Change these once; they propagate everywhere. */

export const SITE = {
  name: 'DOCX to Markdown',
  /** Used in <title> suffixes and the wordmark. */
  shortName: 'docx2md',
  domainLabel: 'docx-to-markdown.dev',
  tagline:
    'Convert Word .docx files to clean, structured Markdown - free, private, and entirely in your browser.',
  description:
    'Free online DOCX to Markdown converter. Drop a Word document and get clean GitHub-Flavored or CommonMark Markdown - tables, images, lists, footnotes and metadata preserved. Runs 100% in your browser; files are never uploaded.',
  author: 'Omar Hanafy',
  // The engine behind the tool.
  packageName: 'docx_to_markdown',
  repo: 'https://github.com/omar-hanafy/docx_to_markdown',
  pubDev: 'https://pub.dev/packages/docx_to_markdown',
  pubDevApi: 'https://pub.dev/documentation/docx_to_markdown/latest/',
  // Author links. Update authorUrl to a portfolio when one is live.
  authorUrl: 'https://github.com/omar-hanafy',
  authorGithub: 'https://github.com/omar-hanafy',
  // Support the developer. Slug: omar.hanafy.
  buyMeACoffee: 'https://buymeacoffee.com/omar.hanafy',
  ogImage: '/og.png',
  themeColor: '#6d28d9',
  themeColorDark: '#131419',
} as const;

export const NAV: { label: string; href: string }[] = [
  { label: 'Features', href: '/features' },
  { label: 'For developers', href: '/developers' },
  { label: 'Guide', href: '/guides/convert-docx-to-markdown' },
];
