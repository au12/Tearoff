#!/usr/bin/env python3
"""Builds synthetic shipping-label PDFs that mimic the layouts real carrier and
marketplace sites produce. Every name, address and tracking number is fake.

    python3 tests/make_fixtures.py            # -> tests/fixtures/*.pdf + expected.json

Needs: reportlab, pymupdf, pillow.
"""
import io
import json
import math
import os

import pymupdf
from PIL import Image
from reportlab.graphics import renderPDF
from reportlab.graphics.barcode import code128, createBarcodeDrawing
from reportlab.lib.utils import ImageReader
from reportlab.pdfgen import canvas

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "fixtures")
IN = 72.0
LETTER = (8.5 * IN, 11 * IN)

UPS_TRACK = "1Z999AA10123456784"
POSTAL = "420627019205"
USPS_TRACK = "9400111899223197428490"


# ---------------------------------------------------------------- label art

def draw_label(c, carrier="ups", tracking=UPS_TRACK, frame=True, ref="TEST-REF-001"):
    """Draws one portrait 4x6 label into (0,0)-(288,432) of the current canvas
    coordinate system (reportlab: origin bottom-left)."""
    W, H = 4 * IN, 6 * IN
    c.saveState()
    c.setFillColorRGB(0, 0, 0)
    c.setStrokeColorRGB(0, 0, 0)
    if frame:
        c.setLineWidth(1.2)
        c.rect(0, 0, W, H, stroke=1, fill=0)
    # sender block
    c.setFont("Helvetica-Bold", 8)
    y = H - 14
    for line in ("JANE SAMPLE", "100 TEST AVENUE", "SPRINGFIELD IL 62701-0001"):
        c.drawString(8, y, line); y -= 9
    c.setFont("Helvetica-Bold", 11)
    c.drawRightString(W - 8, H - 16, "2 LBS   1 OF 1")
    # ship-to block
    c.setFont("Helvetica-Bold", 15)
    c.drawString(8, H - 70, "SHIP")
    c.drawString(8, H - 86, "TO:")
    c.setFont("Helvetica-Bold", 11)
    y = H - 62
    for line in ("ACME RETURNS CENTER", "DOCK 7", "500 WAREHOUSE ROAD", "ATLANTA GA 30349-0002"):
        c.drawString(60, y, line); y -= 13
    c.setLineWidth(2)
    c.line(0, H - 122, W, H - 122)
    # 2D code (stands in for MaxiCode / PDF417) + postal routing barcode
    dm = createBarcodeDrawing("ECC200DataMatrix", value="FAKE MAXI " + tracking)
    s = 92.0 / dm.width
    c.saveState(); c.translate(10, H - 222); c.scale(s, s); renderPDF.draw(dm, c, 0, 0); c.restoreState()
    c.setFont("Helvetica-Bold", 26)
    c.drawString(118, H - 152, "GA 303 9-02")
    bc = code128.Code128(POSTAL, barWidth=1.0, barHeight=46, humanReadable=False, quiet=False)
    bc.drawOn(c, 118, H - 214)
    c.setLineWidth(2)
    c.line(0, H - 232, W, H - 232)
    # service banner with a solid black box
    c.rect(W - 56, H - 290, 48, 50, stroke=0, fill=1)
    c.setFont("Helvetica-Bold", 20)
    c.drawString(8, H - 258, "UPS GROUND" if carrier == "ups" else "PRIORITY MAIL")
    c.setFont("Helvetica", 9)
    pretty = " ".join(tracking[i:i + 4] for i in range(0, len(tracking), 4))
    c.drawString(8, H - 274, "TRACKING #: " + pretty)
    c.setLineWidth(1)
    c.line(0, H - 296, W, H - 296)
    # tracking barcode
    bc = code128.Code128(tracking, barWidth=0.75, barHeight=70, humanReadable=False, quiet=False)
    bc.drawOn(c, (W - bc.width) / 2, H - 380)
    c.setLineWidth(2)
    c.line(0, H - 390, W, H - 390)
    c.setFont("Helvetica-Bold", 8)
    c.drawString(8, 26, "BILLING: P/P")
    c.drawString(8, 16, "REFERENCE: " + ref)
    c.setFont("Helvetica-Bold", 22)
    c.drawRightString(W - 8, 12, "E7")
    c.restoreState()


