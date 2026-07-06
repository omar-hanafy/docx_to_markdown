import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// IMPORTANT: set this to the real deployed URL before going live.
// Drives canonical URLs, the sitemap, robots.txt, and Open Graph tags.
// Can be overridden at build time with the SITE_URL env var.
const site = process.env.SITE_URL ?? 'https://docx-to-markdown.dev';

// Deploy base path. Empty (root) for a custom domain; '/docx-to-markdown' when
// hosted as a subfolder of omar-hanafy.github.io. Set via the BASE_PATH env var
// (see `npm run deploy`). All internal links go through withBase() in src/lib/url.ts.
const base = process.env.BASE_PATH || undefined;

// https://astro.build/config
export default defineConfig({
  site,
  base,
  trailingSlash: 'ignore',
  integrations: [sitemap()],
  build: {
    // Inline small stylesheets to cut render-blocking requests (good CWV).
    inlineStylesheets: 'auto',
  },
  vite: {
    optimizeDeps: {
      // marked/dompurify/jszip are imported *dynamically* from a client <script>
      // (Preview render, .zip export), so Vite can't discover them by scanning at
      // startup. Left implicit, they get optimized on first use, which re-runs the
      // dep optimizer mid-session and 504s the in-flight import ("Outdated Optimize
      // Dep") - which silently broke the Preview tab in dev. Pre-bundling them up
      // front keeps the optimized set stable. (No effect on the production build.)
      include: ['marked', 'dompurify', 'jszip'],
    },
    build: {
      // The converter engine (marked/dompurify/jszip) is a lazy chunk; keep the
      // warning threshold sane so builds stay quiet.
      chunkSizeWarningLimit: 900,
    },
  },
});
