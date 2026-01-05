import 'dart:io';
import 'package:docx_to_markdown/docx_to_markdown.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    print('Usage: dart example/docx_to_markdown_example.dart <path_to_docx>');
    exit(1);
  }

  final filePath = args.first;
  final file = File(filePath);

  if (!file.existsSync()) {
    print('Error: File "$filePath" not found.');
    exit(1);
  }

  try {
    // 1. Read the file bytes
    final bytes = await file.readAsBytes();

    // 2. Configure the converter
    final config = DocxToMarkdownConfig(
      flavor: MarkdownFlavor.gfm,
      extractImages: true,
      imageSizeMode: ImageSizeMode.obsidian, // ![alt](src =WxH)
      paragraphStyleOverrides: {
        // Map custom styles from your Word doc to Markdown constructs
        'MyCustomCode': const ParagraphStyleOverride(
          isCodeBlock: true,
          codeLanguage: 'yaml',
        ),
        'MyCallout': const ParagraphStyleOverride(isQuote: true),
      },
      hooks: DocxToMarkdownHooks(
        // Example: Log warnings to console
        onWarning: (warning, ctx) {
          print('[WARN] ${warning.message} at ${ctx.location}');
        },
        // Example: Rewrite image paths to be relative to a specific folder
        rewriteImageTarget: (src, [ctx]) {
          // You might upload `src` to a CDN here and return the URL.
          // For now, we just prepend a folder.
          return 'images/${src.split('/').last}';
        },
      ),
    );

    // 3. Initialize converter
    final converter = DocxConverter(bytes, config: config);

    // 4. Convert!
    // We specify an output directory for images if we want them extracted.
    final markdown = await converter.convert(
      imageOutputDirectory: 'out/images',
    );

    // 5. Output result
    print('--- Markdown Output ---');
    print(markdown);
    print('-----------------------');
  } catch (e, st) {
    print('Conversion failed: $e');
    print(st);
    exit(1);
  }
}
