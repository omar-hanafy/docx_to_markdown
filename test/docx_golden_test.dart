// Golden-file test suite: converts every `test/docx_golden/<name>.docx` and
// compares the result to the committed `<name>.md`.
//
// Regenerate expected files after an intentional change:
//   dart run tool/update_goldens.dart            (all cases)
//   dart run tool/update_goldens.dart lists       (one case by name)
//
// Then review the diff before committing.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'golden/golden_support.dart';

void main() {
  final cases = discoverCases();

  if (cases.isEmpty) {
    test(
      'docx golden fixtures present',
      () {},
      skip: 'No .docx files under test/docx_golden/ yet.',
    );
    return;
  }

  group('docx golden', () {
    for (final c in cases) {
      test(c.name, () async {
        final result = await convertCase(c);
        addTearDown(() async {
          if (result.imageDir.existsSync()) {
            await result.imageDir.delete(recursive: true);
          }
        });

        // Every referenced local image must have been extracted to disk.
        for (final target in imageTargets(result.markdown)) {
          if (target.startsWith('data:') ||
              target.startsWith('http://') ||
              target.startsWith('https://')) {
            continue;
          }
          expect(
            File(p.join(result.imageDir.path, target)).existsSync(),
            isTrue,
            reason: 'Referenced image missing on disk: $target',
          );
        }

        final expectedFile = File(c.expectedPath);
        expect(
          expectedFile.existsSync(),
          isTrue,
          reason:
              'Missing ${p.relative(c.expectedPath)}. '
              'Run: dart run tool/update_goldens.dart ${c.name}',
        );
        expect(result.markdown, normalize(expectedFile.readAsStringSync()));
      });
    }
  });
}