def label_pdf_bytes(**kw):
    buf = io.BytesIO()
    c = canvas.Canvas(buf, pagesize=(4 * IN, 6 * IN))
    draw_label(c, **kw)
    c.showPage(); c.save()
    return buf.getvalue()


def label_png(dpi, landscape_ccw=False, **kw):
    """Rasterizes the vector label to a 1-bit-looking PNG like carrier APIs return."""
    doc = pymupdf.open(stream=label_pdf_bytes(**kw), filetype="pdf")
    pix = doc[0].get_pixmap(dpi=dpi, colorspace="gray", alpha=False)
    im = Image.frombytes("L", (pix.width, pix.height), pix.samples)
    im = im.point(lambda v: 0 if v < 128 else 255)
    if landscape_ccw:  # carrier gave us the label lying on its side: top of label faces left
        im = im.transpose(Image.Transpose.ROTATE_90)
    return im.convert("RGB")


def img_reader(im):
    b = io.BytesIO(); im.save(b, "PNG"); b.seek(0)
    return ImageReader(b)


def paragraph(c, x, y, lines, size=9, lead=12):
    c.setFont("Helvetica", size)
    for ln in lines:
        c.drawString(x, y, ln); y -= lead
    return y


INSTRUCTIONS = [
    "Make sure no other tracking labels are on your package.",
    "Affix the mailing label squarely onto the address side of the parcel.",
    "Bring your package to any drop-off location before the return deadline.",
]


def dashed_rect(c, x, y, w, h):
    c.saveState(); c.setDash(4, 3); c.setLineWidth(1); c.setStrokeColorRGB(0.45, 0.45, 0.45)
    c.rect(x, y, w, h, stroke=1, fill=0); c.restoreState()


def logo_image():
    im = Image.new("RGB", (467, 135), "white")
    px = im.load()
    for x in range(467):
        for y in range(135):
            v = int(255 * (0.5 + 0.5 * math.sin(x / 23.0) * math.cos(y / 17.0)))
            px[x, y] = (v, 120, 255 - v)
    return im


def code128_image(value, module=3, height=120):
    """Raster Code 128 (as web pages embed for slips/receipts)."""
    doc = pymupdf.open()
    buf = io.BytesIO()
    c = canvas.Canvas(buf, pagesize=(400, 100))
    bc = code128.Code128(value, barWidth=1, barHeight=60, humanReadable=False, quiet=True)
    bc.drawOn(c, 0, 20)
    c.showPage(); c.save()
    doc = pymupdf.open(stream=buf.getvalue(), filetype="pdf")
    pix = doc[0].get_pixmap(dpi=72 * module, colorspace="gray", clip=pymupdf.Rect(0, 20, bc.width, 80))
    return Image.frombytes("L", (pix.width, pix.height), pix.samples).convert("RGB")


# ---------------------------------------------------------------- fixtures

