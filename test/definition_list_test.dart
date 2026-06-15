import 'dart:typed_data';

import 'package:docx_to_markdown/docx_to_markdown.dart';
import 'package:docx_to_markdown/src/markdown_renderer.dart';
import 'package:docx_to_markdown/src/ooxml_package.dart';
import 'package:docx_to_markdown/src/parser.dart';
import 'package:docx_to_markdown/src/styles.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

import 'utils/docx_fixture.dart';

/// Parses [bytes] into the IR, wiring the StyleRegistry exactly like
/// [DocxConverter] does so style-driven detection (headings, code, definition
/// lists) is exercised end to end.
Future<Document> parseDocument(
  Uint8List bytes, {
  DocxToMarkdownConfig? config,
  void Function(DocWarning)? onWarning,
}) async {
  final cfg = config ?? DocxToMarkdownConfig.defaults;
  final pkg = DocxPackage.openBytes(bytes);
  try {
    final styles = StyleRegistry();
    styles.setMonospaceFonts(cfg.monospaceFonts);
    styles.load(pkg.stylesXml);
    if (cfg.codeBlockStyleName.isNotEmpty) {
      styles.addCodeStyleName(cfg.codeBlockStyleName);
    }
    final parser = DocxParser(
      package: pkg,
      styles: styles,
      config: cfg,
      mediaMap: const {},
      onWarning: onWarning ?? (_) {},
    );
    return parser.parseMainDocument();
  } finally {
    await pkg.close();
  }
}

