#!/usr/bin/env python3
"""Write a one-page PDF (no dependencies) for install-time self-tests."""

import sys


def build(text):
    text = "".join(c if 32 <= ord(c) < 127 and c not in "()\\" else " " for c in text)
    stream = "BT /F1 24 Tf 72 770 Td (%s) Tj ET\n" % text
    objs = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] "
        "/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        "<< /Length %d >>\nstream\n%sendstream" % (len(stream), stream),
    ]
    out = bytearray("%PDF-1.4\n".encode())
    offsets = []
    for i, body in enumerate(objs, start=1):
        offsets.append(len(out))
        out += ("%d 0 obj\n%s\nendobj\n" % (i, body)).encode()
    xref = len(out)
    out += ("xref\n0 %d\n0000000000 65535 f \n" % len(offsets)).encode()
    for off in offsets:
        out += ("%010d 00000 n \n" % off).encode()
    out += ("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n"
            % (len(offsets) + 1, xref)).encode()
    return bytes(out)


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: make-test-pdf.py <out.pdf> [text]")
    text = sys.argv[2] if len(sys.argv) > 2 else "pdfprint self-test"
    with open(sys.argv[1], "wb") as fh:
        fh.write(build(text))


if __name__ == "__main__":
    main()