def fx_image_letter_dashed(path):
    """Amazon/Firefox return page: landscape label image squashed non-uniformly inside a dashed cut line."""
    c = canvas.Canvas(path, pagesize=LETTER)
    W, H = LETTER
    c.drawImage(img_reader(logo_image()), 36, H - 70, 120, 34.7)
    c.setFont("Helvetica-Bold", 11); c.drawString(36, H - 100, "Additional instructions for mailing your package")
    paragraph(c, 44, H - 118, ["- " + s for s in INSTRUCTIONS])
    c.setFont("Helvetica-Bold", 11); c.drawString(36, H - 172, "Return Mailing Label")
    c.setFont("Helvetica", 9); c.drawString(36, H - 190, "Cut this label and affix to the outside of the return package")
    im = label_png(300, landscape_ccw=True)               # 1800 x 1200
    x, w, h = 94.8, 373.65, 240.66                        # same odd squash Firefox produced
    y = H - 437.9
    dashed_rect(c, x - 1.6, y - 1.6, w + 3.2, h + 3.2)
    c.drawImage(img_reader(im), x, y, w, h)
    c.setFont("Helvetica-Bold", 11); c.drawString(36, H - 470, "Return Authorization Slip")
    c.setFont("Helvetica", 9); c.drawString(36, H - 488, "Place this barcode inside your return package.")
    c.drawImage(img_reader(code128_image("RMASLIP42")), 168, H - 567, 227.5, 65.8)
    c.setFont("Helvetica-Bold", 9); c.drawString(40, H - 600, "Item Descriptions")
    c.setFont("Helvetica", 9); c.drawString(40, H - 616, "Digital Watch | 50M WR | Stopwatch | Countdown Timer | LED Backlight")
    c.showPage(); c.save()
    return {"labels": [{"barcodes": [UPS_TRACK, POSTAL], "source": "image"}]}


def fx_vector_letter_framed(path):
    """USPS Click-N-Ship style: framed portrait vector label at the top, fold line + receipt below."""
    c = canvas.Canvas(path, pagesize=LETTER)
    W, H = LETTER
    c.saveState(); c.translate(0.5 * IN, H - 0.5 * IN - 6 * IN)
    draw_label(c, carrier="usps", tracking=USPS_TRACK)
    c.restoreState()
    c.saveState(); c.setDash(6, 4); c.line(18, H - 7 * IN, W - 18, H - 7 * IN); c.restoreState()
    c.setFont("Helvetica-Oblique", 8); c.drawCentredString(W / 2, H - 7 * IN + 4, "FOLD HERE")
    y = paragraph(c, 0.5 * IN, H - 7.4 * IN, ["Instructions:"] + ["  " + s for s in INSTRUCTIONS] +
                  ["Customer receipt — keep for your records."])
    code128.Code128("RECEIPT0001", barWidth=0.9, barHeight=28, humanReadable=True).drawOn(c, 0.5 * IN, y - 40)
    c.showPage(); c.save()
    return {"labels": [{"barcodes": [USPS_TRACK, POSTAL], "source": "vector"}]}


def fx_vector_letter_unframed_rotated(path):
    """Unframed vector label lying on its side in the top half (top faces right: needs a counter-clockwise turn)."""
    c = canvas.Canvas(path, pagesize=LETTER)
    W, H = LETTER
    c.saveState()
    c.translate(1.25 * IN, H - 0.75 * IN - 4 * IN)   # bottom-left of the 6x4 landscape footprint
    c.translate(0, 4 * IN); c.rotate(-90)            # label top now faces right
    draw_label(c, frame=False)
    c.restoreState()
    y = paragraph(c, 0.75 * IN, H - 5.6 * IN, ["Return instructions"] + INSTRUCTIONS * 2)
    c.setFont("Helvetica", 9)
    for i in range(6):
        c.drawString(0.75 * IN, y - 20 - i * 12, f"Item {i + 1}   Widget, blue, size M            qty 1")
    c.showPage(); c.save()
    return {"labels": [{"barcodes": [UPS_TRACK, POSTAL], "source": "vector"}]}


