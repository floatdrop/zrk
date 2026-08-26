# README demo

`zrk.svg` at the repo root is a real recorded run, not a mockup. Regenerate it
with:

```sh
docs/demo/record.sh
```

The pieces:

- `server.js` — the target. A finite worker pool (20 slots, ~8 ms of service
  time each) so it saturates around 2.5k req/s. The recorded run ramps past
  that on purpose: the point of the demo is the tail opening up once the
  offered rate crosses capacity, which is exactly what coordinated-omission
  correction is for.
- `session.sh` — what gets recorded: types the command, runs it, holds on the
  final panel. The URL on screen is a stand-in; the run hits `127.0.0.1:8080`.
- `cast2svg.py` / `term.py` — asciicast → animated SVG. Frames stack as
  `<use>` elements sharing one `@keyframes`, each held into its slot by an
  `animation-delay` of `i * step`, and identical rows are emitted once into
  `<defs>`; that is what keeps a 100-column heatmap under 250 KB. The heat
  ramp's block glyphs are drawn as rects that fill their cells — terminals
  rasterise block elements procedurally so they tile, and text glyphs would
  leave a gap on every line.

Requires `asciinema`, `node`, `python3` and a Zig toolchain.
