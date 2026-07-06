import type { APIRoute } from 'astro';
import { withBase } from '../lib/url';
import { SITE } from '../consts';

// Served at /site.webmanifest. Generated (not a static file in public/) so the
// start_url and icon paths pick up the deploy base - otherwise they'd 404 when
// the site is hosted under omar-hanafy.github.io/docx-to-markdown/.
export const GET: APIRoute = () => {
  const manifest = {
    name: SITE.name,
    short_name: SITE.shortName,
    description:
      'Convert Word .docx files to clean Markdown, entirely in your browser.',
    start_url: withBase('/'),
    display: 'standalone',
    background_color: '#fbfaf7',
    theme_color: SITE.themeColor,
    icons: [
      { src: withBase('/icon-192.png'), sizes: '192x192', type: 'image/png' },
      { src: withBase('/icon-512.png'), sizes: '512x512', type: 'image/png' },
      {
        src: withBase('/icon-512.png'),
        sizes: '512x512',
        type: 'image/png',
        purpose: 'maskable',
      },
    ],
  };

  return new Response(JSON.stringify(manifest, null, 2), {
    headers: { 'Content-Type': 'application/manifest+json; charset=utf-8' },
  });
};
