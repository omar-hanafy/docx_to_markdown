import 'package:docx_to_markdown/docx_to_markdown.dart';
import 'package:docx_to_markdown/src/ir.dart';
import 'package:docx_to_markdown/src/markdown_renderer.dart';
import 'package:test/test.dart';

void main() {
  group('MarkdownRenderer', () {
    test('renders headings with clamped level and line breaks', () {
      final doc = Document(
        blocks: [
          HeadingBlock(
            level: 7,
            inlines: const [
              TextInline('Hello'),
              LineBreakInline(),
              TextInline('World'),
            ],
          ),
        ],
      );

      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults,
      ).render(doc);
      expect(markdown.trim(), '###### Hello<br>World');
    });

    test('renders inline formatting and escapes', () {
      final doc = Document(
        blocks: [
          ParagraphBlock([
            const TextInline('A '),
            StrongInline([const TextInline('B')]),
            const TextInline(' '),
            EmphInline([const TextInline('I')]),
            const TextInline(' '),
            UnderlineInline([const TextInline('U')]),
            const TextInline(' '),
            StrikeInline([const TextInline('S')]),
            const TextInline(' '),
            SubInline([const TextInline('2')]),
            const TextInline(' '),
            SupInline([const TextInline('3')]),
            const TextInline(' '),
            const CodeInline('code`tick'),
          ]),
        ],
      );

      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults,
      ).render(doc);
      expect(
        markdown.trim(),
        'A **B** *I* <u>U</u> ~~S~~ <sub>2</sub> <sup>3</sup> ``code`tick``',
      );
    });

    test('respects underline mode plusPlus', () {
      final doc = Document(
        blocks: [
          ParagraphBlock([
            UnderlineInline([const TextInline('U')]),
          ]),
        ],
      );
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults.copyWith(
          underlineMode: UnderlineMode.plusPlus,
        ),
      ).render(doc);
      expect(markdown.trim(), '++U++');
    });

    test('respects underline mode ignore', () {
      final doc = Document(
        blocks: [
          ParagraphBlock([
            UnderlineInline([const TextInline('U')]),
          ]),
        ],
      );
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults.copyWith(
          underlineMode: UnderlineMode.ignore,
        ),
      ).render(doc);
      expect(markdown.trim(), 'U');
    });

    test('renders line breaks based on config', () {
      final doc = Document(
        blocks: [
          ParagraphBlock(const [
            TextInline('Hello'),
            LineBreakInline(),
            TextInline('World'),
          ]),
        ],
      );

      final hard = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults.copyWith(
          lineBreakStyle: LineBreakStyle.hardBreak,
        ),
      ).render(doc);
      expect(
        hard.trim(),
        '''
Hello  
World
'''
            .trim(),
      );

      final html = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults.copyWith(
          lineBreakStyle: LineBreakStyle.htmlBr,
        ),
      ).render(doc);
      expect(
        html.trim(),
        '''
Hello<br/>
World
'''
            .trim(),
      );

      final soft = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults.copyWith(
          lineBreakStyle: LineBreakStyle.newline,
        ),
      ).render(doc);
      expect(
        soft.trim(),
        '''
Hello
World
'''
            .trim(),
      );
    });

    test('renders ordered list with keep numbering', () {
      final list = ListBlock(
        ordered: true,
        start: 3,
        items: [
          ListItem(
            blocks: [
              ParagraphBlock([const TextInline('A')]),
            ],
          ),
          ListItem(
            blocks: [
              ParagraphBlock([const TextInline('B')]),
            ],
          ),
        ],
      );
      final doc = Document(blocks: [list]);
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults.copyWith(
          orderedListNumbering: OrderedListNumbering.keep,
        ),
      ).render(doc);
      expect(markdown.trim(), '3. A\n4. B');
    });

    test('auto list tightness respects config.tightLists=false', () {
      final list = ListBlock(
        ordered: false,
        tightness: ListTightness.auto,
        items: [
          ListItem(
            blocks: [
              ParagraphBlock([const TextInline('A')]),
              ParagraphBlock([const TextInline('A2')]),
            ],
          ),
          ListItem(
            blocks: [
              ParagraphBlock([const TextInline('B')]),
              ParagraphBlock([const TextInline('B2')]),
            ],
          ),
        ],
      );
      final doc = Document(blocks: [list]);
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults.copyWith(tightLists: false),
      ).render(doc);
      expect(markdown.contains('\n\n- B'), isTrue);
    });

    test('renders ordered list with alwaysOne numbering', () {
      final list = ListBlock(
        ordered: true,
        start: 5,
        items: [
          ListItem(
            blocks: [
              ParagraphBlock([const TextInline('A')]),
            ],
          ),
          ListItem(
            blocks: [
              ParagraphBlock([const TextInline('B')]),
            ],
          ),
        ],
      );
      final doc = Document(blocks: [list]);
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults.copyWith(
          orderedListNumbering: OrderedListNumbering.alwaysOne,
        ),
      ).render(doc);
      expect(markdown.trim(), '1. A\n1. B');
    });

    test('renders loose list with blank lines', () {
      final list = ListBlock(
        ordered: false,
        tightness: ListTightness.loose,
        items: [
          ListItem(
            blocks: [
              ParagraphBlock([const TextInline('A')]),
            ],
          ),
          ListItem(
            blocks: [
              ParagraphBlock([const TextInline('B')]),
            ],
          ),
        ],
      );
      final doc = Document(blocks: [list]);
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults,
      ).render(doc);
      expect(markdown.trim(), '- A\n\n- B');
    });

    test('renders markdown tables when simple', () {
      final table = TableBlock(
        grid: TableGrid(
          rows: [
            TableRow(
              cells: [
                TableCell(
                  blocks: [
                    ParagraphBlock([const TextInline('H1')]),
                  ],
                ),
                TableCell(
                  blocks: [
                    ParagraphBlock([const TextInline('H2')]),
                  ],
                ),
              ],
              isHeader: true,
            ),
            TableRow(
              cells: [
                TableCell(
                  blocks: [
                    ParagraphBlock([const TextInline('A')]),
                  ],
                ),
                TableCell(
                  blocks: [
                    ParagraphBlock([const TextInline('B')]),
                  ],
                ),
              ],
            ),
          ],
        ),
        alignments: const [TableAlign.left, TableAlign.right],
      );
      final doc = Document(blocks: [table]);
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults,
      ).render(doc);
      expect(markdown.trim(), '| H1 | H2 |\n|:---|---:|\n| A | B |');
    });

    test('renders list and code inside HTML table cells', () {
      final table = TableBlock(
        grid: TableGrid(
          rows: [
            TableRow(
              cells: [
                TableCell(
                  blocks: [
                    ListBlock(
                      ordered: false,
                      items: [
                        ListItem(
                          blocks: [
                            ParagraphBlock([const TextInline('A')]),
                          ],
                        ),
                        ListItem(
                          blocks: [
                            ParagraphBlock([const TextInline('B')]),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
                TableCell(blocks: [const CodeBlock(text: 'code')]),
              ],
            ),
          ],
        ),
      );
      final doc = Document(blocks: [table]);
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults.copyWith(
          tableMode: TableMode.htmlOnly,
        ),
      ).render(doc);
      expect(markdown.contains('<ul>'), isTrue);
      expect(markdown.contains('<pre><code>code</code></pre>'), isTrue);
    });

    test('forces markdown tables in markdownOnly mode', () {
      final table = TableBlock(
        grid: TableGrid(
          rows: [
            TableRow(
              cells: [
                TableCell(
                  blocks: [
                    ParagraphBlock([const TextInline('H')]),
                  ],
                ),
              ],
            ),
            TableRow(
              cells: [
                TableCell(
                  blocks: [
                    ParagraphBlock([const TextInline('A')]),
                  ],
                ),
                TableCell(
                  blocks: [
                    ParagraphBlock([const TextInline('B')]),
                  ],
                ),
              ],
            ),
          ],
        ),
      );
      final doc = Document(blocks: [table]);
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults.copyWith(
          tableMode: TableMode.markdownOnly,
        ),
      ).render(doc);
      expect(markdown.contains('| A | B |'), isTrue);
    });

    test('renders HTML tables when commonmark auto', () {
      final table = TableBlock(
        grid: TableGrid(
          rows: [
            TableRow(
              cells: [
                TableCell(
                  blocks: [
                    ParagraphBlock([const TextInline('H')]),
                  ],
                ),
              ],
            ),
            TableRow(
              cells: [
                TableCell(
                  blocks: [
                    ParagraphBlock([const TextInline('A')]),
                  ],
                ),
              ],
            ),
          ],
        ),
      );
      final doc = Document(blocks: [table]);
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults.copyWith(
          flavor: MarkdownFlavor.commonmark,
          tableMode: TableMode.auto,
        ),
      ).render(doc);
      expect(markdown.trim().startsWith('<table>'), isTrue);
    });

    test('falls back to HTML tables for complex grids', () {
      final table = TableBlock(
        grid: TableGrid(
          rows: [
            TableRow(
              cells: [
                TableCell(
                  blocks: [
                    ParagraphBlock([const TextInline('A')]),
                  ],
                  colSpan: 2,
                ),
              ],
            ),
            TableRow(
              cells: [
                TableCell(
                  blocks: [
                    ParagraphBlock([const TextInline('B')]),
                  ],
                ),
                TableCell(
                  blocks: [
                    ParagraphBlock([const TextInline('C')]),
                  ],
                ),
              ],
            ),
          ],
        ),
      );
      final doc = Document(blocks: [table]);
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults,
      ).render(doc);
      expect(markdown.trim().startsWith('<table>'), isTrue);
    });

    test('renders math blocks with bracket fallback', () {
      final doc = Document(
        blocks: const [MathBlock(r'$$x+y$$'), MathBlock(r'x+y')],
      );
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults,
      ).render(doc);
      expect(markdown.contains(r'\['), isTrue);
      expect(markdown.contains(r'$$'), isTrue);
    });

    test('emits warnings as HTML comments when enabled', () {
      final doc = Document(
        blocks: [
          ParagraphBlock([const TextInline('Hi')]),
        ],
        warnings: const [
          DocWarning(
            code: 'unsupported.block',
            message: 'Unsupported block element',
            location: SourceLocation(part: 'doc', path: 'p[1]'),
          ),
        ],
      );
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults.copyWith(
          emitWarningsAsHtmlComments: true,
        ),
      ).render(doc);
      expect(markdown.contains('unsupported.block'), isTrue);
    });

    test('renders images with size hints', () {
      final doc = Document(
        blocks: [
          ParagraphBlock([const ImageInline(src: 'img.png', alt: 'Alt')]),
        ],
      );
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults.copyWith(
          maxImageWidth: 300,
          imageSizeMode: ImageSizeMode.obsidian,
        ),
      ).render(doc);
      expect(markdown.trim(), '![Alt](img.png =300x)');
    });

    test('rewrites link and image targets via hooks', () {
      final doc = Document(
        blocks: [
          ParagraphBlock([
            LinkInline(
              url: 'https://old.example',
              children: [const TextInline('Link')],
            ),
            const TextInline(' '),
            const ImageInline(src: 'old.png', alt: 'Alt'),
          ]),
        ],
      );
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig(
          hooks: DocxToMarkdownHooks(
            rewriteLinkTarget: (url, [ctx]) => 'https://new.example',
            rewriteImageTarget: (src, [ctx]) => 'new.png',
          ),
        ),
      ).render(doc);
      expect(markdown.trim(), '[Link](https://new.example) ![Alt](new.png)');
    });

    test('renders blockquotes', () {
      final doc = Document(
        blocks: [
          QuoteBlock([
            ParagraphBlock([const TextInline('Quote')]),
          ]),
        ],
      );
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults,
      ).render(doc);
      expect(markdown.trim(), '> Quote');
    });

    test('renders quote containing a list', () {
      final doc = Document(
        blocks: [
          QuoteBlock([
            ListBlock(
              ordered: false,
              items: [
                ListItem(
                  blocks: [
                    ParagraphBlock([const TextInline('Item')]),
                  ],
                ),
              ],
            ),
          ]),
        ],
      );
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults,
      ).render(doc);
      expect(markdown.trim(), '> - Item');
    });

    test('escapes paragraph line starts to avoid list marker', () {
      final doc = Document(
        blocks: [
          ParagraphBlock([const TextInline('- not a list')]),
        ],
      );
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults,
      ).render(doc);
      expect(markdown.trim(), r'\- not a list');
    });

    test('escapes other paragraph line start triggers (asserted)', () {
      final doc = Document(
        blocks: [
          ParagraphBlock([
            const TextInline('# Heading'),
            const LineBreakInline(),
            const TextInline('> Quote'),
            const LineBreakInline(),
            const TextInline('1. Item'),
            const LineBreakInline(),
            const TextInline('```'),
            const LineBreakInline(),
            const TextInline('---'),
          ]),
        ],
      );
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults.copyWith(
          lineBreakStyle: LineBreakStyle.newline,
        ),
      ).render(doc);
      expect(markdown.contains(r'\# Heading'), isTrue);
      expect(markdown.contains(r'\> Quote'), isTrue);
      expect(markdown.contains(r'\1. Item'), isTrue);
      expect(markdown.contains(r'\`'), isTrue);
      expect(markdown.contains(r'\---'), isTrue);
    });

    test('renders default image when no size hints', () {
      final doc = Document(
        blocks: [
          ParagraphBlock([const ImageInline(src: 'img.png', alt: 'Alt')]),
        ],
      );
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults.copyWith(
          maxImageWidth: 0,
          imageSizeMode: ImageSizeMode.none,
        ),
      ).render(doc);
      expect(markdown.trim(), '![Alt](img.png)');
    });

    test('renders horizontal rules', () {
      final doc = Document(blocks: const [HorizontalRuleBlock()]);
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults,
      ).render(doc);
      expect(markdown.trim(), '---');
    });

    test('skips footnotes when includeFootnotes is false', () {
      final doc = Document(
        blocks: [
          ParagraphBlock([const TextInline('Body')]),
        ],
        footnotes: {
          '1': FootnoteDefinition(
            id: '1',
            blocks: [
              ParagraphBlock([const TextInline('Note')]),
            ],
          ),
        },
      );
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults.copyWith(includeFootnotes: false),
      ).render(doc);
      expect(markdown.contains('[^1]:'), isFalse);
    });

    test('renders images with pandoc size hints', () {
      final doc = Document(
        blocks: [
          ParagraphBlock([const ImageInline(src: 'img.png', alt: 'Alt')]),
        ],
      );
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults.copyWith(
          maxImageWidth: 250,
          imageSizeMode: ImageSizeMode.pandoc,
        ),
      ).render(doc);
      expect(markdown.trim(), '![Alt](img.png){ width=250px }');
    });

    test('renders images as HTML when size mode is none', () {
      final doc = Document(
        blocks: [
          ParagraphBlock([const ImageInline(src: 'img.png', alt: 'Alt')]),
        ],
      );
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults.copyWith(
          maxImageWidth: 200,
          imageSizeMode: ImageSizeMode.none,
        ),
      ).render(doc);
      expect(markdown.trim(), '<img src="img.png" alt="Alt" width="200"/>');
    });

    test('renders HTML blocks as-is', () {
      final doc = Document(
        blocks: const [HtmlBlock('<div>Hi</div>\n<span>There</span>')],
      );
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults,
      ).render(doc);
      expect(markdown.trim(), '<div>Hi</div>\n<span>There</span>');
    });

    test('escapes link destinations with spaces', () {
      final doc = Document(
        blocks: [
          ParagraphBlock([
            LinkInline(
              url: 'https://example.com/a b',
              children: [const TextInline('link')],
            ),
          ]),
        ],
      );
      final markdown = MarkdownRenderer(
        config: DocxToMarkdownConfig.defaults,
      ).render(doc);
      expect(markdown.trim(), '[link](<https://example.com/a%20b>)');
    });
  });
}