def fx_two_up(path):
    """Two framed 4x6 labels side by side with dashed cut lines (Pirate Ship / Shippo 2-up)."""
    c = canvas.Canvas(path, pagesize=LETTER)
    W, H = LETTER
    for i, trk in enumerate((UPS_TRACK, "1Z999AA10123456795")):
        x = 0.25 * IN + i * 4.0 * IN
        c.saveState(); c.translate(x, H - 0.5 * IN - 6 * IN)
        draw_label(c, tracking=trk, frame=False, ref=f"TWOUP-{i + 1}")
        c.restoreState()
        dashed_rect(c, x - 2, H - 0.5 * IN - 6 * IN - 2, 4 * IN + 4, 6 * IN + 4)
    paragraph(c, 0.5 * IN, H - 7.2 * IN, ["Cut along the dashed lines."])
    c.showPage(); c.save()
    return {"labels": [{"barcodes": [UPS_TRACK]}, {"barcodes": ["1Z999AA10123456795"]}]}


def fx_two_landscape_stacked(path):
    """Two unframed labels on their sides, stacked top/bottom (eBay-style half sheets)."""
    c = canvas.Canvas(path, pagesize=LETTER)
    W, H = LETTER
    for i, trk in enumerate((UPS_TRACK, "1Z999AA10123456795")):
        top = H - 0.5 * IN - i * 5.25 * IN
        c.saveState(); c.translate(1.25 * IN, top - 4 * IN)
        c.translate(0, 4 * IN); c.rotate(-90)
        draw_label(c, tracking=trk, frame=True, ref=f"STACK-{i + 1}")
        c.restoreState()
    c.showPage(); c.save()
    return {"labels": [{"barcodes": [UPS_TRACK]}, {"barcodes": ["1Z999AA10123456795"]}]}


def fx_page_4x6_vector(path):
    c = canvas.Canvas(path, pagesize=(4 * IN, 6 * IN))
    draw_label(c, frame=False)
    c.showPage(); c.save()
    return {"labels": [{"barcodes": [UPS_TRACK, POSTAL], "source": "page"}]}


def fx_page_4x6_raster203(path):
    c = canvas.Canvas(path, pagesize=(4 * IN, 6 * IN))
    im = label_png(203)
    assert im.size == (812, 1218), im.size
    c.drawImage(img_reader(im), 0, 0, 4 * IN, 6 * IN)
    c.showPage(); c.save()
    return {"labels": [{"barcodes": [UPS_TRACK, POSTAL], "source": "image"}]}


def fx_browser_4x6_shrunk(path, letter_pdf):
    """Chrome printing the Amazon-style page onto 4x6 paper: the whole letter layout shrunk with margins."""
    src = pymupdf.open(letter_pdf)
    dst = pymupdf.open()
    page = dst.new_page(width=4 * IN, height=6 * IN)
    m = 0.2 * IN
    s = (4 * IN - 2 * m) / LETTER[0]
    page.show_pdf_page(pymupdf.Rect(m, m, m + LETTER[0] * s, m + LETTER[1] * s), src, 0)
    dst.save(path)
    return {"labels": [{"barcodes": [UPS_TRACK, POSTAL], "source": "image"}]}


def fx_multipage(path):
    c = canvas.Canvas(path, pagesize=LETTER)
    W, H = LETTER
    c.setFont("Helvetica-Bold", 16); c.drawString(0.75 * IN, H - IN, "Your return is ready")
    paragraph(c, 0.75 * IN, H - 1.4 * IN, INSTRUCTIONS * 3)
    c.showPage()
    c.saveState(); c.translate(0.5 * IN, H - 0.5 * IN - 6 * IN)
    draw_label(c, tracking=USPS_TRACK, carrier="usps")
    c.restoreState()
    c.showPage(); c.save()
    return {"labels": [{"barcodes": [USPS_TRACK], "page": 2}]}


def fx_image_portrait_300(path):
    """FedEx-style: portrait 300 dpi label image at true size in the top-left, no border."""
    c = canvas.Canvas(path, pagesize=LETTER)
    W, H = LETTER
    c.drawImage(img_reader(label_png(300)), 0.25 * IN, H - 0.25 * IN - 6 * IN, 4 * IN, 6 * IN)
    paragraph(c, 4.6 * IN, H - 0.6 * IN, ["Shipping instructions", "1. Fold the page", "2. Tape it securely",
                                          "3. Drop off at any location"])
    c.showPage(); c.save()
    return {"labels": [{"barcodes": [UPS_TRACK, POSTAL], "source": "image"}]}


