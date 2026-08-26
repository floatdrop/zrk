<p align="center">
    <img alt="zrk console demo" src="./zrk.gif" width="600" />
</p>

# zrk

[![CI](https://github.com/zoxy-io/zrk/actions/workflows/ci.yml/badge.svg)](https://github.com/zoxy-io/zrk/actions/workflows/ci.yml)

A constant-throughput HTTP load generator — a Zig 0.16 rewrite of
[wrk2](https://github.com/giltene/wrk2) with a live in-terminal dashboard.

- **Corrected for coordinated omission.** Latency is measured from the time a
  request *should* have been sent, so a server stall lands in the tail instead
  of being smoothed away.
- **Nanosecond pacing.** The send schedule is a closed-form nanosecond offset,
  not wrk2's millisecond timer wheel — which rounds every wait up and adds
  ~0.5 ms of the tool's own noise to every sample.
  ([why this matters](docs/coordinated-omission.md#why-zrk-is-more-accurate-than-wrk2))
- **Three load models.** Fixed rate (`-R 2000`), linear ramp (`-R 100:5000`),
  or closed loop (`--closed`) to discover a ceiling instead of guessing one.
- **Live dashboard.** Latency percentile spectrum and a p99 sparkline while the
  run is going; falls back to append-only lines when stdout is not a TTY.
- **Machine-readable output.** JSON summary, HdrHistogram (`.hgrm` and V2
  base64), and per-interval NDJSON for streaming plotters.
- **CI gates.** `--slo-p99` and `--max-error-rate` fail the build with exit 3.

## Installation

### Homebrew

```sh
brew install zoxy-io/tap/zrk
```

### Pre-built binary

Download the latest release binary from the [Releases page](https://github.com/zoxy-io/zrk/releases).
Linux and macOS, x86_64 and aarch64. Windows binaries were dropped after v1.4.3
([#21](https://github.com/zoxy-io/zrk/issues/21)): zrk's TLS is moving to
[ztls](https://github.com/zoxy-io/ztls), which is Linux/macOS by design.

### Build from source

Requires Zig 0.16.

```sh
zig build                 # produces zig-out/bin/zrk
zig build -Doptimize=ReleaseFast
zig build test            # run the unit + integration tests
```

## Usage

```
zrk — constant-throughput HTTP load generator

Usage: zrk [options] <url>

Options:
  -t, --threads     <N>     Total number of threads to execute load (default 2)
  -c, --connections <N>     Total connections to keep open (default 10)
  -d, --duration    <T>     Test duration, e.g. 30s, 2m    (default 10s)
  -R, --rate      <N|A:B>   Target requests/second (total); A:B ramps
                            linearly from A to B over the run (default 1000)
      --closed              Closed-loop mode: ignore -R, send each
                            connection's next request the instant its
                            previous response completes (like wrk/ab).
                            No coordinated-omission correction; the rate
                            finds its own ceiling instead of chasing one.
                            Incompatible with a ramp (-R A:B) or --deadline
  -H, --header  <K: V>      Add a request header (repeatable)
  -m, --method      <M>     HTTP method                    (default GET)
  -b, --body     <S|@FILE>  Request body; @FILE reads it from a file
                            (@- = stdin, @@x = a literal "@x")
      --timeout     <T>     Wire timeout per attempt, from the actual
                            send (default 2s); does not bound CO latency
      --deadline    <T>     Max coordinated-omission latency, from the
                            scheduled send: a too-stale request is shed
                            (failed as a `deadline` error, not sent or
                            recorded) before sending (0 = off)
      --deadline-abort      Also abort in-flight requests past the
                            deadline. Resets the connection per miss and
                            churns under saturation; off by default
      --interval    <T>     Stats window: --timeseries rows and --plain
                            lines                          (default 1s)
      --refresh     <T>     Live dashboard redraw rate     (default 80ms)
      --latency             Print full latency spectrum in the final report
      --http2               Speak HTTP/2. Cleartext uses prior knowledge
                            (h2c); https negotiates it over ALPN and
                            fails the connection if the server declines
  -k, --insecure            Skip TLS certificate verification
      --plain               Append-only output instead of a live dashboard

Reporting:
      --format  <text|json> Final report format            (default text)
  -o, --output      <FILE>  Write the final report to FILE (default stdout)
      --hdr         <FILE>  Also write the HdrHistogram percentile
                            distribution (.hgrm) to FILE
      --timeseries  <FILE>  Stream per-interval NDJSON (throughput +
                            latency percentiles) to FILE. "-" streams to
                            stdout for piping into a live plotter; the
                            dashboard is then suppressed and the final
                            report goes to stderr unless -o is given
      --timeseries-histogram  Add each interval's full latency histogram
                            (HdrHistogram base64) to every --timeseries row
      --no-record-timeouts  Drop wire-timed-out requests from the latency
                            histogram (default: record them). Independent
                            of --deadline misses, which are never recorded.

CI gates (exit code 3 on breach):
      --slo-p99     <T>     Fail if final p99 latency exceeds T
      --max-error-rate <F>  Fail if error rate exceeds F (0..1)

  -h, --help                Show this help
      --version             Show version
```

Durations accept `us`, `ms`, `s`, `m`, `h` (a bare number is seconds).
Short options may be attached (`-c100`) or separated (`-c 100`).

### Examples

```sh
# 2000 req/s for 30s over 100 connections
zrk -c100 -d30s -R2000 http://127.0.0.1:8080/

# Ramp linearly from 100 to 5000 req/s over 60s, capturing the latency-vs-load
# curve as a per-interval NDJSON time series (find the knee where latency breaks)
zrk -c200 -d60s -R100:5000 --timeseries ramp.ndjson http://127.0.0.1:8080/

# Closed-loop: what's the real max throughput at 100 connections? No -R to
# guess — achieved_rate finds its own ceiling instead of chasing one.
zrk -c100 -d20s --closed http://127.0.0.1:8080/

# HTTPS with the full latency spectrum in the final report
zrk -c20 -d1m -R500 --latency https://api.example.com/health

# POST with a body and custom headers (-b @payload.json reads a file, @- stdin)
zrk -c10 -R100 -m POST -b '{"ping":1}' \
    -H 'Content-Type: application/json' http://127.0.0.1:8080/echo

# CI-friendly, no redrawing dashboard
zrk -c50 -R1000 -d20s --plain http://127.0.0.1:8080/ | tee run.log

# Machine-readable: JSON summary to a file + HdrHistogram .hgrm for plotting
zrk -c50 -R1000 -d20s --format json -o result.json --hdr latency.hgrm \
    http://127.0.0.1:8080/

# CI gate: fail the build (exit 3) if p99 regresses past 250ms or errors climb
zrk -c50 -R1000 -d20s --format json -o result.json \
    --slo-p99 250ms --max-error-rate 1% http://127.0.0.1:8080/

# Live terminal plot: stream the per-interval rows into jplot
zrk -c50 -R1000 -d5m --timeseries - http://127.0.0.1:8080/ \
  | jplot achieved_rate+target_rate latency_us.p50+latency_us.p90+latency_us.p99 error_rate
```

### Exit codes

| code | meaning |
|------|---------|
| 0 | run completed; any configured gates passed |
| 1 | the run failed to start or complete (see the message on stderr) |
| 2 | bad arguments, or a `--body` file that could not be read |
| 3 | run completed but a `--slo-p99` / `--max-error-rate` gate was breached |
| 130 | interrupted by SIGINT (`Ctrl-C`); a partial report was still written |
| 143 | interrupted by SIGTERM; a partial report was still written |

## Documentation

| | |
|---|---|
| [Coordinated omission](docs/coordinated-omission.md) | Why the correction exists, when `--closed` is the right tool, and how zrk's clock differs from wrk2's. |
| [`--timeout` vs `--deadline`](docs/deadlines.md) | Bounding the latency tail under overload, and the backlog gauge. |
| [Machine-readable output](docs/output.md) | The JSON summary, `--hdr`, `--timeseries` NDJSON, and piping rows into a live plotter. |
| [Interrupting a run](docs/signals.md) | What SIGINT/SIGTERM report, and what supervisors should know. |
| [Library usage](docs/library.md) | Driving `runner.run` from Zig instead of the CLI. |
| [How it works](docs/internals.md) | Concurrency model, histogram/memory budget, source layout. |

## License

[MIT](LICENSE)
