# Machine-readable output

## `--format json` — the final summary

For embedding in a benchmark harness or CI, `--format json` emits a single
summary object (the live dashboard is suppressed) to stdout or `--output <file>`:

```json
{
  "zrk_version": "0.1.0",
  "target": { "url": "http://127.0.0.1:8080/", "method": "GET" },
  "config": { "connections": 50, "launched": 50, "duration_s": 20.000, "closed": false, "target_rate": 1000, "timeout_ms": 2000, "deadline_ms": 0, "deadline_abort": false, "record_timeouts": true },
  "duration_s": 20.002,
  "requests": 19998,
  "bytes": 1239876,
  "achieved_rate": 999.80,
  "target_rate": 1000,
  "rate_ratio": 0.9998,
  "bytes_per_sec": 61987.30,
  "error_rate": 0.000000,
  "max_schedule_lag_us": 84,
  "latency_us": { "min": 106, "mean": 422.0, "stdev": 1222.9, "max": 13991,
                  "p50": 251, "p75": 337, "p90": 471, "p99": 1913, "p99_9": 13364, "p99_99": 13988 },
  "status_codes": { "1xx": 0, "2xx": 19998, "3xx": 0, "4xx": 0, "5xx": 0 },
  "errors": { "connect": 0, "read": 0, "write": 0, "timeout": 0, "deadline": 0, "non_2xx_3xx": 0 },
  "latency_histogram": "HISTFAAAAUJ4nC1P..."
}
```

`latency_histogram` is the **complete** latency distribution encoded as an
HdrHistogram **V2 compressed** base64 blob — the same interchange format the
Java/Go/JS/Rust HdrHistogram libraries read. It decodes losslessly, so a harness
can store the raw histogram and later re-percentile it, diff two runs, or merge
many runs into one aggregate — none of which the summarized percentiles allow.
`zrk` can round-trip it too (`hdr.decodeBase64`), e.g. to merge prior runs.

`achieved_rate` / `rate_ratio` tell you whether the client actually sustained
the target load. **If `rate_ratio` is well below 1.0, the client was saturated
(one request in flight per connection) and the latency numbers reflect client
backpressure, not the server: increase `-c`.**

Under `--closed` (`config.closed: true`), there's no offered rate to compare
against, so `target_rate` mirrors `achieved_rate` and `rate_ratio` is always
1.0 — a consumer that doesn't special-case `--closed` still gets coherent
numbers instead of the unrelated default `-R`.

Timed-out requests are recorded into the latency histogram by default (as a
coordinated-omission-corrected sample) so the tail isn't silently truncated;
`--no-record-timeouts` restores wrk2's drop-on-timeout behavior.

## `--hdr` — HdrHistogram percentile distribution

`--hdr <file>` writes the classic HdrHistogram percentile distribution (values
in milliseconds), directly loadable by the
[HdrHistogram plotter](https://hdrhistogram.github.io/HdrHistogram/plotFiles.html)
and format-compatible with wrk2's `--latency` output.

## `--timeseries` — per-interval NDJSON

`--timeseries <file>` streams one NDJSON object per `--interval`, each carrying
that window's offered `target_rate`, `achieved_rate`, request/error counts,
transfer (`bytes`, `bytes_per_sec`), the backlog gauge, and a delta-histogram
latency percentile set:

```
{"t":1.006,"target_rate":480.0,"achieved_rate":476.2,"requests":476,"errors":3,"error_rate":0.006263,"errors_by_kind":{"connect":0,"read":0,"write":0,"timeout":1,"deadline":2,"non_2xx_3xx":0},"bytes":58852,"bytes_per_sec":58501.0,"max_schedule_lag_us":18524,"latency_us":{"p50":245,"p90":669,"p99":1745,"p99_9":2401,"max":2401}}
```

This is the artifact a **ramp** (`-R A:B`) exists to produce: a curve of latency
against offered load, so you can find the rate at which the server's tail breaks
down. (The final summary's aggregate percentiles blend the whole ramp together,
so they're less useful for a ramp than the time series is.)

Every count in a row is that **interval's** delta, so the rows sum to the run.
`errors_by_kind` splits the `errors` scalar the same way the final summary's
`errors` object does — worth plotting stacked, because a tail that broke into
`deadline` misses and one that broke into `connect` failures are different
findings that the single number cannot tell apart.

`error_rate` is that window's failure fraction, computed exactly like the
summary's top-level `error_rate` (and so directly comparable to it and to the
`--max-error-rate` gate). Plot this rather than the raw `errors` count: it sits
on a fixed 0..1 axis regardless of what `--interval` is set to, whereas the
count silently rescales with the window. Over a single interval the two
definitions coincide, so a one-window run's row reports the summary's number.

`max_schedule_lag_us` is the one exception: it is the **cumulative** peak
`now − scheduled` the fleet has reached *as of* that row, the same running gauge
the summary reports, not the interval's own peak. It is aggregated by max rather
than summed, so there is nothing to difference — an interval-local peak would
mean resetting the gauge on the row cadence and costing the final report its
true high-water mark. Read the series as a staircase: each riser marks the
window in which the client fell further behind its schedule than it ever had
before, which is what dates the onset of a backlog against the latency it
explains.

Add `--timeseries-histogram` to append each interval's **full** latency
distribution as an HdrHistogram V2 base64 blob (`latency_histogram`) to every
row. Each blob decodes losslessly, so a harness can re-percentile a single
interval or merge any subset of them — e.g. just the windows above a target
rate. Merging every row reproduces the run's summary histogram exactly, since
the intervals partition the run. (Rows get noticeably larger, so it is opt-in.)

## Streaming to a live plotter

`--timeseries -` sends the rows to **stdout** instead of a file, so they can be
piped straight into a streaming plotter such as
[jplot](https://github.com/rs/jplot), which reads newline-delimited JSON and
addresses fields by dotted path:

```sh
zrk -c50 -R1000 -d5m --timeseries - http://127.0.0.1:8080/ \
  | jplot achieved_rate+target_rate \
          latency_us.p50+latency_us.p90+latency_us.p99 \
          error_rate
```

Each space-separated spec is its own graph, so keep `error_rate` off the
throughput one — it is a 0..1 fraction, not a req/s figure. Do **not** prefix
zrk's fields with jplot's `counter:`: that option exists to difference
monotonic counters, and these rows are already per-interval deltas. There is no
`jaggr` stage either: aggregating raw samples into per-interval percentiles is
what zrk already does in-process, with real HdrHistograms.

Because stdout then belongs to the row stream, `--timeseries -` suppresses the
live dashboard and sends the final report to `--output` if given, else to
**stderr** — so the summary still lands in your terminal without corrupting the
pipe.

Pair it with `-o` when the report is machine-read: `--format json --timeseries -`
puts the JSON summary on stderr *alongside* the human notices (an SLO breach, a
sink warning), so a parser reading stderr whole can trip over the trailing line.
`--format json -o result.json --timeseries -` keeps all three streams apart —
rows on stdout, report in the file, notices on stderr.
