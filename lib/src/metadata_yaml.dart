// metadata_yaml.dart
//
// Renders [DocumentMetadata] as a Pandoc-friendly YAML front matter block.
//
// This is a small, self-contained YAML emitter (no third-party YAML dependency)
// covering exactly the shapes metadata needs: scalars, a string list
// (keywords), and a one-level nested map (custom). Output is deterministic.

import 'package:docx_to_markdown/src/ir.dart';

/// Renders [meta] as a YAML front matter block delimited by `---` lines, or an
/// empty string when [DocumentMetadata.isEmpty].
///
/// Keys use Pandoc-friendly names and a fixed, deterministic order: `title`,
/// `author` (from `creator`), `subject`, `description`, `keywords`, `lang`
/// (from `language`), `category`, `created`, `modified`, `lastModifiedBy`,
/// `revision`, then any [DocumentMetadata.extra] keys (sorted), then a nested
/// `custom` map (keys sorted). The returned string has no trailing newline.
String renderMetadataFrontMatter(DocumentMetadata meta) {
  if (meta.isEmpty) return '';

  final out = <String>['---'];

  void field(String key, String? value) {
    if (value != null) _emitKeyValue(out, key, value, indent: 0);
  }

  field('title', meta.title);
  field('author', meta.creator);
  field('subject', meta.subject);
  field('description', meta.description);

  if (meta.keywords.isNotEmpty) {
    out.add('keywords:');
    for (final keyword in meta.keywords) {
      out.add('  - ${yamlEncodeScalar(keyword)}');
    }
  }

  field('lang', meta.language);
  field('category', meta.category);
  field('created', meta.created);
  field('modified', meta.modified);
  field('lastModifiedBy', meta.lastModifiedBy);
  field('revision', meta.revision);

  for (final key in meta.extra.keys.toList()..sort()) {
    _emitKeyValue(out, key, meta.extra[key]!, indent: 0);
  }

  if (meta.custom.isNotEmpty) {
    out.add('custom:');
    for (final key in meta.custom.keys.toList()..sort()) {
      _emitKeyValue(out, key, meta.custom[key]!, indent: 2);
    }
  }

  out.add('---');
  return out.join('\n');
}

/// Emits a `key: value` entry, choosing a block scalar for safe multiline
/// values and an inline (plain or double-quoted) scalar otherwise.
void _emitKeyValue(
  List<String> out,
  String key,
  String value, {
  required int indent,
}) {
  final pad = ' ' * indent;
  final encodedKey = yamlEncodeScalar(key);

  if (value.contains('\n')) {
    final lines = value.split('\n');
    // A literal block scalar auto-detects indentation from its first line, so a
    // leading space would be ambiguous; fall back to a quoted scalar there.
    final firstContent = lines.firstWhere(
      (l) => l.isNotEmpty,
      orElse: () => '',
    );
    if (!firstContent.startsWith(' ')) {
      final endsWithNewline = value.endsWith('\n');
      out.add('$pad$encodedKey: ${endsWithNewline ? '|' : '|-'}');
      final body = endsWithNewline
          ? value.substring(0, value.length - 1)
          : value;
      for (final line in body.split('\n')) {
        out.add(line.isEmpty ? '' : '$pad  $line');
      }
      return;
    }
  }

  out.add('$pad$encodedKey: ${yamlEncodeScalar(value)}');
}

const Set<String> _yamlReserved = {
  'true',
  'false',
  'null',
  '~',
  'yes',
  'no',
  'y',
  'n',
  'on',
  'off',
};

final RegExp _numberLike = RegExp(r'^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$');

// Characters that make a plain scalar unsafe anywhere they appear (including a
// backslash, so it is always escaped via the double-quoted form).
final RegExp _dangerousChars = RegExp(r'''[:#\[\]{}&<>'"|\\]''');

// Characters that are unsafe only as the first character of a plain scalar.
const Set<String> _leadingIndicators = {
  '-', '?', ':', ',', '[', ']', '{', '}', '#', '&', //
  '*', '!', '|', '>', "'", '"', '%', '@', '`',
};

/// Encodes a single-line [value] as a YAML scalar: returned plain when safe,
/// otherwise double-quoted with backslash/quote/control-char escaping.
///
/// Quoting is conservative - it triggers on empty or whitespace-padded values,
/// YAML reserved words and numbers (kept as strings), structural punctuation
/// (`:`, `#`, `&`, `<`, `>`, brackets, quotes, `|`), and leading indicator
/// characters. Non-ASCII letters are not a trigger. This function is internal;
/// it is exposed for direct testing of the quoting rules.
String yamlEncodeScalar(String value) =>
    _needsQuoting(value) ? _doubleQuote(value) : value;

bool _needsQuoting(String value) {
  if (value.isEmpty) return true;
  if (value.trimLeft() != value || value.trimRight() != value) return true;
  if (_yamlReserved.contains(value.toLowerCase())) return true;
  if (_numberLike.hasMatch(value)) return true;
  if (value.contains('\n') || value.contains('\r')) return true;
  if (_dangerousChars.hasMatch(value)) return true;
  if (_leadingIndicators.contains(value[0])) return true;
  return false;
}

String _doubleQuote(String value) {
  final sb = StringBuffer('"');
  for (final unit in value.codeUnits) {
    switch (unit) {
      case 0x5C: // backslash
        sb.write(r'\\');
      case 0x22: // double quote
        sb.write(r'\"');
      case 0x0A: // newline
        sb.write(r'\n');
      case 0x0D: // carriage return
        sb.write(r'\r');
      case 0x09: // tab
        sb.write(r'\t');
      default:
        if (unit < 0x20) {
          sb.write('\\x');
          sb.write(unit.toRadixString(16).padLeft(2, '0'));
        } else {
          sb.writeCharCode(unit);
        }
    }
  }
  sb.write('"');
  return sb.toString();
}
