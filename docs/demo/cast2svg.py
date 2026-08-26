#!/usr/bin/env python3
"""Render an asciicast recording as a self-contained animated SVG.

The animation is a stack of frame groups, exactly one of which is visible at a
time: every frame shares one `@keyframes` and is held back into its own slot by
an `animation-delay` of i*step, so N frames cost N delay attributes instead of N
keyframe blocks. Identical rows are emitted once into <defs> and referenced with
<use>, which is what keeps a dense 100-column heatmap from turning into a
multi-megabyte file.

Rows carry no whitespace and no reliance on font metrics: blank cells are
skipped and every run after a gap re-anchors on an explicit x, and the heat
ramp's block glyphs become rects that tile their cells the way a terminal
rasterises them.
"""
import argparse, sys, os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import term


def xterm256(n):
    if n < 16:
        base = ["000000", "800000", "008000", "808000", "000080", "800080",
                "008080", "c0c0c0", "808080", "ff0000", "00ff00", "ffff00",
                "0000ff", "ff00ff", "00ffff", "ffffff"]
        return "#" + base[n]
    if n < 232:
        n -= 16
        lv = [0, 95, 135, 175, 215, 255]
        return "#%02x%02x%02x" % (lv[n // 36], lv[(n // 6) % 6], lv[n % 6])
    v = 8 + (n - 232) * 10
    return "#%02x%02x%02x" % (v, v, v)


ESC = {"&": "&amp;", "<": "&lt;", ">": "&gt;"}


def esc(s):
    return "".join(ESC.get(c, c) for c in s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cast")
    ap.add_argument("out")
    ap.add_argument("--fps", type=float, default=10)
    ap.add_argument("--font-size", type=float, default=15)
    ap.add_argument("--cell-width", type=float, default=9)
    ap.add_argument("--line-height", type=float, default=19)
    ap.add_argument("--pad", type=float, default=14)
    ap.add_argument("--bg", default="#14161b")
    ap.add_argument("--fg", default="#ced4df")
    ap.add_argument("--dim", default="#6b7385")
    ap.add_argument("--radius", type=float, default=8)
    ap.add_argument("--title", default="terminal recording")
    a = ap.parse_args()

    cols, rows, step, fs = term.frames(a.cast, a.fps)

    # Crop the terminal to the ink: the recording is sized so the panel never
    # scrolls, which leaves slack rows and columns that would otherwise render
    # as dead margin.
    used = [(y, x) for f in fs for y, row in enumerate(f)
            for x, cell in enumerate(row) if cell[1] != " "]
    rows = max(y for y, _ in used) + 1
    cols = max(x for _, x in used) + 1
    fs = [tuple(row[:cols] for row in f[:rows]) for f in fs]

    cw, lh, pad = a.cell_width, a.line_height, a.pad
    width = cols * cw + 2 * pad
    height = rows * lh + 2 * pad
    total = len(fs) * step

    # Colour classes, assigned in order of first use so the common ones get the
    # shortest names.
    order, seen = [], set()
    for f in fs:
        for row in f:
            for fgc, _ in row:
                if fgc is not None and fgc not in seen:
                    seen.add(fgc)
                    order.append(fgc)
    alphabet = "abcdefghijklmnopqrstuvwxyz"
    assert len(order) <= len(alphabet), "more colours than class names"
    cls = {c: alphabet[i] for i, c in enumerate(order)}

    def hexof(c):
        return a.dim if c == "dim" else xterm256(c)

    # The heat ramp's shade glyphs are the one place a terminal does not just
    # draw a font: terminals rasterise block elements procedurally so they tile
    # the cell exactly. Drawing them as text instead leaves a gap on every line
    # and shreds the spectrogram, so they become rects that fill the cell, with
    # the shade dropped: in the ramp the glyph only duplicates what the colour
    # already says (it is the NO_COLOR fallback), and dimming a warm colour
    # toward the background is exactly the muddy brown the ramp is built to
    # avoid. Cells therefore merge by colour alone.
    SHADES = "\u2591\u2592\u2593\u2588"

    row_ids, row_defs = {}, []
    baseline = (lh - a.font_size) / 2 + a.font_size * 0.78

    def row_id(row):
        """One <g> per row: rects for the shade glyphs, one <text> for the rest.
        Blank cells are skipped entirely and the next run re-anchors with an
        explicit x, so nothing depends on how a renderer treats whitespace and
        font-metric drift cannot accumulate past one unbroken stretch of ink."""
        if row in row_ids:
            return row_ids[row]
        rects, spans, i, pen = [], [], 0, None
        while i < cols:
            c, ch = row[i]
            if ch == " ":
                i += 1
                continue
            if ch in SHADES:
                j = i
                while j < cols and row[j][0] == c and row[j][1] in SHADES:
                    j += 1
                rects.append('<rect x="%g" width="%g" class="%s"/>'
                             % (i * cw, (j - i) * cw, cls[c]))
                pen = None
            else:
                j = i
                while j < cols and row[j][0] == c \
                        and row[j][1] not in SHADES and row[j][1] != " ":
                    j += 1
                chunk = esc("".join(row[k][1] for k in range(i, j)))
                attrs = "" if pen == i else ' x="%g"' % (i * cw)
                attrs += "" if c is None else ' class="%s"' % cls[c]
                spans.append("<tspan%s>%s</tspan>" % (attrs, chunk)
                             if attrs else chunk)
                pen = j
            i = j
        if not rects and not spans:
            row_ids[row] = None
            return None
        body = "".join(rects)
        if spans:
            body += '<text y="%g">%s</text>' % (baseline, "".join(spans))
        rid = "r%d" % len(row_defs)
        row_defs.append('<g id="%s">%s</g>' % (rid, body))
        row_ids[row] = rid
        return rid

    frame_ids, frame_defs, slots = {}, [], []
    for f in fs:
        key = f
        if key not in frame_ids:
            uses = []
            for y, row in enumerate(f):
                rid = row_id(row)
                if rid:
                    uses.append('<use href="#%s" y="%g"/>' % (rid, y * lh))
            fid = "f%d" % len(frame_defs)
            frame_defs.append('<g id="%s">%s</g>' % (fid, "".join(uses)))
            frame_ids[key] = fid
        slots.append(frame_ids[key])

    # Positive delay: a slot's local time is `t - delay`, so slot i must be
    # held back by i*step to come up in its own turn. A negative delay would
    # run each slot *ahead* of the one before it and play the stack backwards.
    body = "".join(
        '<use href="#%s" class="_" style="animation-delay:%.2fs"/>'
        % (fid, i * step) for i, fid in enumerate(slots))

    css = [
        "svg{background:%s}" % a.bg,
        "text{font-family:ui-monospace,'SF Mono',SFMono-Regular,Menlo,Consolas,"
        "'DejaVu Sans Mono','Liberation Mono',monospace;"
        "font-size:%gpx;fill:%s}"
        % (a.font_size, a.fg),
        "g>rect{height:%gpx}" % lh,
    ]
    for c, name in cls.items():
        css.append(".%s{fill:%s}" % (name, hexof(c)))
    # "_" is reserved for the frame slots so it can never collide with a
    # generated colour class.
    css.append("._{visibility:hidden;animation:s %.3fs steps(1,end) infinite}"
               % total)
    css.append("@keyframes s{0%%{visibility:visible}%.4f%%{visibility:hidden}}"
               % (100.0 / len(slots)))

    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" role="img" '
        'viewBox="0 0 %g %g" width="%g" height="%g" font-variant-ligatures="none">'
        '<title>%s</title><style>%s</style>'
        '<defs>%s%s</defs>'
        '<rect width="%g" height="%g" rx="%g" fill="%s"/>'
        '<g transform="translate(%g,%g)">%s</g></svg>'
    ) % (width, height, width, height, esc(a.title), "".join(css),
         "".join(row_defs), "".join(frame_defs),
         width, height, a.radius, a.bg, pad, pad, body)

    open(a.out, "w", encoding="utf8").write(svg)
    print("%s  %d frames (%d unique), %d unique rows, %.1f KB"
          % (a.out, len(fs), len(frame_defs), len(row_defs), len(svg) / 1024))


main()
