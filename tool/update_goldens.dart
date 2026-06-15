// Regenerates the expected Markdown for the DOCX golden suite.
//
// Usage:
//   dart run tool/update_goldens.dart            # regenerate every case
//   dart run tool/update_goldens.dart lists tables   # only the named cases
//
// It reuses the exact conversion path the test suite asserts against
// (test/golden/golden_support.dart), writes each `<name>.md`, and prints a
// summary. Review the diff before committing.
import 'dart:io';

import 'package:path/path.dart' as p;

import '../test/golden/golden_support.dart';

Future<void> main(List<String> args) async {
  final filter = args.toSet();
  final cases = discoverCases().where(
    (c) => filter.isEmpty || filter.contains(c.name),
  );

  if (cases.isEmpty) {
    stderr.writeln(
      filter.isEmpty
          ? 'No .docx fixtures found under test/docx_golden/.'
          : 'No golden cases matched: ${filter.join(', ')}',
    );
    exitCode = 1;
    return;
  }

  for (final c in cases) {
    final result = await convertCase(c);
    try {
      File(c.expectedPath).writeAsStringSync(result.markdown);
      stdout.writeln('updated  ${p.relative(c.expectedPath)}');
    } finally {
      if (result.imageDir.existsSync()) {
        await result.imageDir.delete(recursive: true);
      }
    }
  }
}
