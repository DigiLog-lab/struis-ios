---
name: struis-document
description: Read what the learner attached. Use whenever an answer depends on an attached PDF or image, on a PDF page that was not attached as an image, on small print, or on a tall screenshot or page.
metadata:
  short-description: Read attached PDFs and images with struis.document
  struis-waiting:
    pdf:
      started: PDF の読み方を確かめています
      finished: PDF の読み方を確かめました
    image:
      started: 写真の見方を確かめています
      finished: 写真の見方を確かめました
    default:
      started: 資料の読み方を確かめています
      finished: 資料の読み方を確かめました
---

# Reading attachments

The learner's PDFs and images are listed in the inbox manifest (`tutor_desk/inbox/.../manifest.md`). Open them with the `struis.document` tool using the paths written there (`document_path` or `original_path`). PDF command-line tools and Python PDF libraries are not installed.

## Rules

1. Read before answering. Only the first pages of a PDF are attached as images. When the learner asks about any other page, read that page with `struis.document` first. Never guess what a page says from its number, the outline, or nearby pages.
2. Find the page, then read it.
   - `info` gives the page count, the outline, which pages have a text layer, and how many parts a tall page splits into.
   - `search` with a word from the question finds the pages that contain it.
   - `text` reads up to 10 pages. Pages without a text layer come back as on-device OCR and are marked so. Check OCR text against `render` when a symbol, number or formula matters.
   - `render` shows up to 4 page images, for figures, handwriting, layout and formulas.
3. Look closer instead of guessing.
   - Small print: `render` with `crop` [x0,y0,x1,y1] (0-1, top-left origin) on the region.
   - Tall screenshots and tall pages: `render` with `part` N for each part listed by `info` or the manifest.
   - If a part is still unreadable after a closer look, tell the learner which part is unclear and ask for a closer photo or a typed excerpt.
4. Read it yourself for a quick check. Checking one page or one image is faster with `struis.document` than with a delegated lookup. Delegate only a wide search across materials; then put the inbox manifest or the `document_path` in `sources`.
5. Keep the work private. Do not mention paths, the manifest, tool names, this skill, OCR or rendering to the learner. Say what the material says.
