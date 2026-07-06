import type { APIRoute } from 'astro';
import { withBase } from '../lib/url';

// Served at /robots.txt. Uses the configured `site` (+ deploy base) so the
// sitemap URL is correct for whatever domain/subpath the site is deployed to.
export const GET: APIRoute = ({ site }) => {
  const sitemap = new URL(withBase('/sitemap-index.xml'), site).href;
  const body = [
    'User-agent: *',
    'Allow: /',
    '',
    `Sitemap: ${sitemap}`,
    '',
  ].join('\n');

  return new Response(body, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
};
