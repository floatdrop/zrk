# `--timeout` vs `--deadline` (bounding the tail under overload)

These knobs sound similar but measure from **different clocks**, and the
difference only shows up under overload:

- **`--timeout`** is a **wire** timeout, measured from the *actual* send. It
  bounds one attempt on the wire (`done − actual_send`) and catches a hung
  socket or a dead server. It does **not** bound coordinated-omission latency:
  when a connection falls behind its schedule, each attempt still goes out and
  comes back quickly, so the timeout never trips even though the *recorded* CO
  latency (measured from the request's **scheduled** time) balloons into the
  tens of seconds. A tight `--timeout 1s` will happily sit next to a 30 s `p50`.
- **`--deadline`** is what actually bounds that tail. It is measured from each
  request's **scheduled** send time and targets `done − scheduled`. It is
  enforced by **shedding before sending**: a request already staler than the
  deadline is **failed as a `deadline` error** without ever touching the wire,
  which drains the backlog and keeps the client probing near-live latency. This
  is the usual benchmark intent ("past X ms it's a failed request, per our SLA").

With `--deadline` set, the latency histogram becomes the distribution of
requests that were **sent within the deadline** of their schedule, and sustained
overload shows up as a rising `deadline` error count instead of an unbounded
latency tail. That makes both CI gates meaningful at once under overload:
`--slo-p99` stays a p99 of *met* latency, while `--max-error-rate` catches the
deadline-miss rate. Deadline misses are **never** recorded into the histogram
(unlike wire timeouts), so `--no-record-timeouts` does not affect them.

## `--deadline-abort`

Shedding bounds the send time, not the completion, so a request that *is* sent
still runs to completion on the wire: its recorded CO latency is bounded by
**deadline + wire time** (and wire time by `--timeout`), not by the deadline
exactly. zrk deliberately does **not** cut an in-flight request off by default,
because on HTTP/1.1 keep-alive that means resetting the connection — and under
saturation, where most in-flight requests exceed the deadline, resetting every
one storms the target with reconnects and can balloon its memory (an OOM risk
for the system under test). `--deadline-abort` opts into that in-flight cut-off
(recorded latency then capped at the deadline exactly), at the cost of a
connection reset per miss; use it only against a target you know tolerates the
churn.

## The backlog gauge

`max_schedule_lag_us` (JSON) / "Peak schedule lag" (text report) is the backlog
gauge: the peak `now − scheduled` the fleet ever reached. It is populated even
without `--deadline`, so it is an early warning that the client is falling
behind the offered schedule — a companion to `rate_ratio` / `achieved_rate`.