/// Builds a styles.xml string defining the Pandoc-style "Definition Term" and
/// "Definition" paragraph styles plus a "Verbatim Char" monospace character
/// style, mirroring a real Pandoc reference document.
///
/// When [termStyleId]/[defStyleId] differ from the canonical ids, the visible
/// w:name still carries "Definition Term"/"Definition" so the style-name
/// fallback can be exercised.
String definitionStylesXml({
  bool boldTerm = false,
  String termStyleId = 'DefinitionTerm',
  String defStyleId = 'Definition',
}) {
  final termRpr = boldTerm ? '<w:rPr><w:b/></w:rPr>' : '';
  return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
  <w:style w:type="paragraph" w:customStyle="1" w:styleId="$termStyleId">
    <w:name w:val="Definition Term"/>
    <w:basedOn w:val="Normal"/>
    $termRpr
  </w:style>
  <w:style w:type="paragraph" w:customStyle="1" w:styleId="$defStyleId">
    <w:name w:val="Definition"/>
    <w:basedOn w:val="Normal"/>
  </w:style>
  <w:style w:type="character" w:customStyle="1" w:styleId="VerbatimChar">
    <w:name w:val="Verbatim Char"/>
    <w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/></w:rPr>
  </w:style>
</w:styles>''';
}

void main() {
  group('StyleRegistry.definitionRole', () {
    StyleRegistry loaded() {
      final reg = StyleRegistry();
      reg.load(XmlDocument.parse(definitionStylesXml()));
      return reg;
    }

    test('resolves Definition Term and Definition styles by id', () {
      final reg = loaded();
      expect(reg.definitionRole('DefinitionTerm'), DefinitionRole.term);
      expect(reg.definitionRole('Definition'), DefinitionRole.definition);
    });

    test('returns null for unrelated styles', () {
      final reg = loaded();
      expect(reg.definitionRole('Normal'), isNull);
      expect(reg.definitionRole('Nope'), isNull);
      expect(reg.definitionRole(null), isNull);
    });

    test('resolves by visible name when the styleId is custom', () {
      final reg = StyleRegistry();
      reg.load(
        XmlDocument.parse(
          definitionStylesXml(termStyleId: 'MyTerm', defStyleId: 'MyDef'),
        ),
      );
      expect(reg.definitionRole('MyTerm'), DefinitionRole.term);
      expect(reg.definitionRole('MyDef'), DefinitionRole.definition);
    });
  });

  group('DefinitionList parsing', () {
    test(
      'term followed by definition groups into a DefinitionListBlock',
      () async {
        final bytes = buildDocxBytes(
          documentXml: docXmlWithBody(
            wP(styleId: 'DefinitionTerm', text: 'Term 1') +
                wP(styleId: 'Definition', text: 'Definition 1'),
          ),
          stylesXml: definitionStylesXml(),
        );

        final doc = await parseDocument(bytes);

        expect(doc.blocks, [
          DefinitionListBlock(
            items: [
              DefinitionListItem(
                term: const [TextInline('Term 1')],
                definitions: [
                  ParagraphBlock(const [TextInline('Definition 1')]),
                ],
              ),
            ],
          ),
        ]);
      },
    );

    test('consecutive definition paragraphs stay under one term', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(
          wP(styleId: 'DefinitionTerm', text: 'Term 2') +
              wP(styleId: 'Definition', text: 'Definition 2') +
              wP(
                styleId: 'Definition',
                innerXml: wR(
                  text: '{ code }',
                  rPrXml: '<w:rStyle w:val="VerbatimChar"/>',
                ),
              ) +
              wP(styleId: 'Definition', text: 'Third paragraph.'),
        ),
        stylesXml: definitionStylesXml(),
      );

      final doc = await parseDocument(bytes);

      expect(doc.blocks, [
        DefinitionListBlock(
          items: [
            DefinitionListItem(
              term: const [TextInline('Term 2')],
              definitions: [
                ParagraphBlock(const [TextInline('Definition 2')]),
                ParagraphBlock(const [CodeInline('{ code }')]),
                ParagraphBlock(const [TextInline('Third paragraph.')]),
              ],
            ),
          ],
        ),
      ]);
    });

    test('multiple items keep their own boundaries', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(
          wP(styleId: 'DefinitionTerm', text: 'T1') +
              wP(styleId: 'Definition', text: 'd1') +
              wP(styleId: 'DefinitionTerm', text: 'T2') +
              wP(styleId: 'Definition', text: 'd2a') +
              wP(styleId: 'Definition', text: 'd2b'),
        ),
        stylesXml: definitionStylesXml(),
      );

      final doc = await parseDocument(bytes);

      expect(doc.blocks, [
        DefinitionListBlock(
          items: [
            DefinitionListItem(
              term: const [TextInline('T1')],
              definitions: [
                ParagraphBlock(const [TextInline('d1')]),
              ],
            ),
            DefinitionListItem(
              term: const [TextInline('T2')],
              definitions: [
                ParagraphBlock(const [TextInline('d2a')]),
                ParagraphBlock(const [TextInline('d2b')]),
              ],
            ),
          ],
        ),
      ]);
    });

    test('preserves italic formatting inside a term', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(
          wP(
                styleId: 'DefinitionTerm',
                innerXml: wR(text: 'Term', rPrXml: '<w:i/>'),
              ) +
              wP(styleId: 'Definition', text: 'd'),
        ),
        stylesXml: definitionStylesXml(),
      );

      final doc = await parseDocument(bytes);
      final item = (doc.blocks.single as DefinitionListBlock).items.single;
      expect(item.term, [
        EmphInline(const [TextInline('Term')]),
      ]);
    });

    test(
      'preserves bold, inline code, and links inside a definition',
      () async {
        final bytes = buildDocxBytes(
          documentXml: docXmlWithBody(
            wP(styleId: 'DefinitionTerm', text: 'Term') +
                wP(
                  styleId: 'Definition',
                  innerXml: wR(text: 'b', rPrXml: '<w:b/>'),
                ) +
                wP(
                  styleId: 'Definition',
                  innerXml: wR(
                    text: 'code',
                    rPrXml: '<w:rStyle w:val="VerbatimChar"/>',
                  ),
                ) +
                wP(
                  styleId: 'Definition',
                  innerXml: wHyperlink(
                    rid: 'rId1',
                    innerXml: wR(text: 'link'),
                  ),
                ),
          ),
          stylesXml: definitionStylesXml(),
          documentRels: const [
            DocxRel(
              id: 'rId1',
              type: DocxRelTypes.hyperlink,
              target: 'https://example.com',
              external: true,
            ),
          ],
        );

        final doc = await parseDocument(bytes);
        final item = (doc.blocks.single as DefinitionListBlock).items.single;
        expect(item.definitions, [
          ParagraphBlock([
            StrongInline(const [TextInline('b')]),
          ]),
          ParagraphBlock(const [CodeInline('code')]),
          ParagraphBlock([
            LinkInline(
              url: 'https://example.com',
              children: const [TextInline('link')],
            ),
          ]),
        ]);
      },
    );

    test('preserves footnote references inside a definition', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(
          wP(styleId: 'DefinitionTerm', text: 'Term') +
              wP(
                styleId: 'Definition',
                innerXml: wR(innerXml: '<w:footnoteReference w:id="2"/>'),
              ),
        ),
        stylesXml: definitionStylesXml(),
      );

      final doc = await parseDocument(bytes);
      final item = (doc.blocks.single as DefinitionListBlock).items.single;
      expect(item.definitions, [
        ParagraphBlock(const [FootnoteRefInline('2')]),
      ]);
    });

    test(
      'term with no following definition is preserved with empty body',
      () async {
        final bytes = buildDocxBytes(
          documentXml: docXmlWithBody(
            wP(styleId: 'DefinitionTerm', text: 'Lonely term') +
                wP(text: 'After'),
          ),
          stylesXml: definitionStylesXml(),
        );

        final doc = await parseDocument(bytes);

        expect(doc.blocks, [
          DefinitionListBlock(
            items: [
              DefinitionListItem(
                term: const [TextInline('Lonely term')],
                definitions: const [],
              ),
            ],
          ),
          ParagraphBlock(const [TextInline('After')]),
        ]);
      },
    );

    test('a non-definition paragraph flushes the grouping', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(
          wP(styleId: 'DefinitionTerm', text: 'T') +
              wP(styleId: 'Definition', text: 'd') +
              wP(text: 'Normal') +
              wP(styleId: 'DefinitionTerm', text: 'T2') +
              wP(styleId: 'Definition', text: 'd2'),
        ),
        stylesXml: definitionStylesXml(),
      );

      final doc = await parseDocument(bytes);

      expect(doc.blocks, [
        DefinitionListBlock(
          items: [
            DefinitionListItem(
              term: const [TextInline('T')],
              definitions: [
                ParagraphBlock(const [TextInline('d')]),
              ],
            ),
          ],
        ),
        ParagraphBlock(const [TextInline('Normal')]),
        DefinitionListBlock(
          items: [
            DefinitionListItem(
              term: const [TextInline('T2')],
              definitions: [
                ParagraphBlock(const [TextInline('d2')]),
              ],
            ),
          ],
        ),
      ]);
    });

    test('orphan definition degrades to a paragraph and warns', () async {
      final warnings = <DocWarning>[];
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(
          wP(styleId: 'Definition', text: 'Orphan definition'),
        ),
        stylesXml: definitionStylesXml(),
      );

      final doc = await parseDocument(bytes, onWarning: warnings.add);

      expect(doc.blocks, [
        ParagraphBlock(const [TextInline('Orphan definition')]),
      ]);
      expect(
        warnings.map((w) => w.code),
        contains('definitionList.orphanDefinition'),
      );
    });

    test(
      'resolves term/definition by visible name with a custom styleId',
      () async {
        final bytes = buildDocxBytes(
          documentXml: docXmlWithBody(
            wP(styleId: 'MyTerm', text: 'Term') +
                wP(styleId: 'MyDef', text: 'Definition'),
          ),
          stylesXml: definitionStylesXml(
            termStyleId: 'MyTerm',
            defStyleId: 'MyDef',
          ),
        );

        final doc = await parseDocument(bytes);

        expect(doc.blocks, [
          DefinitionListBlock(
            items: [
              DefinitionListItem(
                term: const [TextInline('Term')],
                definitions: [
                  ParagraphBlock(const [TextInline('Definition')]),
                ],
              ),
            ],
          ),
        ]);
      },
    );

    test('applies inline hooks to both term and definition content', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(
          wP(styleId: 'DefinitionTerm', text: 'term') +
              wP(styleId: 'Definition', text: 'def'),
        ),
        stylesXml: definitionStylesXml(),
      );
      final config = DocxToMarkdownConfig(
        hooks: DocxToMarkdownHooks(
          transformInline: (node, ctx) =>
              node is TextInline ? TextInline(node.text.toUpperCase()) : node,
        ),
      );

      final doc = await parseDocument(bytes, config: config);
      final item = (doc.blocks.single as DefinitionListBlock).items.single;
      expect(item.term, const [TextInline('TERM')]);
      expect(item.definitions, [
        ParagraphBlock(const [TextInline('DEF')]),
      ]);
    });

    test('attaches the term styleId to item metadata for hooks', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(
          wP(styleId: 'DefinitionTerm', text: 'Term') +
              wP(styleId: 'Definition', text: 'd'),
        ),
        stylesXml: definitionStylesXml(),
      );

      final doc = await parseDocument(bytes);
      final item = (doc.blocks.single as DefinitionListBlock).items.single;
      expect(item.meta?.attributes['styleId'], 'DefinitionTerm');
      expect(item.meta?.attributes['styleName'], 'Definition Term');
    });
  });

  group('DefinitionList rendering', () {
    Document doc(List<DefinitionListItem> items) =>
        Document(blocks: [DefinitionListBlock(items: items)]);

    String render(Document d, {DefinitionListMode? mode}) {
      final cfg = mode == null
          ? DocxToMarkdownConfig.defaults
          : DocxToMarkdownConfig(definitionListMode: mode);
      return MarkdownRenderer(config: cfg).render(d).trim();
    }

    test('HTML mode is the default and emits dl/dt/dd', () {
      final d = doc([
        DefinitionListItem(
          term: const [TextInline('Term')],
          definitions: [
            ParagraphBlock(const [TextInline('Def')]),
          ],
        ),
      ]);
      expect(render(d), '<dl>\n<dt>Term</dt>\n<dd>Def</dd>\n</dl>');
    });

    test('HTML mode wraps multi-block definitions in paragraphs', () {
      final d = doc([
        DefinitionListItem(
          term: [
            StrongInline(const [TextInline('Term')]),
          ],
          definitions: [
            ParagraphBlock(const [TextInline('Definition 2')]),
            ParagraphBlock(const [CodeInline('code')]),
          ],
        ),
      ]);
      expect(
        render(d),
        '<dl>\n<dt><strong>Term</strong></dt>\n<dd>\n'
        '<p>Definition 2</p>\n<p><code>code</code></p>\n</dd>\n</dl>',
      );
    });

    test('HTML mode renders multiple items in one dl', () {
      final d = doc([
        DefinitionListItem(
          term: const [TextInline('A')],
          definitions: [
            ParagraphBlock(const [TextInline('a')]),
          ],
        ),
        DefinitionListItem(
          term: const [TextInline('B')],
          definitions: [
            ParagraphBlock(const [TextInline('b')]),
          ],
        ),
      ]);
      expect(
        render(d),
        '<dl>\n<dt>A</dt>\n<dd>a</dd>\n<dt>B</dt>\n<dd>b</dd>\n</dl>',
      );
    });

    test('HTML mode emits a dt without a dd for an empty definition', () {
      final d = doc([
        DefinitionListItem(
          term: const [TextInline('Lonely')],
          definitions: const [],
        ),
      ]);
      expect(render(d), '<dl>\n<dt>Lonely</dt>\n</dl>');
    });

    test('Pandoc mode emits term and colon-prefixed definition', () {
      final d = doc([
        DefinitionListItem(
          term: const [TextInline('Term')],
          definitions: [
            ParagraphBlock(const [TextInline('Def')]),
          ],
        ),
      ]);
      expect(render(d, mode: DefinitionListMode.pandoc), 'Term\n\n:   Def');
    });

    test('Pandoc mode indents continuation blocks by four spaces', () {
      final d = doc([
        DefinitionListItem(
          term: const [TextInline('Term')],
          definitions: [
            ParagraphBlock(const [TextInline('one')]),
            ParagraphBlock(const [TextInline('two')]),
          ],
        ),
      ]);
      expect(
        render(d, mode: DefinitionListMode.pandoc),
        'Term\n\n:   one\n\n    two',
      );
    });

    test('paragraphs mode degrades to flat term and definition paragraphs', () {
      final d = doc([
        DefinitionListItem(
          term: [
            StrongInline(const [TextInline('Term')]),
          ],
          definitions: [
            ParagraphBlock(const [TextInline('Def')]),
          ],
        ),
      ]);
      expect(render(d, mode: DefinitionListMode.paragraphs), '**Term**\n\nDef');
    });
  });

  group('DefinitionList end-to-end', () {
    test('default conversion produces an HTML definition list', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(
          wP(styleId: 'DefinitionTerm', text: 'Term') +
              wP(styleId: 'Definition', text: 'Def'),
        ),
        stylesXml: definitionStylesXml(),
      );
      final markdown = await DocxConverter(bytes).convert();
      expect(markdown.trim(), '<dl>\n<dt>Term</dt>\n<dd>Def</dd>\n</dl>');
    });

    test('pandoc mode conversion produces Pandoc definition syntax', () async {
      final bytes = buildDocxBytes(
        documentXml: docXmlWithBody(
          wP(styleId: 'DefinitionTerm', text: 'Term') +
              wP(styleId: 'Definition', text: 'Def'),
        ),
        stylesXml: definitionStylesXml(),
      );
      final markdown = await DocxConverter(
        bytes,
        config: DocxToMarkdownConfig(
          definitionListMode: DefinitionListMode.pandoc,
        ),
      ).convert();
      expect(markdown.trim(), 'Term\n\n:   Def');
    });
  });

  group('DefinitionList config', () {
    test('definitionListMode defaults to html', () {
      expect(
        DocxToMarkdownConfig.defaults.definitionListMode,
        DefinitionListMode.html,
      );
    });

    test('copyWith overrides definitionListMode', () {
      final copy = DocxToMarkdownConfig.defaults.copyWith(
        definitionListMode: DefinitionListMode.pandoc,
      );
      expect(copy.definitionListMode, DefinitionListMode.pandoc);
      // Unrelated fields preserved.
      expect(copy.flavor, MarkdownFlavor.gfm);
    });
  });

  group('DefinitionList IR', () {
    test('equality is by term and definitions, ignoring meta', () {
      DefinitionListBlock build({String term = 'T', String def = 'D'}) =>
          DefinitionListBlock(
            items: [
              DefinitionListItem(
                term: [TextInline(term)],
                definitions: [
                  ParagraphBlock([TextInline(def)]),
                ],
                meta: NodeMeta(attributes: {'styleId': 'DefinitionTerm'}),
              ),
            ],
          );

      expect(build(), equals(build()));
      expect(build().hashCode, equals(build().hashCode));
      expect(build() == build(term: 'X'), isFalse);
      expect(build() == build(def: 'Y'), isFalse);
    });
  });
}
