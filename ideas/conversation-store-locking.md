# Give `ConversationStore` its own lock

> **Status of the premise, re-audited 2026-08-28 against HEAD. Every mechanical argument this
> note was built on has since been settled or falsified. What is left is a *documentation*
> complaint, and the recommendation at the bottom is now "don't add the lock".**
>
> Read `DECISIONS.md` `D_serial_turn_executor` (the folder audit), `D_conversation_owns_agent`,
> `D_no_event_queue` and `D_no_multi_process_lock` first — between them they already answer most
> of what follows.

## What changed since this note was written

- **The event queue is decided against** (`D_no_event_queue`), so the oldest version's "a queue
  eats this idea" no longer applies. The idea does stand on its own merits. It just turns out
  not to have many.
- **`ideas/per-conversation-agents.md` is gone**, graduated into `D_conversation_owns_agent`.
  Every reference to it below was rewritten to cite the decision.
- **The "multiple agents means N writers" trigger fired, and the audit came back clean.**
  `D_serial_turn_executor` writes it down: two turn-ends write two *disjoint subdirectories*;
  `write_meta` touches only `conversation.dir/meta.json` through a sibling temp file and a
  rename inside that same directory; the root is created in the constructor and otherwise only
  enumerated; and one directory can never have two writers because a conversation admits one
  turn at a time. That is why `--turns > 1` shipped without this lock.
- **"Reads run unsynchronized from Sinatra request threads" is false now.** Nothing in `App`
  holds a store. Every store call the app makes goes through {ConversationRegistry}, whose
  `Monitor` wraps `@store.list` (in `#rows`), `@store.find`, `@store.create` and `@store.delete`.
  The store's operations are *already* serialized against each other — by the registry.
- **`delete`'s "natural home is a request thread, so the discipline is gone" is false too.**
  It shipped as `ConversationRegistry#delete`, which is where the busy-refusal has to live
  anyway; it holds the registry monitor across `busy?` → drop the runner → `@store.delete`.
  There is no `AgentRunner#delete_conversation`, no `switch_conversation`, no `switch_to` — a
  runner *is* one conversation for its lifetime.
- **The `row` TOCTOU fix has shipped.** `row` no longer checks `file?` before reading;
  `load_meta` rescues `Errno::ENOENT` into `:absent`, which `row` drops from the listing, with
  corrupt-JSON and unknown-schema still coming back `supported: false`. The comment in `row`
  says why. That was always the only part of this note that survived a second process, and it
  is done.
- **`concurrent-ruby` is in the bundle.** `bin/pikuri-web-chat` builds a
  `Concurrent::FixedThreadPool` for turns (`D_serial_turn_executor`), with its own Gemfile
  paragraph. So the whole "it would be a genuinely new direct dependency, and the only
  non-stdlib lock in the family" cost argument below is void: `Concurrent::ReentrantReadWriteLock`
  is a `require` away and costs nothing.
- **`History#save` now goes through the store, so the "a lock could only guard half the folder"
  objection is gone — removed by refactor rather than argued away.**
  `ConversationStore#save(conversation, history)` creates the directory 0700, calls
  `history.save(dir)`, then writes `meta.json`; `AgentRunner#persist` is one call and decides
  only *whether* to save (an empty history is not worth a folder), and `write_meta` is private.
  The store is now the single writer of a conversation's directory: the mode it is created with,
  the order the halves land in, and which one commits are decided in one place instead of at the
  call site. Two things fell out of it beyond the lock question — the history is no longer
  briefly written into a default-mode directory (0700 comes first now, where `write_meta` used
  to tighten it afterwards, and `History#save` creates `attachments/` before it `mkpath`s the
  directory itself), and a failed history write provably leaves the conversation unlisted rather
  than half-committed, which is now a spec instead of a comment.
- **The seam rule was restated on the way**, because this put a `Pikuri::Agent::History` in the
  store: `D_pikuri_free_core` is now a boundary (nothing the browser sees speaks a pikuri type)
  rather than a list of four classes, and the store is server-side of it. A block form that kept
  the store literally Pikuri-free was built first and reverted — see that entry's rejected
  alternatives. `AGENTS.md`'s seam bullet and Layout line are updated.

## So: read-write lock, plain lock, or nothing?

**The RW-lock question answers itself, and always did.** An RWLock buys parallel readers, which
pays only under read contention with long read critical sections. `#list` is a directory scan of
a few hundred `stat`s (~ms) for a single user with a handful of tabs. `#list`'s rdoc already
carries the matching rule — *measure a slow sidebar before trading the directory away*. The gem
being free now removes the argument *against* an RWLock without supplying one *for* it: it would
be a more complex lock guarding the same uncontended milliseconds. If a sidebar ever measures
badly, the fix is the index file `#list` already rejected, not a fancier lock.

