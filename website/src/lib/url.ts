// Base-aware URL helpers.
//
// The site can be deployed either at a domain root (base '/') or under a
// subpath (e.g. omar-hanafy.github.io/docx-to-markdown/). Astro exposes the
// configured base as `import.meta.env.BASE_URL` - '/' at root, or
// '/docx-to-markdown/' under a subpath. Every internal, root-relative link and
// asset must be prefixed with it or it will 404 under a subpath.
//
// Vite statically replaces `import.meta.env.BASE_URL` at build time, so this
// works in .astro frontmatter, client <script>s, endpoints, and plain modules.

const RAW = import.meta.env.BASE_URL ?? '/';
/** Base with no trailing slash: '' at root, '/docx-to-markdown' under a subpath. */
const BASE = RAW === '/' ? '' : RAW.replace(/\/$/, '');

/**
 * Prefix an internal, root-relative path (e.g. '/features', '/og.png') with the
 * deploy base. Leaves external URLs, protocol-relative URLs, hashes and
 * non-root paths untouched, and is idempotent (won't double-prefix).
 */
export function withBase(path = '/'): string {
  if (!path.startsWith('/') || path.startsWith('//')) return path;
  if (BASE && (path === BASE || path.startsWith(BASE + '/'))) return path;
  return BASE + path || '/';
}
