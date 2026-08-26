"""Minimal VT emulator + asciicast v3 reader — enough for zrk's dashboard.

Handles exactly what the recording contains: SGR (reset / bright-black / 256-
color foreground), cursor-up, erase-below, CR, LF, and the DEC 2026 sync pair
(ignored). Anything else is dropped rather than guessed at.
"""
import json, re

CSI = re.compile(r'\x1b\[([0-9;?]*)([a-zA-Z])')
# A chunk may end mid-escape; PARTIAL recognises the truncated head so feed()
# can hold it back instead of printing the bytes as text.
PARTIAL = re.compile(r'\x1b(\[[0-9;?]*)?$')


class Screen:
    def __init__(self, cols, rows):
        self.cols, self.rows = cols, rows
        self.blank = (None, ' ')
        self.grid = [[self.blank] * cols for _ in range(rows)]
        self.x = self.y = 0
        self.fg = None
        self.pending = ''

    def _nl(self):
        self.y += 1
        if self.y >= self.rows:
            self.grid.pop(0)
            self.grid.append([self.blank] * self.cols)
            self.y = self.rows - 1

    def put(self, ch):
        if self.x >= self.cols:
            self.x = 0
            self._nl()
        self.grid[self.y][self.x] = (self.fg, ch)
        self.x += 1

    def erase_below(self):
        for x in range(self.x, self.cols):
            self.grid[self.y][x] = self.blank
        for y in range(self.y + 1, self.rows):
            self.grid[y] = [self.blank] * self.cols

    def sgr(self, params):
        ps = [int(p) for p in params.split(';')] if params else [0]
        i = 0
        while i < len(ps):
            p = ps[i]
            if p == 0:
                self.fg = None
            elif p == 90:
                self.fg = 'dim'
            elif p == 38 and i + 2 < len(ps) and ps[i + 1] == 5:
                self.fg = ps[i + 2]
                i += 2
            i += 1

    def feed(self, data):
        data = self.pending + data
        self.pending = ''
        i = 0
        while i < len(data):
            ch = data[i]
            if ch == '\x1b':
                m = CSI.match(data, i)
                if not m and PARTIAL.match(data, i):
                    self.pending = data[i:]
                    return
                if m:
                    params, final = m.group(1), m.group(2)
                    if final == 'm':
                        self.sgr(params)
                    elif final == 'A':
                        self.y = max(0, self.y - int(params or 1))
                    elif final == 'J' and params in ('', '0'):
                        self.erase_below()
                    i = m.end()
                    continue
                i += 1
            elif ch == '\r':
                self.x = 0
                i += 1
            elif ch == '\n':
                self._nl()
                i += 1
            else:
                self.put(ch)
                i += 1

    def snapshot(self):
        return tuple(tuple(row) for row in self.grid)


def read_cast(path):
    """Yield (absolute_time, output_chunk) plus the header."""
    lines = open(path, encoding='utf8').read().splitlines()
    header = json.loads(lines[0])
    t = 0.0
    evs = []
    for line in lines[1:]:
        if not line.strip():
            continue
        e = json.loads(line)
        t += e[0]
        if e[1] == 'o':
            evs.append((t, e[2]))
    return header, evs


def frames(path, fps):
    """Rasterise the cast onto a fixed grid, one snapshot per 1/fps tick."""
    header, evs = read_cast(path)
    cols, rows = header['term']['cols'], header['term']['rows']
    scr = Screen(cols, rows)
    end = evs[-1][0]
    out, i, step = [], 0, 1.0 / fps
    t = 0.0
    while t <= end + 1e-9:
        while i < len(evs) and evs[i][0] <= t:
            scr.feed(evs[i][1])
            i += 1
        out.append(scr.snapshot())
        t += step
    while i < len(evs):
        scr.feed(evs[i][1]); i += 1
    out.append(scr.snapshot())
    return cols, rows, step, out
