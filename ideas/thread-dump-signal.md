# A signal that dumps every thread's backtrace

Ruby has no `jstack`. When this server wedges, there is nothing to take a look *at* — you kill it
and guess. Java gets `kill -3` for free; we would have to install the equivalent, and it is about
ten lines.

Came out of the `D_no_event_queue` reopening (see its **Reopened** section). The argument there:
a race consumes its evidence, but a *stall* is a stable state that holds its own — one dump names
the thread and the line. That advantage is only real if something can produce the dump.

## Why it is worth having before any owner thread exists

The wedge hazards are already here, and they are the ones `D_shutdown_on_state_stop` exists to
prevent:

- A `/events` drain loop parked forever on a queue nobody pushes to — one Puma thread per stranded
  tab, and Puma's graceful stop waits on all of them.
- A turn stuck inside `run_loop` against an inference server that stopped answering, holding an
  executor slot the whole time (`--turns` defaults to 1, so that is *the* slot).
- `ConversationStore#save` blocked on a full or slow disk, inside `finish_turn`, holding the
  runner's mutex — which is the same mutex `#submit` takes, so the request thread parks too.

None of those is hypothetical and none of them is diagnosable today.

## Shape

- `TTIN`, following Sidekiq. Puma does not claim it — **verify against Puma 8's trap set before
  wiring it**, because being wrong here means stealing a signal the server needs.
- Ruby trap context cannot take a mutex, so the handler must not print directly. Push a token to a
  `Thread::Queue`; a dedicated printer thread drains it and writes `Thread.list` backtraces to
  stderr.
- stderr, not the browser — `D_diagnostics_to_stderr`.
- Boot script, next to the Puma wiring. Not a flag; it costs nothing when unused.

## Open

- Does the printer thread itself need to survive `:state, :stop`? It is one more thread Puma's
  graceful stop might wait on, which would be a nice irony.
- Worth dumping on the way out of a shutdown that took too long, or only on demand?
