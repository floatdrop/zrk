# HTTP/2 multiplexing: what `-c` and `-s` mean

`-s/--streams` sets how many HTTP/2 streams one connection keeps in flight.
The semantics below were settled before the implementation, per
[#50](https://github.com/zoxy-io/zrk/issues/50), so that they were not decided
by whichever patch happened to land first.

## The decision

**`-c` does not change meaning. `-s` is a depth knob only.**

- `-R` still splits evenly across `-c` connections, and each connection still
  owns one send schedule with one request index. `-c` is the number you compare
  across runs, exactly as it was before `-s` existed.
- `-s` bounds how many of *that connection's already-scheduled* sends may be on
  the wire at once. It never changes what is scheduled or when.
- `-s 1` is the pre-multiplexing behaviour, down to which code path runs. It is
  the default.

The consequence to state up front, because it is the thing users will assume
otherwise: **`-c 10 -s 10` is not `-c 100`.** Both put up to 100 requests in
flight, but the first offers ten connections each paced at `R/10`, and the
second offers a hundred each paced at `R/100`. Same aggregate rate, different
per-connection rate, different transport behaviour. They are not interchangeable
and zrk does not pretend they are. The numbers below say how far apart.

## Why not h2load's `-c × -m`

h2load spells concurrency `-c` connections × `-m` streams, so `-c 10 -m 10` and
`-c 100` both mean "100 in flight". Adopting that would mean splitting `-R`
across the *product* and moving the send schedule to a (connection, stream)
pair — and it would buy comparability with a measurement that cannot see the
thing being compared — and, as the numbers below show, comparability that does
not exist in the first place.

In h2load the per-request clock starts in nghttp2's `before_frame_send`
callback, which fires when HEADERS is serialised **onto the wire**. Its
`submit_request` only queues into nghttp2's `ob_syn`, which is gated by the
peer's concurrent-stream limit and by connection flow control. Every nanosecond
a stream spends waiting for a slot is therefore *absent from the sample*. That
is the same blind spot as coordinated omission, one layer lower: the delay
multiplexing causes is exactly the delay h2load's clock skips.

Two related h2load behaviours are worth knowing if you compare tools:

- `-m` is a **closed-loop depth**, not a rate. The default mode opens `min(remaining, m)`
  streams on connect and refills exactly one per completion, so the send rate is
  whatever the server hands back. `-r/--rate` paces *connection* creation, not
  requests. Only `--rps` is an open loop, and `-m` truncates each of its ticks
  (the unsent remainder is drained later, from stream close — coordinated
  omission in its plainest form).
- With `--timing-script-file`, hitting the `-m` ceiling **stops the script timer**
  and restarts it from stream close, silently converting a scripted open loop
  into a closed one.

## What `-s` buys under zrk's schedule

It is tempting to read multiplexing as noise injection, and there is a real cost
(below), but under zrk's model the first-order effect runs the other way.

Coordinated-omission correction exists because a serial connection **cannot send
on time** when the server is slow: the next request waits behind the previous
response, and zrk charges that wait back by measuring from the *scheduled* send.
A second stream lets the connection actually send on time. So `-s` does not hide
backlog — it removes a client-side cause of it. A run where `-s 4` flattens the
tail that `-s 1` showed is a run where the tail was partly zrk's own
serialisation, and `--deadline`'s shedding and the `max_schedule_lag_us` gauge
were reporting a client-side queue as target latency. See
[`docs/deadlines.md`](deadlines.md) for those two.

That is also the honest limit of the feature: `-s` is worth raising when a
connection cannot keep up with its own schedule. If responses already return
faster than `R/c`, a second stream never opens and `-s` changes nothing.

## What it costs

N streams on one socket share one TCP congestion window and one kernel receive
queue. HTTP/2 multiplexes above that layer and cannot unblock it, so a single
slow or large response can delay the others in a way no amount of stream
priority fixes. This is a transport effect, not a scheduling one — which is why
it argues for keeping `-c` as the comparable number rather than for refusing
multiplexing.

Use `-s` to model a client that genuinely multiplexes, or to let a connection
hold its schedule. Use `-c` to add independent transport. When in doubt about a
number you are going to compare across runs, change `-c`.

## What the numbers actually say

Against `nghttpd` on loopback, closed loop, five seconds each — the two layouts
that both hold 100 requests in flight:

| layout | in flight | req/s | p50 | p99 |
| --- | ---: | ---: | ---: | ---: |
| `-c 10 -s 1` | 10 | 250,990 | 38 µs | 67 µs |
| `-c 10 -s 10` | 100 | 524,942 | 165 µs | 235 µs |
| `-c 100 -s 1` | 100 | 186,608 | 522 µs | 1.04 ms |
| `-c 100 -s 10` | 1000 | 433,818 | 2.21 ms | 3.77 ms |

`-c 10 -s 10` and `-c 100 -s 1` are the same "100 concurrent requests" and
nothing else: **2.8× apart on throughput and 3.2× apart on p50**. h2load, asked
the same two questions on the same server, splits the same way (857k req/s at
`-c 10 -m 10` against 285k at `-c 100 -m 1`) — so this is a property of the load
layout, not of either tool.

Which way the gap points is worth noticing: on loopback, multiplexing *wins*,
because a hundred sockets cost a hundred sockets' worth of syscalls and
scheduling and ten do not. That is the argument for `-s` existing. It is also
the argument for never quoting a `-s` number against a `-c` number: the two
differ by whatever the client's own transport costs on that machine, which is
exactly the quantity a load generator is supposed to keep out of its results.

Change `-c` when you want a number to compare. Change `-s` when you want to
model a client that multiplexes.

## Nagle

zrk sets `TCP_NODELAY` on every connection it opens. This became necessary with
`-s`, and the reason is worth recording because it cost real time to find.

Nagle's algorithm holds a small write until the previous one has been
acknowledged; Linux delays that acknowledgement by up to 40 ms. Serially the two
can barely meet — nothing of ours is unacknowledged when the next request is
written, because the response that acknowledged it is what released the send.
Multiplexing makes them meet by design: writing a second request while the first
is outstanding is the whole point, and Nagle answers it by parking that request
until a delayed-ACK timer fires. Left on, it puts 40 ms of the client's own
transport into the target's latency.

It showed up first as an end-of-run artifact — the last response of a run
arriving exactly 40 ms late, every time — which is the same bug wearing the one
disguise that makes it look like a scheduling problem instead of a TCP one.

## Per-stream aborts

With one request in flight, a timeout is aborted by shutting the socket down,
because "abort this request" and "abort this connection" are the same act. With
N streams open they stop being the same act, so a timeout on one stream becomes
`RST_STREAM` on that stream and **every other in-flight stream's latency sample
survives it**. That is the whole difference from the serial path and the place
bugs would live, so it has a test of its own: one stream held open forever
against a server that answers every other, asserting one timeout, one
`RST_STREAM` seen by the server, zero connection errors, and the rest of the
samples still arriving after it.

h2load offered no precedent to copy here — it has no per-stream timeout at all,
only per-connection `-N`/`-T`, and `Client::timeout()` marks every in-flight
stream timed out and disconnects.

`--deadline-abort` inherits the same change, and improves on it: serially it
resets the connection per miss, which is why [deadlines.md](deadlines.md) warns
against it under saturation. Per stream it is a `RST_STREAM` per miss, with no
reconnect storm.

## `SETTINGS_MAX_CONCURRENT_STREAMS`

The peer advertises a limit and zrk honours it: the effective depth is
`min(-s, peer limit)`, read from the SETTINGS that arrive during the handshake,
so it is known before the first send rather than discovered by overshooting.
h2load does not — its accounting runs against the requested `-m` while the
surplus sits invisibly in nghttp2's queue, which means a client that believes it
has N in flight against a peer allowing ten is timing its own queue and
attributing it to the server.

Flow control changed character too. `h2conn.open` raised the connection receive
window to its 31-bit maximum once and never revisited it, which reads as "flow
control off" and is not: that window is a budget for the connection's whole
life, and every DATA octet spends it. One response at a time spends it slowly
enough that short runs finish first; N streams share the same budget. zrk now
credits the peer back at half, which is one WINDOW_UPDATE per gibibyte and makes
the budget genuinely unbounded.