def fx_two_up_unframed(path):
    """Two unframed portrait labels side by side, no cut lines at all."""
    c = canvas.Canvas(path, pagesize=LETTER)
    W, H = LETTER
    for i, trk in enumerate((UPS_TRACK, "1Z999AA10123456795")):
        c.saveState(); c.translate(0.25 * IN + i * 4.0 * IN, H - 0.5 * IN - 6 * IN)
        draw_label(c, tracking=trk, frame=False, ref=f"UNFRAMED-{i + 1}")
        c.restoreState()
    paragraph(c, 0.5 * IN, H - 7.2 * IN, ["Two labels per sheet."])
    c.showPage(); c.save()
    return {"labels": [{"barcodes": [UPS_TRACK]}, {"barcodes": ["1Z999AA10123456795"]}]}


def fx_photo_and_label(path):
    """A product photo with label-like proportions must not be mistaken for the label."""
    c = canvas.Canvas(path, pagesize=LETTER)
    W, H = LETTER
    photo = logo_image().resize((900, 600))
    c.drawImage(img_reader(photo), 0.75 * IN, H - 0.5 * IN - 2 * IN, 3 * IN, 2 * IN)
    c.setFont("Helvetica-Bold", 12); c.drawString(4.1 * IN, H - 1 * IN, "Your item: Widget, blue")
    c.saveState(); c.translate(0.75 * IN, H - 3 * IN - 6 * IN)
    draw_label(c, tracking=USPS_TRACK, carrier="usps")
    c.restoreState()
    c.showPage(); c.save()
    return {"labels": [{"barcodes": [USPS_TRACK]}]}


def fx_vector_shrunk_4x6(path, letter_pdf):
    """A vector letter page printed onto 4x6 paper by a browser (label ends up ~45% size)."""
    return fx_browser_4x6_shrunk(path, letter_pdf) and {"labels": [{"barcodes": [USPS_TRACK]}]}


def main():
    os.makedirs(OUT, exist_ok=True)
    expected = {}
    fx = [
        ("01_image_letter_dashed.pdf", fx_image_letter_dashed),
        ("02_vector_letter_framed.pdf", fx_vector_letter_framed),
        ("03_vector_letter_unframed_rotated.pdf", fx_vector_letter_unframed_rotated),
        ("04_two_up.pdf", fx_two_up),
        ("05_two_landscape_stacked.pdf", fx_two_landscape_stacked),
        ("06_page_4x6_vector.pdf", fx_page_4x6_vector),
        ("07_page_4x6_raster203.pdf", fx_page_4x6_raster203),
        ("09_multipage.pdf", fx_multipage),
        ("10_image_portrait_300.pdf", fx_image_portrait_300),
        ("11_two_up_unframed.pdf", fx_two_up_unframed),
        ("12_photo_and_label.pdf", fx_photo_and_label),
    ]
    for name, fn in fx:
        expected[name] = fn(os.path.join(OUT, name))
    expected["08_browser_4x6_shrunk.pdf"] = fx_browser_4x6_shrunk(
        os.path.join(OUT, "08_browser_4x6_shrunk.pdf"), os.path.join(OUT, "01_image_letter_dashed.pdf"))
    expected["13_vector_shrunk_4x6.pdf"] = fx_vector_shrunk_4x6(
        os.path.join(OUT, "13_vector_shrunk_4x6.pdf"), os.path.join(OUT, "02_vector_letter_framed.pdf"))
    with open(os.path.join(OUT, "expected.json"), "w") as f:
        json.dump(dict(sorted(expected.items())), f, indent=2)
    print("wrote", len(expected), "fixtures to", OUT)


if __name__ == "__main__":
    main()
