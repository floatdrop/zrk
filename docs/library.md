# Library usage

zrk's core is a reusable Zig module, not just a CLI: `runner.run` drives the
same load-test loop the CLI does (see `src/runner.zig`) and returns a typed
`Report`, with an optional progress callback for the periodic snapshots the
dashboard renders. The lower-level pieces it's built from (`hdr`, `cli`,
`http`, `connection`, `stats`, `report`, `tls`) are exported too.

Add it as a dependency:

```sh
zig fetch --save git+https://github.com/zoxy-io/zrk#<commit-or-tag>
```

```zig
// build.zig
const zrk_dep = b.dependency("zrk", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zrk", zrk_dep.module("zrk"));
```

```zig
const std = @import("std");
const zio = @import("zio");
const zrk = @import("zrk");

var rt = try zio.Runtime.init(allocator, .{});
defer rt.deinit();
const io = rt.io();

var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();

var cfg: zrk.cli.Config = .{
    .connections = 50,
    .rate = 1000,
    .duration_ns = 10 * std.time.ns_per_s,
    .interval_ns = 1 * std.time.ns_per_s,
    .url = try zrk.cli.parseUrl("http://127.0.0.1:8080/"),
};
const report = try zrk.runner.run(arena.allocator(), io, &cfg, 0, null, null, null);
```

`Report` carries the merged `snapshot` (counters plus the
coordinated-omission-corrected histogram), `elapsed_s`, `launched`, and
`interrupted`. It also carries `end_rate` / `end_bytes_per_sec` /
`end_window_s` / `end_window_at_s`: throughput over the run's *last*
`--interval` and where that window sat, rather than
`completed / elapsed_s`. Under a ramp those differ by design — the whole-run
average is the midpoint of the offered range and reports ~550 for `-R100:1000`
no matter what the target did at the top of it, while `end_rate` is the rate it
was actually serving when the run ended. A run shorter than one interval has no
window of its own and falls back to the average.

`report.writeJson` takes those as a `report.Run` alongside the snapshot, and
reports `end_rate` as the summary's `achieved_rate` whenever `cfg.rate_end` is
set (see [output.md](output.md)); an embedder computing its own headline number
should make the same choice. Leaving `end_window_s` at 0 says "no window
measured", and the whole run stands in for it.

## Which `std.Io` to pass

`runner.run` takes a `std.Io` instance as a plain parameter, so any conforming
`std.Io` implementation can be passed in. In practice, zrk dials each
connection with a connect timeout (`address.connect(io, .{ .timeout = ... })`),
and Zig 0.16's default `std.Io.Threaded` backend hasn't implemented
connect-with-timeout yet (it's a TODO panic there). [zio](https://github.com/lalinsky/zio)
does implement it, which is why zio is a hard dependency of the `zrk` package
itself (see `build.zig.zon`) and the runtime zrk's own CLI constructs at
startup (`src/main.zig`). Embedders should do the same — construct a
`zio.Runtime` and pass its `.io()` to `runner.run` — unless you bring another
`std.Io` implementation that you've verified covers what zrk needs.