**And the plain lock buys nothing either, which is the finding of this re-audit.** The `#save`
refactor above deliberately removed the one argument that said a lock was *impossible*; what is
left says it is *unnecessary*, which is the better place to stand:

1. **The consistency does not rest on a discipline any more — it rests on construction, and it
   is written down.** Disjoint directories, one writer per directory, atomic rename, and a read
   whose own `ENOENT` is the answer. `D_serial_turn_executor` states all four. A lock would
   serialize operations that are already safe to interleave.
2. **It invites the false argument it was meant to prevent.** A `Monitor` in the store reads as
   *the* reason the folder is consistent, and the next reader relaxes the atomic rename or puts
   the `file?` check back — the two things that actually work, and the only two that work
   against a second process or against pikuri's own writes. `D_serial_turn_executor` already
   warns in exactly this shape: distrust a correctness argument resting on the wrong mechanism.
3. **The store lock's ordering obligation is real and buys nothing back.** It would be the third
   lock, under the registry monitor (which calls into the store) and unordered against
   `AgentRunner`'s mutex. The ordering happens to be forced already — runner or registry
   outermost, store innermost, never the reverse — but "a documented lock ordering" is a cost
   to carry, not a benefit.
4. **A lock around `#save` would now hold across the whole history write.** Whatever critical
   section wrapped it would contain pikuri's entire `history.json` + `attachments/` write — the
   longest filesystem operation this project performs — where before it held only a rename. That
   is the one honest argument an RWLock has left (readers blocking behind a multi-megabyte save
   rather than behind a rename), and it argues for *no* lock around the write at all, not for a
   cleverer one.
5. **Adding it later is a local change.** Now that one method owns the whole write path, the
   lock is a two-line diff whenever a real reason appears. Nothing is being deferred at a cost.

## What the complaint *actually* is — and its one-sentence fix

The store's rdoc says **"Thread-safe: stateless past its constructor arguments"**, which is a
true claim about the *object* sitting where a reader looks for a claim about the *folder*. That
is the whole of the legitimate finding, and a `Monitor` is not its fix — a sentence is. Name
what is guaranteed and by what:

- the object holds no mutable state, so concurrent calls need no lock here;
- one conversation's directory has one writer at a time, which comes from the partition
  (`D_conversation_owns_agent`) and not from anything in this class — and since the `#save`
  refactor that writer goes through this class, so the claim is at least about the right scope;
- `meta.json` is written temp-file-and-rename, which is what a reader *outside this process*
  gets and all it gets (`D_no_multi_process_lock`);
- `#row` treats a read's own `ENOENT` as "not listed", so a listing concurrent with a save or a
  delete is correct without coordination;
- cross-call sequences are not atomic — `find` then `delete` has a gap, and callers tolerate
  the conversation having vanished.

And the pointer in {ConversationRegistry}'s rdoc — "the store's folder is its own problem
(`ideas/conversation-store-locking.md`)" — needs to resolve somewhere real once this file goes.

## The residual race — found here, fixed elsewhere

Worth recording because it is the one real bug this re-audit turned up, and a store lock would
*not* have caught it (it is the "no cross-call atomicity" bullet with teeth): a request thread
that obtained a runner from `registry.open` before a delete could call `submit` on it afterwards,
and the turn's `persist` wrote the deleted folder back. `ConversationRegistry#delete` dropped the
runner from the map precisely so nothing *resident* resurrected it, but a stale reference was
outside that — and once the runner is out of the map, `busy?` can never see it again.

Fixed 2026-08-28 as runner state, not store state: `AgentRunner#discard!` is one atomic
busy-check-and-claim on the runner's mutex, called inside the registry's monitor, and `#submit`
answers `:discarded` (404 from `POST /messages`) on a retired runner. Written up as an amendment
in `D_delete_no_undo`'s consequences — nothing about it belongs to this file any more.

## If this is graduated as a "no"

Mirror `D_no_multi_process_lock`: a `D_no_store_lock` entry saying the store is consistent by
construction rather than by lock, with the five reasons above and the RW-lock-buys-nothing
paragraph as the rejected alternatives, plus a flat invariant in **Scope decisions**. Note in it
that the half-the-folder objection was *removed by refactor* — `#save` shipped as part of this
graduation — so a future reader does not resurrect an argument that was retired rather than
rejected. The rdoc sentence above is the only code change left.

`#save` itself is worth a line of its own in that entry (or its own `D_` if it grows one): the
store owns a conversation's directory, and a caller hands it a payload writer rather than
writing beside it. Its **Layout** line in `AGENTS.md` is updated already.

Trigger to reopen the lock: a store operation that spans two directories (a move, a merge, an
index file), or a second writer to one conversation's folder — either breaks the disjointness
the whole audit rests on.
