# Give `ConversationStore` its own lock

> **Read `ideas/per-conversation-agents.md` and `DECISIONS.md` `D_no_event_queue` first.** The
> oldest note here said an event queue eats this idea — a lock is dead weight once one thread does
> all the mutating. That queue is now decided against, so this idea is on its own merits.
>
> **But check the premise before acting on it.** The middle version of this note argued the trigger
> had fired: a conversation owns its agent, so the folder has N writers. True, and weaker than it
> sounds — those writers touch *disjoint subdirectories*. `write_meta` only ever writes
> `conversation.dir/meta.json`, through a sibling temp file and a rename inside that same directory;
> the shared root is created once in the constructor and otherwise only enumerated; and one
> conversation admits one turn at a time, so a single directory never has two writers. That audit is
> in `D_serial_turn_executor`, and it is why `--turns > 1` shipped without this lock.
>
> What is left is the honest, smaller case: the store's consistency rests on a *discipline* nobody
> states, and its rdoc's "Thread-safe: stateless…" is a claim about the object that reads as a claim
> about the folder. Worth fixing for legibility. Not urgent for correctness.
>
> The `row` TOCTOU fix below survives every version of this — it is about a *second process*.

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
- **Multiple agents — this trigger has now fired.** `ideas/per-conversation-agents.md` settles that a
  conversation owns its own agent, which means N writers to the folder, and "one serialized writer in
  `AgentRunner`" stops being true in a way no reader of `ConversationStore` would ever guess. It is no
  longer a step past some later version: it is a precondition of the one that is coming.

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
  the accepted limitation in `DECISIONS.md` `D_no_multi_process_lock`, and it is accepted for good —
  so this idea can never be sold as fixing it.
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
- Cheap to do now and cheaper than retrofitting under N agents. Delete shipped without it
  (`D_delete_no_undo`), routing through the runner's mutex like every other mutating op — so the
  discipline is intact and undocumented, which is the whole complaint above.
