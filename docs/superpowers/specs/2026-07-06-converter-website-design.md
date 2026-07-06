# DOCX to Markdown - Converter Website Design

Date: 2026-07-06
Status: Approved (autonomous build - owner delegated all decisions)
Author: Omar Hanafy (built with Claude Code)

## 1. Goal

Build one website that serves three jobs at once:

1. **A real, useful converter tool** - drop in a `.docx`, see the Markdown, copy or
   download it. SEO-tuned so it ranks for "docx to markdown" style searches.
2. **A live demo / showcase** for the `docx_to_markdown` Dart package (README links to it).
3. **A portfolio-grade piece** - clean, fast, professional, credited to Omar Hanafy.

Plus the things a thoughtful build adds on its own: privacy-first client-side conversion,
a "try a sample" path, image + ZIP export, dark mode, and structured data for search.

## 2. The single most important constraint: SEO

Goal #1 requires the site to be **crawlable and fast**. This rules out a Flutter Web app
(CanvasKit renders to a canvas; content is not in the DOM, Core Web Vitals suffer, and the
initial payload is heavy). For a page whose entire purpose is to rank for conversion
searches, that is disqualifying.

Therefore the marketing/content shell is a **static HTML site**, and the conversion itself
runs **client-side** by compiling the existing Dart package to JavaScript.

## 3. Architecture

```
Browser
  ├─ Static HTML/CSS (Astro build)  ← crawlable, fast, ~0 JS baseline
  └─ Converter island (vanilla TS)
        ├─ marked + DOMPurify        ← render Markdown -> safe HTML preview
        ├─ JSZip                     ← "download .zip" (md + images/)
        └─ converter.js (lazy)       ← the Dart package, compiled to JS
              └─ DocxConverter(bytes, config).convert(imageAssetSink: ...)
```

- **Nothing is uploaded.** Bytes are read with `FileReader`, converted in-page, and never
  leave the browser. This is a genuine privacy feature AND a trust/SEO selling point, and
  it makes hosting free (no compute backend).
- The converter is the **real package**, not a reimplementation, guaranteeing the demo
  matches what a developer gets from `pub add docx_to_markdown`.

### 3.1 Repo layout (monorepo)

The site lives inside the package repo so the bridge always compiles against the exact
current package code (path dependency). `website/` and `docs/` are added to `.pubignore`,
so neither ships in the pub.dev archive - the published package stays lean.

```
docx_to_markdown/                 # repo root = the Dart package (unchanged)
├─ lib/ …                          # the package
├─ docs/superpowers/specs/         # this doc (pub-ignored)
└─ website/                        # the site (pub-ignored)
   ├─ bridge/                      # tiny Dart package: path dep on ../.. + JS entrypoint
   │  ├─ pubspec.yaml              #   docx_to_markdown: { path: ../../ }
   │  └─ web/converter_bridge.dart #   dart:js_interop wrapper
   ├─ public/converter/converter.js# compiled bridge (committed) + version stamp
   ├─ src/ (pages, components, layouts, styles)
   ├─ scripts/build-bridge.sh      # regenerates converter.js via `dart compile js`
   └─ package.json / astro.config.mjs
```

### 3.2 The Dart -> JS bridge

A standalone Dart entrypoint (its own mini-package with a path dep on the root package)
exposes one global function via `dart:js_interop`:

```
globalThis.docxToMarkdownConvert(Uint8Array bytes, options) : Promise<{
  markdown : string,
  images   : Array<{ partPath, filename, mimeType, bytes: Uint8Array }>,
  warnings : Array<{ code, message, location }>,
}>
```

- Options is a plain JS object; the bridge maps known keys onto `DocxToMarkdownConfig`
  and ignores unknown ones (forward-compatible).
- Images are collected through `imageAssetSink`: the sink returns a stable relative path
  (`images/<suggestedFilename>`) that goes into the Markdown, and pushes the bytes into the
  result so JS can build blob URLs (preview) and a ZIP (download). No JS->Dart callbacks.
- `onWarning` hook collects warnings into the result so the UI can surface "3 things were
  downgraded" (e.g. SmartArt kept as text) - honest about fidelity, which builds trust.

**Build/deploy decoupling:** `converter.js` is precompiled and committed. Static hosts
(Cloudflare Pages / Netlify / Vercel) only need Node to build the Astro site; they never
need the Dart SDK. `npm run build:bridge` (which runs `dart compile js -O2`) regenerates it
locally whenever the package changes; this is documented in `website/README.md`.

**Verification:** the compiled bridge is exercised in Node against a real `test/**.docx`
fixture before wiring the UI, proving the whole conversion path works outside a browser.

## 4. Pages & information architecture

