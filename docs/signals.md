# Interrupting a run

`Ctrl-C` (SIGINT) and SIGTERM both stop the run and still report what was
measured, rather than discarding it — useful when a long run has already shown
you what you needed, and the reason `docker stop` on a containerized run no
longer throws the measurement away. A second signal aborts immediately, without
a report.

The report covers the elapsed time, not `--duration`: `duration_s` is the real
figure and `--format json` adds `"interrupted": true`. CI gates are *not*
evaluated on an interrupted run, so a partial sample can never report a passing
`--slo-p99`.

On the live dashboard the stop shows up on the panel itself: the blinking
recording dot beside the clock becomes a `✕` and a line under the counters says
the run is winding down (joining a large fleet takes a moment). Without a live
panel — `--plain`, a pipe, `--format json` — the notice goes to stderr instead.

Note for supervisors: the graceful stop has to tear down every connection, which
at high `-c` takes a moment, so allow some grace before SIGKILL (`docker stop`
defaults to 10s, which is ample).
