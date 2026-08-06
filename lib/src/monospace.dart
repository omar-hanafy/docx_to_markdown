// monospace.dart
//
// The single source of truth for "is this font family monospace?".
//
// Both the run-level check (a `w:rFonts` directly on a `w:r`) and the
// style-level check (a font reached through `w:rStyle` or `w:pStyle`) resolve
// through this file. They used to hold separate lists, so the same font was
// code one way and plain text the other.

import 'package:meta/meta.dart';

/// Monospace font hints used to detect code runs.
///
/// Each entry matches a font family name when the entry's words appear as a
/// contiguous run of *whole words* in the family name. Word boundaries make
/// `mono` match "SF Mono" and "Liberation Mono" while leaving the Monotype
/// foundry names ("Monotype Corsiva", a script face) alone.
const List<String> kDefaultMonospaceFonts = <String>[
  // Generic tokens. These carry most of the recall: nearly every modern
  // monospace family ends in a standalone "Mono" word.
  'mono', 'monospace', 'monospaced',

  // Families whose names contain no "mono" word.
  'consolas', 'courier', 'menlo', 'monaco', 'inconsolata',
  'source code', 'fira code', 'cascadia code', 'anonymous pro',
  'lucida console', 'lucida sans typewriter',
  'hack', 'iosevka', 'monofonto', 'monolisa', 'freemono',
  'letter gothic', 'prestige elite', 'nanum gothic coding',
  'ocr a', 'ocr b', 'fixedsys', 'terminus', 'proggy',
];

// Splits camelCase and PascalCase runs so "SFMono-Regular" and "JetBrainsMono"
// tokenize the same way their display names do. A family genuinely spelled
// "MonoType" would split to "mono type" and match, but the foundry spells it
// "Monotype", so the collision is theoretical.
final RegExp _wordBoundary = RegExp(
  r'(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])',
);
final RegExp _nonAlphanumeric = RegExp(r'[^a-z0-9]+');

/// Normalizes an OOXML font family name to lowercase, space-separated words.
String normalizeFontName(String raw) => raw
    .trim()
    .replaceAll(_wordBoundary, ' ')
    .toLowerCase()
    .replaceAll(_nonAlphanumeric, ' ')
    .trim();

/// The single decision procedure for "is this font monospace?".
///
/// Matching is whole-word containment: an entry matches when its word sequence
/// appears as a contiguous run of complete words in the normalized family name.
/// Raw substring matching cannot separate the family token `Mono` from the
/// foundry prefix `Monotype`, and papering over that needs a deny-list - a
/// second list to keep in sync, which is the failure this file exists to
/// remove.
@immutable
class MonospaceFontMatcher {
  /// Compiles [families] into a matcher.
  MonospaceFontMatcher(Iterable<String> families)
    : _hints = {
        for (final family in families)
          if (normalizeFontName(family).isNotEmpty)
            ' ${normalizeFontName(family)} ',
      };

  /// The matcher for [kDefaultMonospaceFonts].
  static final MonospaceFontMatcher defaults = MonospaceFontMatcher(
    kDefaultMonospaceFonts,
  );

  final Set<String> _hints;

  /// Whether this matcher recognizes no fonts at all.
  bool get isEmpty => _hints.isEmpty;

  /// Whether [fontName] names a monospace family.
  bool matches(String? fontName) {
    if (_hints.isEmpty || fontName == null) return false;
    final normalized = normalizeFontName(fontName);
    if (normalized.isEmpty) return false;
    final padded = ' $normalized ';
    for (final hint in _hints) {
      if (padded.contains(hint)) return true;
    }
    return false;
  }
}
