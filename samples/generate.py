# generates test PDFs for OCR testing
# requires: pip install Pillow fpdf2

from PIL import Image, ImageDraw, ImageFont
from fpdf import FPDF
import os

OUT = os.path.dirname(os.path.abspath(__file__))
A4_W, A4_H = 2480, 3508  # pixels at 300 DPI
PT = 300 // 72  # pixels per point

SAMPLE_TEXT = """Rechnung Nr. 2026-0042

Datum: 22.06.2026

Kunde:
Max Mustermann
Musterstrasse 42
12345 Berlin

Positionen:
  1x Bürostuhl ergonomisch    289,00 EUR
  2x Monitorhalterung          79,80 EUR
  1x Schreibtischleuchte       45,50 EUR
  5x Kugelschreiber blau       12,50 EUR
                              ----------
  Gesamt (netto)              426,80 EUR
  MwSt. 19%                    81,09 EUR
                              ----------
  Gesamt (brutto)             507,89 EUR

Zahlung innerhalb von 14 Tagen ohne Abzug.
Vielen Dank fuer Ihren Einkauf."""


def _load_font(size):
    paths = [
        "/System/Library/Fonts/Helvetica.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "C:\\Windows\\Fonts\\arial.ttf",
    ]
    for p in paths:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except OSError:
                continue
    return ImageFont.load_default()


def create_scan_pdf():
    img = Image.new("RGB", (A4_W, A4_H), "white")
    draw = ImageDraw.Draw(img)
    font = _load_font(36)
    y = 200
    for line in SAMPLE_TEXT.split("\n"):
        draw.text((200, y), line, fill="black", font=font)
        y += 60
    path = os.path.join(OUT, "sample_notext.pdf")
    img.save(path, "PDF", resolution=300)
    print(f"created {path}  ({os.path.getsize(path)} bytes)")
    return path


def create_text_pdf():
    pdf = FPDF(orientation="P", unit="mm", format="A4")
    pdf.add_page()
    pdf.set_font("Helvetica", size=16)
    for line in SAMPLE_TEXT.split("\n"):
        if line.strip() == "":
            pdf.ln(8)
        else:
            pdf.cell(0, 10, text=line, new_x="LMARGIN", new_y="NEXT")
    path = os.path.join(OUT, "sample_text.pdf")
    pdf.output(path)
    print(f"created {path}  ({os.path.getsize(path)} bytes)")
    return path


if __name__ == "__main__":
    create_scan_pdf()
    create_text_pdf()
    print("done")
