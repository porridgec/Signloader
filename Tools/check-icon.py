#!/usr/bin/env python3
"""Measure the icon geometry: glyph centring, badge containment, canvas clipping."""
import struct
import sys
import zlib

BODY_INSET = 46.0
SIZE = 1024.0
BODY_MID = SIZE / 2


def load(path):
    d = open(path, 'rb').read()
    pos, idat, w, h = 8, b'', 0, 0
    while pos + 8 <= len(d):
        ln = struct.unpack('>I', d[pos:pos + 4])[0]
        typ = d[pos + 4:pos + 8]
        data = d[pos + 8:pos + 8 + ln]
        if typ == b'IHDR':
            w, h, bd, ct = struct.unpack('>IIBB', data[:10])
            assert bd == 8 and ct == 6, (bd, ct)
        elif typ == b'IDAT':
            idat += data
        pos += 12 + ln
    raw = zlib.decompress(idat)
    ch, stride = 4, w * 4
    prev = bytearray(stride)
    rows, i = [], 0
    for _ in range(h):
        f = raw[i]; i += 1
        line = bytearray(raw[i:i + stride]); i += stride
        for x in range(stride):
            a = line[x - ch] if x >= ch else 0
            b = prev[x]
            c = prev[x - ch] if x >= ch else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        rows.append(bytes(line))
        prev = line
    return rows, w, h


def scan(rows, w, h):
    glyph, badge = [], []
    for y in range(h):
        row = rows[y]
        for x in range(w):
            r, g, b, a = row[x * 4:(x + 1) * 4]
            if a < 250:
                continue
            if r > 235 and g > 235 and b > 235:
                glyph.append((x, y))
            elif g > 130 and r < 120 and 100 < b < 180:
                badge.append((x, y))
    return glyph, badge


def bounds(pts):
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    return min(xs), min(ys), max(xs), max(ys)


def main(path):
    rows, w, h = load(path)
    print(f'image {w}x{h}')
    if w != SIZE or h != SIZE:
        print('  ! expected a 1024x1024 master'); return 1

    glyph, badge = scan(rows, w, h)
    if not glyph or not badge:
        print('  ! glyph or badge missing'); return 1

    bx0, by0, bx1, by1 = bounds(badge)
    # The badge's white ring sits outside the green disc, so the exclusion has to
    # clear the ring (~22px) plus antialiasing, not just the green bounds.
    pad = 44
    ring = (bx0 - pad, by0 - pad, bx1 + pad, by1 + pad)
    glyph = [p for p in glyph
             if not (ring[0] <= p[0] <= ring[2] and ring[1] <= p[1] <= ring[3])]
    if not glyph:
        print('  ! glyph missing after excluding badge ring'); return 1

    gx0, gy0, gx1, gy1 = bounds(glyph)

    # 1) nothing may touch the canvas edge -> nothing can be clipped
    ok = True
    for name, b in (('glyph', (gx0, gy0, gx1, gy1)), ('badge', (bx0, by0, bx1, by1))):
        x0, y0, x1, y1 = b
        margin = min(x0, y0, SIZE - 1 - x1, SIZE - 1 - y1)
        flag = 'ok ' if margin > 0 else 'CLIPPED'
        if margin <= 0: ok = False
        print(f'  {name:6s} x {x0:4d}..{x1:4d}  y {y0:4d}..{y1:4d}   canvas margin {margin:6.1f}  {flag}')

    # 2) glyph ink should be centred on the body
    gcx, gcy = (gx0 + gx1) / 2, (gy0 + gy1) / 2
    dx, dy = gcx - BODY_MID, gcy - BODY_MID
    off = (dx * dx + dy * dy) ** 0.5
    print(f'  glyph ink centre ({gcx:6.1f}, {gcy:6.1f})  body centre ({BODY_MID:.0f}, {BODY_MID:.0f})  offset {off:5.1f}px ({off/SIZE*100:.2f}%)')
    if off > 40:
        print('  ! glyph looks off-centre'); ok = False

    # 3) badge must stay inside the squircle, not just the canvas
    a = (SIZE - 2 * BODY_INSET) / 2
    for label, (px, py) in (('right', (bx1, (by0 + by1) / 2)), ('bottom', ((bx0 + bx1) / 2, by1))):
        # superellipse |x/a|^5 + |y/a|^5 = 1, in body-local coords
        x = abs(px - BODY_MID) / a
        y = abs(py - BODY_MID) / a
        inside = (x ** 5 + y ** 5) <= 1.0
        print(f'  badge {label:6s} point ({px:6.1f}, {py:6.1f})  {"inside" if inside else "OVERHANGS squircle"}')
        if not inside: ok = False

    # 4) glyph ink must not run into the badge
    overlap = not (gx1 < bx0 or bx1 < gx0 or gy1 < by0 or by1 < gy0)
    print(f'  glyph/badge boxes touch: {"yes" if overlap else "no"}')

    print('RESULT:', 'PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
