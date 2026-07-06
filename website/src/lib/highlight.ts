/**
 * A small, dependency-free Markdown highlighter.
 *
 * It wraps Markdown syntax in <span class="t-*"> tokens WITHOUT adding or
 * removing any characters, so `element.textContent` of the result is always the
 * exact original Markdown (safe to copy). Output is HTML-escaped, so it is safe
 * to assign via innerHTML / set:html. This is cosmetic - correctness of the
 * Markdown itself comes from the converter, not from here.
 */

// A sentinel that will never occur in real text (NUL), used to stash tokens.
const NUL = String.fromCharCode(0);

function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function span(cls: string, text: string): string {
  return `<span class="${cls}">${text}</span>`;
}

/** Highlight inline constructs in an ALREADY-ESCAPED string. */
function highlightInline(escaped: string): string {
  const stash: string[] = [];
  const keep = (html: string) => {
    stash.push(html);
    return `${NUL}${stash.length - 1}${NUL}`;
  };

  let s = escaped;

  // Inline code first - its contents must not be reparsed.
  s = s.replace(/`([^`]+)`/g, (_m, code) => keep(span('t-ic', '`' + code + '`')));

  // Images / links: color the URL, dim the punctuation.
  s = s.replace(
    /(!?)\[([^\]]*)\]\(([^)\s]+)([^)]*)\)/g,
    (_m, bang, text, url, rest) =>
      keep(
        span('t-mk', bang + '[') +
          text +
          span('t-mk', '](') +
          span('t-link', url + rest) +
          span('t-mk', ')'),
      ),
  );

  // Footnote references.
  s = s.replace(/\[\^([^\]]+)\]/g, (_m, id) => keep(span('t-link', '[^' + id + ']')));

  // Emphasis: bold, then italic (* and _), then strikethrough.
  s = s.replace(/(\*\*|__)(?=\S)([\s\S]+?\S)\1/g, (_m, mk, t) =>
    span('t-strong', mk + t + mk),
  );
  s = s.replace(/(^|[^*\\])\*(?=\S)([^*\n]+?\S)\*/g, (_m, pre, t) =>
    pre + span('t-em', '*' + t + '*'),
  );
  s = s.replace(/(^|[^_\w\\])_(?=\S)([^_\n]+?\S)_(?![\w])/g, (_m, pre, t) =>
    pre + span('t-em', '_' + t + '_'),
  );
  s = s.replace(/~~(?=\S)([\s\S]+?\S)~~/g, (_m, t) => span('t-del', '~~' + t + '~~'));

  // Restore stashed tokens.
  s = s.replace(new RegExp(NUL + '(\\d+)' + NUL, 'g'), (_m, i) => stash[Number(i)]);
  return s;
}

/** Turn a Markdown string into token-highlighted, HTML-escaped markup. */
export function tokenizeMarkdown(md: string): string {
  const lines = md.replace(/\r\n?/g, '\n').split('\n');
  const out: string[] = [];
  let inFence = false;

  for (const raw of lines) {
    const esc = escapeHtml(raw);

    const fence = /^\s*(```|~~~)/.test(raw);
    if (fence) {
      inFence = !inFence;
      out.push(span('t-fence', esc));
      continue;
    }
    if (inFence) {
      out.push(span('t-code', esc));
      continue;
    }

    // YAML front-matter fence.
    if (/^---\s*$/.test(raw)) {
      out.push(span('t-mk', esc));
      continue;
    }

    // Heading.
    let m = /^(#{1,6})(\s+)(.*)$/.exec(raw);
    if (m) {
      out.push(
        span('t-hd-mk', escapeHtml(m[1])) +
          m[2] +
          span('t-hd', highlightInline(escapeHtml(m[3]))),
      );
      continue;
    }

    // Blockquote.
    m = /^(\s*>[>\s]*)(.*)$/.exec(raw);
    if (m) {
      out.push(
        span('t-mk', escapeHtml(m[1])) +
          span('t-quote', highlightInline(escapeHtml(m[2]))),
      );
      continue;
    }

    // Thematic break.
    if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(raw)) {
      out.push(span('t-mk', esc));
      continue;
    }

    // Table rows.
    if (/^\s*\|.*\|\s*$/.test(raw)) {
      if (/^\s*\|?[\s:|-]+\|?\s*$/.test(raw) && raw.includes('-')) {
        out.push(span('t-mk', esc)); // separator row
      } else {
        out.push(
          raw
            .split('|')
            .map((c) => highlightInline(escapeHtml(c)))
            .join(span('t-mk', '|')),
        );
      }
      continue;
    }

    // List item.
    m = /^(\s*)([-*+]|\d+[.)])(\s+)(.*)$/.exec(raw);
    if (m) {
      out.push(
        m[1] +
          span('t-mk', escapeHtml(m[2])) +
          m[3] +
          highlightInline(escapeHtml(m[4])),
      );
      continue;
    }

    // Footnote definition.
    m = /^(\s*)(\[\^[^\]]+\]:)(.*)$/.exec(raw);
    if (m) {
      out.push(
        m[1] + span('t-link', escapeHtml(m[2])) + highlightInline(escapeHtml(m[3])),
      );
      continue;
    }

    out.push(highlightInline(esc));
  }

  return out.join('\n');
}
