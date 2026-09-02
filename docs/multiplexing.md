# HTTP/2 multiplexing: what `-c` and `-s` mean

> **Status: settled design, not yet shipped.** `-s/--streams` does not exist
> yet; zrk today keeps exactly one request in flight per connection. This is
> the decision [#50](https://github.com/zoxy-io/zrk/issues/50) gates its
> implementation on, written down first so the semantics aren't settled by
> whichever patch lands first.

## The decision

**`-c` does not change meaning. `-s` is a depth knob only.**

- `-R` still splits evenly across `-c` connections, and each connection still
  owns one send schedule with one request index. `-c` is the number you compare
  across runs, exactly as it is today.
- `-s` bounds how many of *that connection's already-scheduled* sends may be on
  the wire at once. It never changes what is scheduled or when.
- `-s 1` is the current behaviour, byte for byte. It stays the default.

The consequence to state up front, because it is the thing users will assume
otherwise: **`-c 10 -s 10` is not `-c 100`.** Both put up to 100 requests in
flight, but the first offers ten connections each paced at `R/10`, and the
second offers a hundred each paced at `R/100`. Same aggregate rate, different
per-connection rate, different transport behaviour. They are not interchangeable
and zrk will not pretend they are.

## Why not h2load's `-c × -m`

h2load spells concurrency `-c` connections × `-m` streams, so `-c 10 -m 10` and
`-c 100` both mean "100 in flight". Adopting that would mean splitting `-R`
across the *product* and moving the send schedule to a (connection, stream)
pair — and it would buy comparability with a measurement that cannot see the
thing being compared.

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

## Per-stream aborts

With one request in flight, a timeout is aborted by shutting the socket down,
because "abort this request" and "abort this connection" are the same act. With
N streams open they stop being the same act: a timeout on one stream has to
become `RST_STREAM` on that stream, and **every other in-flight stream's latency
sample has to survive it**. That difference is the whole of the implementation
risk, and h2load offers no precedent to copy — it has no per-stream timeout at
all, only per-connection `-N`/`-T`, and `Client::timeout()` marks every
in-flight stream timed out and disconnects.

`--deadline-abort` inherits the same change, and improves: today it resets the
connection per miss, which is why the docs warn against it under saturation.
Per-stream it becomes a `RST_STREAM` per miss, with no reconnect storm.

## `SETTINGS_MAX_CONCURRENT_STREAMS`

The peer advertises a limit and zrk currently ignores it. A multiplexing client
must honour it: the effective depth is `min(-s, peer limit)`, and a run that
asked for more than the peer allows should say so rather than silently queue.
h2load does not do this — its accounting runs against the requested `-m` while
the surplus sits invisibly in nghttp2's queue — and that is a bug to avoid, not
a behaviour to match.

Flow control changes character too. `h2conn.open` raises the connection receive
window to its 31-bit maximum once and never revisits it, which is sound while
one reader consumes one response at a time. With N streams that single budget is
shared, and the reasoning that made it free no longer applies unexamined.
