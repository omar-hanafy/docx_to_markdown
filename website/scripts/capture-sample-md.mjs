// Converts public/sample.docx through the real compiled bridge and writes the
// canonical Markdown to src/data/sample.ts, so the static hero shows exactly
// what the live converter produces. Run after make-sample.mjs (and after any
// bridge rebuild). Usage: node scripts/capture-sample-md.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

globalThis.self = globalThis;
const require = createRequire(import.meta.url);
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const website = path.join(__dirname, '..');

require(path.join(website, 'public/converter/converter.js'));
await new Promise((r) => setTimeout(r, 50));

const bytes = new Uint8Array(fs.readFileSync(path.join(website, 'public/sample.docx')));
const res = await globalThis.docxToMarkdownConvert(bytes, { flavor: 'gfm' });
if (res.error) {
  console.error('convert error:', res.error);
  process.exit(1);
}

const md = res.markdown;
const ts = `// AUTO-GENERATED from public/sample.docx by scripts/capture-sample-md.mjs.
// Do not edit by hand. Re-run the script if the sample or bridge changes.
export const SAMPLE_FILENAME = 'project-brief.docx';
export const SAMPLE_SRC = '/sample.docx';
export const SAMPLE_MARKDOWN = ${JSON.stringify(md)};
`;
fs.writeFileSync(path.join(website, 'src/data/sample.ts'), ts);
console.log(`captured ${md.length} chars, ${res.warnings.length} warning(s)`);
console.log('--------\n' + md + '\n--------');