| Route            | Purpose                             | Primary SEO intent                     |
|------------------|-------------------------------------|----------------------------------------|
| `/`              | The converter tool + value props + FAQ | "docx to markdown", "convert word to markdown online" |
| `/features/`     | What it converts, faithfully (tables, images, footnotes, math, metadata …) - doubles as package showcase | feature/long-tail queries |
| `/developers/`   | "Powered by the docx_to_markdown Dart package": install, code sample, links to pub.dev + GitHub | "dart docx package", devs |
| `/guides/convert-docx-to-markdown/` | Cornerstone how-to article (real, useful content) | primary keyword depth |
| `/about/`        | Built by Omar Hanafy + portfolio/GitHub links | brand |

Home is the star: the converter is above the fold. Everything else supports it.

## 5. Converter UX

- **Input:** big drag-and-drop zone + file picker + "Try a sample" (bundled sample `.docx`
  so a first-time visitor can see value with zero effort - lowers bounce, great for demo).
- **Output:** two tabs - **Markdown** (raw source, monospaced, the product) as default, and
  **Preview** (rendered HTML via marked+DOMPurify, images swapped to blob URLs).
- **Actions:** Copy, Download `.md`, Download `.zip` (shown only when images exist).
- **Options bar (always visible):** Flavor (GFM / CommonMark), Include images, Front-matter
  metadata, Footnotes. **Advanced (collapsible):** tables, definition lists, underline, image
  sizing, headers/footers, comments, endnotes, ordered-list numbering, page breaks, track
  changes. Changing an option re-converts the last file instantly (config is cheap).
- **Warnings panel:** lists anything downgraded, with the package's warning codes.
- **Errors:** invalid/non-DOCX files map `DocxPackageException` to a friendly inline message.
- **Privacy note** right on the tool: "Runs entirely in your browser. Files never uploaded."

## 6. SEO plan

- Semantic HTML, exactly one `<h1>` per page, descriptive `<title>` + meta description.
- Open Graph + Twitter Card tags; a generated OG image.
- JSON-LD: `SoftwareApplication` (the tool, free), `FAQPage` (home FAQ), `HowTo`
  (cornerstone guide), `BreadcrumbList`.
- `sitemap.xml` (Astro integration) + `robots.txt`; canonical URLs.
- Fast Core Web Vitals: Astro ships near-zero JS; the ~heavy converter.js is lazy-loaded
  only when the user actually drops a file, so it never taxes first paint.
- The cornerstone guide provides real keyword depth (not thin content).

## 7. Visual direction

Clean, modern, developer-tool aesthetic (think Linear / Vercel / Astro docs restraint, not
a loud gradient landing page). Confident typographic hierarchy, generous whitespace, a
single accent color, subtle borders over heavy shadows, first-class dark mode. The converter
UI itself is the hero - it should feel fast and tactile. Details refined via the
`frontend-design` skill so it does not read as a template.

## 8. Deployment

Static output (`astro build` -> `website/dist/`). Recommend **Cloudflare Pages** (free,
fast, trivial custom domain) with Netlify/Vercel as documented alternatives. Add a
privacy-friendly analytics placeholder (Cloudflare Web Analytics / Plausible) - no keys
hardcoded. Custom domain is the owner's call; the README documents wiring it up.

## 9. Explicitly out of scope (YAGNI for v1)

Batch/multi-file conversion, a blog engine beyond the single cornerstone guide, accounts,
server-side anything, and i18n. All are noted as future ideas, none block launch.

## 10. Key decisions & assumptions (log)

1. **Static site, not Flutter Web** - SEO + speed are non-negotiable for goal #1.
2. **Client-side conversion via `dart compile js`** - privacy, $0 hosting, real package code.
3. **Astro** - best-in-class SEO/perf for a content+tool+islands site; Node is available.
4. **Monorepo with `website/` + `docs/` pub-ignored** - bridge tracks the package exactly;
   published archive stays clean.
5. **Precompile + commit `converter.js`** - decouples static-host deploy from the Dart SDK.
6. **Bridge returns image bytes to JS** (no JS->Dart callbacks) - simplest robust interop.
7. **Expose a curated option subset** (not all ~30 config fields) - power without overwhelm.
8. **marked + DOMPurify** for preview - the package can emit intentional HTML (tables,
   `<u>`, `<mark>`), so the preview must sanitize.
9. Assumption: owner will choose the final domain and hosting account; everything is built
   to deploy anywhere static with zero code changes.
```

## 11. Success criteria

- `astro build` succeeds; site is fully static.
- Dropping a real `.docx` produces correct Markdown, copy + download work, images export.
- Lighthouse: strong Performance/SEO/Best-Practices/Accessibility on the home route.
- Package README links the live demo.
- The whole thing deploys to a static host with only Node in CI.
