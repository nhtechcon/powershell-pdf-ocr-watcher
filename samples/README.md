# Test Samples

| File                | Size | Description                                                                    |
| ------------------- | ---- | ------------------------------------------------------------------------------ |
| `sample_notext.pdf` | 210K | Scan-like PDF (image only, no text layer). The watcher should OCR this file.   |
| `sample_text.pdf`   | 1.3K | PDF with embedded selectable text. The watcher should skip it (`--skip-text`). |

Regenerate with:

```bash
pip install Pillow fpdf2
python generate.py
```
