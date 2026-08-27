# How zrk works

- **One request in flight per connection** (like wrk/wrk2). Throughput comes
  from running many connections; the total `-R` rate is split evenly across
  them, and each connection paces its own sends to that schedule.
- **HdrHistogram** records every request's corrected latency (1µs–60s, 3
  significant figures). Each connection owns its own histogram (lock-free hot
  path) and publishes a snapshot once per `--interval` for the dashboard; the
  final report aggregates all histograms after the run. Latencies above 60s are
  clamped into the top bucket rather than dropped, so the request is still
  counted but the reported tail saturates there. Two histograms per connection
  at ~136KiB each is the bulk of zrk's memory: budget ~280KiB per `-c`.
- Connections run as coroutines on a [zio](https://github.com/lalinsky/zio)
  io_uring runtime (`std.Io`-compatible), one connection per coroutine.

## Source layout

| File | Responsibility |
|------|----------------|
| `src/hdr.zig` | Minimal HdrHistogram (record, percentiles, merge). |
| `src/cli.zig` | Argument / URL / duration parsing → `Config`. |
| `src/http.zig` | Request builder (HTTP/1.1 bytes and the HPACK block); response framing is [zurl](https://github.com/zoxy-io/zurl)'s. |
| `src/runner.zig` | The reusable run loop the CLI and library embedders both call. |
| `src/connection.zig` | The per-connection pacing loop (the coordinated-omission core). |
| `src/pace.zig` | Closed-form nanosecond send schedule per connection and send index. |
| `src/tls.zig` | TLS over a stream: the `std.Io` adapter over [zssl](https://github.com/zoxy-io/zssl)'s sans-I/O engine, plus the X.509 chain and hostname verification zssl leaves to its embedder (system CA bundle, `-k`). |
| `src/stats.zig` | Per-connection state ownership + snapshot/final aggregation. |
| `src/report.zig` | Machine-readable JSON summary + SLO/CI exit-code gates. |
| `src/tui.zig` | Live dashboard and final report. |
| `src/main.zig` | Orchestration: resolve, launch connections, drive the dashboard. |
