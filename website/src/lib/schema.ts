// Builders for JSON-LD structured data. Absolute URLs are derived from the
// passed `site` (Astro.site) so they are always correct for the deployed domain.
import { SITE } from '../consts';
import { FAQS } from '../data/faq';
import { withBase } from './url';

// Base-aware absolute URL: folds in the deploy subpath so JSON-LD URLs are
// correct under omar-hanafy.github.io/docx-to-markdown/ as well as at a root domain.
const abs = (site: URL, path = '/') => new URL(withBase(path), site).href;

export function softwareAppSchema(site: URL) {
  return {
    '@context': 'https://schema.org',
    '@type': 'WebApplication',
    name: SITE.name,
    url: abs(site),
    applicationCategory: 'UtilitiesApplication',
    operatingSystem: 'Any (runs in a web browser)',
    browserRequirements: 'Requires JavaScript',
    description: SITE.description,
    offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
    author: { '@type': 'Person', name: SITE.author, url: SITE.authorUrl },
    isBasedOn: SITE.pubDev,
    featureList: [
      'Convert DOCX to GitHub Flavored or CommonMark Markdown',
      'Tables, images, lists, footnotes and metadata preserved',
      'Runs entirely in the browser - files are never uploaded',
      'Copy, download .md, or export a .zip with images',
    ],
  };
}

export function faqSchema() {
  return {
    '@context': 'https://schema.org',
    '@type': 'FAQPage',
    mainEntity: FAQS.map((f) => ({
      '@type': 'Question',
      name: f.q,
      acceptedAnswer: { '@type': 'Answer', text: f.a },
    })),
  };
}

export function breadcrumbSchema(site: URL, items: { name: string; path: string }[]) {
  return {
    '@context': 'https://schema.org',
    '@type': 'BreadcrumbList',
    itemListElement: items.map((it, i) => ({
      '@type': 'ListItem',
      position: i + 1,
      name: it.name,
      item: abs(site, it.path),
    })),
  };
}

export function howToSchema(
  site: URL,
  opts: { name: string; description: string; path: string; steps: { name: string; text: string }[] },
) {
  return {
    '@context': 'https://schema.org',
    '@type': 'HowTo',
    name: opts.name,
    description: opts.description,
    url: abs(site, opts.path),
    totalTime: 'PT1M',
    tool: { '@type': 'HowToTool', name: SITE.name },
    step: opts.steps.map((s, i) => ({
      '@type': 'HowToStep',
      position: i + 1,
      name: s.name,
      text: s.text,
    })),
  };
}
