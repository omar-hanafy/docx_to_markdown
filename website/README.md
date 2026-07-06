# docx-to-markdown website

The marketing + converter site for the [`docx_to_markdown`](https://pub.dev/packages/docx_to_markdown)
Dart package. It's three things at once:

1. A **real converter** - drop a `.docx`, preview the Markdown, copy or download it.
2. A **live demo** of the package (the conversion is the actual package, compiled to JS).
3. A **portfolio piece**.

Everything runs **client-side**: files are never uploaded, so hosting is free and static.

## Stack

- **Astro** static site (near-zero JS baseline, strong SEO).
- **The Dart package compiled to JavaScript** as the conversion engine
  (`public/converter/converter.js`), exposed as `window.docxToMarkdownConvert`.
- `marked` + `DOMPurify` for the rendered preview, `JSZip` for image export -
  all lazy-loaded only when needed.

```
website/
├─ bridge/                 Dart mini-package: path dep on ../.. + the JS entry point
├─ public/
│  ├─ converter/converter.js   compiled engine (committed - deploys need no Dart SDK)
│  ├─ sample.docx              the "Try the sample" document
│  └─ og.png, favicon.*, ...
├─ scripts/
│  ├─ build-bridge.sh          recompiles converter.js from the Dart package
│  ├─ make-sample.mjs          regenerates sample.docx
│  └─ capture-sample-md.mjs    re-captures the hero's sample Markdown
└─ src/                     pages, components, layouts, styles, data
```

## Develop

```bash
npm install
npm run dev          # http://localhost:4321
```

## Build

```bash
npm run build        # -> dist/  (fully static)
npm run preview      # serve the built output locally
```

Set the public URL so canonical tags, the sitemap, robots.txt and Open Graph
are correct:

```bash
SITE_URL="https://your-domain.com" npm run build
```

The default (in `astro.config.mjs`) is `https://docx-to-markdown.dev` - **change
it to your real domain** (either edit the config or always pass `SITE_URL`).

## Rebuilding the converter engine

`public/converter/converter.js` is the Dart package compiled to JavaScript. It's
committed so static hosts only need Node. **Regenerate it whenever the package
changes** (requires the Dart SDK):

```bash
npm run build:bridge     # runs scripts/build-bridge.sh -> dart compile js
```

To change the hero's sample document:

```bash
node scripts/make-sample.mjs        # writes public/sample.docx
node scripts/capture-sample-md.mjs  # writes src/data/sample.ts from the real conversion
```

## Deploy (any static host)

Build output is plain static files in `dist/`. Because this lives in a
subdirectory of the package repo, point your host at **`website/` as the root
directory**.

| Setting          | Value            |
|------------------|------------------|
| Root directory   | `website`        |
| Build command    | `npm run build`  |
| Output directory | `dist`           |
| Node version     | 20+ (26 tested)  |
| Env (recommended)| `SITE_URL=https://your-domain.com` |

- **Cloudflare Pages** (recommended - free, fast custom domains): the `_headers`
  file is honored automatically.
- **Netlify**: honors `_headers` too; set the base directory to `website`.
- **Vercel**: auto-detects Astro; mirror `public/_headers` in `vercel.json` if
  you want the same caching.

No Dart SDK is needed in CI - the committed `converter.js` is what ships.

## Analytics

None is wired in. To add privacy-friendly, cookieless analytics (Cloudflare Web
Analytics, Plausible, Umami…), drop the snippet into the marked slot in
`src/layouts/Base.astro`.
