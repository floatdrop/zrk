# Coordinated omission, closed loop, and clock accuracy

## Why coordinated-omission correction?

An open-loop load tester that simply sends "as fast as the server answers"
accidentally *coordinates* with the server: when the server stalls, the tester
stops sending, so the stall never shows up in the latency numbers. zrk instead
paces each connection to a fixed schedule and measures every request's latency
from the time it *should* have been sent. If the server stalls, backlogged
requests accrue latency against their intended send time — the stall is
captured, not smoothed away.

## Finding a ceiling instead of chasing one

Coordinated-omission correction has a precondition: you already know a rate
worth measuring against. That's fine for regression testing ("does this
service still hold 2000 req/s within its SLO?"), but it doesn't answer a
different, common question — "what's the most this service, with this many
connections, can actually sustain?" `-R` can't answer that on its own: pick a
rate at or under the true ceiling and you've only confirmed the service beats
your guess; pick one above it and the backlog *from that guess* grows for as
long as the run keeps pacing sends against a rate the server never agreed to,
swamping the latency histogram in queueing delay that has nothing to do with
the server's own response time.

`--closed` drops the schedule and sends each connection's next request the
instant its previous response completes — the classic wrk/ab model. There's
no independent send schedule left to correct against, so coordinated-omission
correction doesn't apply (and zrk says so: the final report reads "latency
(closed-loop round-trip)", not "corrected"), but the throughput that comes out
is real: it's however fast `-c` connections and the server, between them,
actually managed, not a target either side had to hit. That makes it the tool
for capacity discovery — find the ceiling once with `--closed`, then go back
to `-R` (below it, for a regression gate) or `-R start:end` (through it, to
see where latency breaks) now that there's a real number to aim at.

## Why zrk is more accurate than wrk2

Coordinated-omission correction is only as precise as the clock underneath
it, and wrk2's clock has a floor.

wrk2's event loop (`ae.c`, forked from Redis) drives an epoll wait and a timer
wheel that both resolve to whole milliseconds. Its per-request pacing computes
the exact microsecond wait until the next scheduled send
(`usec_to_next_send` in `wrk.c`), but then converts that into a timer delay
with:

```c
int msec_to_wait = round((time_usec_to_wait / 1000.0L) + 0.5);
```

That always rounds *up* to the next whole millisecond — a wait of 1 µs and a
wait of 999 µs both become a 1 ms wait. Because wrk2 correctly measures
latency from the *scheduled* send time (that's the coordinated-omission fix),
this scheduling overshoot isn't discarded — it lands directly in the recorded
latency of every sample that wasn't already overdue. The overshoot is uniform
on (0 ms, 1 ms], averaging ~0.5 ms: noise from the tool itself, not the
server, and indistinguishable from it in the report. At the sub-millisecond
latencies a fast service actually produces, that's not a rounding error —
it's frequently larger than the number being measured.

zrk's schedule (`src/pace.zig`) is a closed-form nanosecond offset per
connection send index, computed directly from the target rate (or ramp),
and each connection sleeps to it via [zio](https://github.com/lalinsky/zio)'s
io_uring runtime (`io.sleep(Io.Duration.fromNanoseconds(...))`). There is no
tick to round to.
