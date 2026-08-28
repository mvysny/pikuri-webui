# Give `ConversationStore` its own lock

> **Check `ideas/event-queue.md` first — that idea eats this one.** Locks *or* a single event-loop
> thread, not both: a lock here is dead weight once one thread does all the mutating. Do this only if
> the queue is far off. The `row` TOCTOU fix below is the exception — it is about a *second process*
> and is worth taking either way.

Today the conversations folder is kept consistent by a *discipline*, not by the store: every write
goes through `AgentRunner`'s `@mutex` (`persist`, which calls both `history.save(dir)` and
`write_meta`; `switch_conversation`; `switch_to`), and reads (`#list` / `#find`, from Sinatra request
threads) run unsynchronized against atomic-rename writes. The store's rdoc says "Thread-safe:
stateless past its constructor arguments", which is a claim about the *object* and reads as a claim
about the *folder*.

**Make the store responsible for its own consistency instead.** Two reasons, one present and one
coming:

- **`delete` is a mutating op whose natural home is a request thread.** Deleting a *non-live*
  conversation needs nothing from the agent, so the obvious implementation calls the store straight
  from the route — and the single-writer discipline is gone. v1 routes it through
  `AgentRunner#delete_conversation` anyway (it has to, for the live case), so the discipline holds by
  choice rather than by construction. That is the definition of accidental.
- **Multiple agents.** `ideas/background-turns.md` still says one live turn at a time and explicitly
  refuses a second concurrent one — so this is a step past v2, not v2. But the moment there are N
  agents there are N writers, and "one serialized writer in `AgentRunner`" stops being true in a way
  no reader of `ConversationStore` would ever guess.

## Shape: `Monitor`, stdlib, not a gem

The gem was the assumed cost, and **it is Tuile that uses `concurrent-ruby`, not pikuri.** Tuile
pulls it for `CountDownLatch` / `AtomicBoolean` / `TimerTask` in `tuile/lib/tuile/event_queue.rb` —
to build an *event queue*, not to hold a lock. pikuri has no `Concurrent::` reference anywhere in the
repo: its threading is stdlib `Mutex` throughout (`subprocess.rb`, `finalizers.rb`, `history.rb`'s
`MINT_LOCK`, `rate_limiter.rb`, `control/interloper.rb` — the class this project already wires up),
plus one `ConditionVariable` in `testing.rb`. **No RW lock in the family.** Nor is the gem in this
project's bundle: `pikuri-core`'s deps are faraday / nokogiri / rainbow / reverse_markdown /
ruby-readability / ruby_llm / zeitwerk, and `pikuri-pdf` adds pdf-reader.

So it would be a genuinely new direct dependency, in a Gemfile where every gem carries a paragraph
justifying itself (`tomlrb`'s even names the rejected alternative), and it would make
`ConversationStore` the only lock in the family that is not a stdlib mutex. Ruby stdlib has no
RWLock either — `sync` is gone (`LoadError` on 3.3).

So start with **`Monitor`**: stdlib, one `include`, and it is *re-entrant*, which matters here for a
concrete reason — `#find` calls `#list`. With a plain `Mutex` and both methods locking, `find`
deadlocks on itself. That is exactly the accidental threading bug the lock was supposed to kill,
introduced by the lock. Either `Monitor`, or a private unlocked `list_unlocked` that the public
methods wrap; `Monitor` is the smaller of the two.

If the gem ever does land here, note what Tuile's use suggests it would be *for*: latches and timers
to run an event queue — the other half of "thread-safe and simple". That is a different and larger
change than swapping a lock, and it would earn its own paragraph honestly.

An RWLock buys parallel readers, which pays only under read contention with long read critical
sections. `#list` is a directory scan of a few hundred `stat`s (~ms) for a single user with a handful
of tabs, so serializing reads costs nothing measurable. `#list`'s rdoc already carries the matching
rule — *measure a slow sidebar before trading the directory away*. **Upgrade path if that ever
measures badly:** swap `Monitor` for `Concurrent::ReentrantReadWriteLock` and pay the gem then, with
a number to justify the paragraph.

## What the lock does *not* buy — don't oversell it in the rdoc

- **Nothing across processes.** A second `pikuri-web-chat` is outside any in-process lock; that is
  the accepted limitation in `ideas/multi-process-locking.md`.
- **No cross-call atomicity.** `find` then `delete` is two locked ops with a gap, so delete still has
  to tolerate the conversation having vanished. A lock per method is not a transaction.
- **It does not replace the `row` TOCTOU fix.** `row` checks `(dir / META_FILE).file?` and *then*
  reads, so an unlink landing in between renders the row as "unsupported format" instead of dropping
  it. The fix — drop the check, `read` and rescue `Errno::ENOENT` as *not listed* (which is already
  its meaning: an interrupted save), keeping corrupt-JSON and unknown-schema as `supported: false` —
  is one syscall instead of two and is the **only** version that also survives the second process.
  Locking and that fix are complementary, not a) vs b).

## Consequences

- The rdoc sentence changes from "Thread-safe: stateless…" to naming what is actually guaranteed:
  the store serializes its own operations, the atomic rename is what a concurrent *reader outside
  this process* relies on, and cross-call sequences are not atomic.
- `AgentRunner`'s mutex stays. It serializes folder writes against *agent* state (`busy?`, the
  conversation switch, the turn-end save), which a store lock cannot see. Two locks with distinct
  jobs and a strict ordering (runner outermost, store innermost, never the reverse) — write that
  ordering down, because that is where the next deadlock comes from.
- Cheap to do now and cheaper than retrofitting under N agents. Not a blocker for
  `ideas/conversation-delete.md`, which routes through the runner regardless.
