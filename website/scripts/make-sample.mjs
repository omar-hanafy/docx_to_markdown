// Generates public/sample.docx - the document behind "Try the sample".
// Run once with:  node scripts/make-sample.mjs
// Crafted to show off real fidelity: headings, inline formatting, a link,
// a nested bulleted list, a table with a header row, and a blockquote.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  Document,
  Packer,
  Paragraph,
  TextRun,
  HeadingLevel,
  Table,
  TableRow,
  TableCell,
  WidthType,
  ExternalHyperlink,
} from 'docx';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.join(__dirname, '..', 'public', 'sample.docx');

const cell = (text, opts = {}) =>
  new TableCell({
    children: [new Paragraph({ children: [new TextRun({ text, ...opts })] })],
    width: { size: 33, type: WidthType.PERCENTAGE },
  });

const doc = new Document({
  creator: 'docx-to-markdown demo',
  title: 'Project Brief: Northwind Redesign',
  description: 'A sample document for the docx-to-markdown converter demo.',
  styles: {
    paragraphStyles: [
      {
        id: 'Quote',
        name: 'Quote',
        basedOn: 'Normal',
        next: 'Normal',
        quickFormat: true,
        run: { italics: true, color: '555555' },
        paragraph: { indent: { left: 360 }, spacing: { before: 120, after: 120 } },
      },
    ],
  },
  sections: [
    {
      children: [
        new Paragraph({
          heading: HeadingLevel.HEADING_1,
          children: [new TextRun('Project Brief: Northwind Redesign')],
        }),
        new Paragraph({
          children: [
            new TextRun('The '),
            new TextRun({ text: 'Northwind', bold: true }),
            new TextRun(' storefront is overdue for a '),
            new TextRun({ text: 'ground-up', italics: true }),
            new TextRun(
              ' redesign. This brief captures the goals, the timeline, and the open questions. Live status lives on the ',
            ),
            new ExternalHyperlink({
              children: [new TextRun({ text: 'tracking board' })],
              link: 'https://example.com/board',
            }),
            new TextRun('.'),
          ],
        }),

        new Paragraph({ heading: HeadingLevel.HEADING_2, text: 'Goals' }),
        new Paragraph({ text: 'Cut time-to-first-purchase in half.', bullet: { level: 0 } }),
        new Paragraph({
          text: 'Unify the design system across web and mobile.',
          bullet: { level: 0 },
        }),
        new Paragraph({
          text: 'Ship a reusable component library.',
          bullet: { level: 1 },
        }),
        new Paragraph({ text: 'Reach a Lighthouse score of 95+.', bullet: { level: 0 } }),

        new Paragraph({ heading: HeadingLevel.HEADING_2, text: 'Timeline' }),
        new Table({
          width: { size: 100, type: WidthType.PERCENTAGE },
          rows: [
            new TableRow({
              tableHeader: true,
              children: [
                cell('Phase'),
                cell('Owner'),
                cell('Status'),
              ],
            }),
            new TableRow({
              children: [cell('Discovery'), cell('Ana'), cell('Done')],
            }),
            new TableRow({
              children: [cell('Design system'), cell('Priya'), cell('In progress')],
            }),
            new TableRow({
              children: [cell('Build & launch'), cell('Marco'), cell('Not started')],
            }),
          ],
        }),

        new Paragraph({ heading: HeadingLevel.HEADING_2, text: 'A note on scope' }),
        new Paragraph({
          style: 'Quote',
          children: [
            new TextRun(
              'Keep the first release small. Ship the checkout flow, measure, then expand.',
            ),
          ],
        }),
      ],
    },
  ],
});

const buffer = await Packer.toBuffer(doc);
fs.writeFileSync(OUT, buffer);
console.log('Wrote', OUT, `(${buffer.length} bytes)`);
