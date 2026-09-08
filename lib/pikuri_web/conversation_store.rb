# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'pathname'
require 'securerandom'
require 'time'

module PikuriWeb
  # The on-disk home of saved conversations: one directory per conversation
  # under a single root. Minting an id and committing are separate steps — a
  # folder per click would litter the root — but a commit is *one* call, and
  # it writes both halves:
  #
  #   store = ConversationStore.new(root: dir, shell: 'pikuri-web-chat')
  #   conversation = store.create                            # mints an id; no folder yet
  #   store.save(conversation, history, model: m, server: s) # the whole commit
  #   store.list                                             # everything committed, newest first
  #
  # {#save} calls +History#save+ itself rather than leaving each caller to
  # write +history.json+ beside the envelope, which is what makes this class
  # the single writer of a conversation's directory — the mode, the order and
  # the commit point are decided once. It is also the only method here that
  # touches a pikuri type, and that is the shape of the seam rather than a
  # leak in it (`D_pikuri_free_core`); {#list}, {#find} and {#delete} deal in
  # paths and plain hashes.
  #
  # The root exists from construction; a conversation's own directory appears
  # with its first save.
  #
  # Both halves land in the one directory, and each format has exactly one
  # writer:
  #
  #   2026-08-27T12-03-51Z-3f9a/
  #       history.json   pikuri's — Pikuri::Agent::History#save
  #       attachments/   pikuri's — content-addressed, only if there are any
  #       meta.json      ours — title, timestamps, shell and connection
  #
  # == The connection a conversation is on
  #
  # +meta.json+ records the +[model, server]+ *pair*, not a +[[llm]]+ name: a
  # name is a config file away from being renamed, and a model id alone cannot
  # tell two servers running one model apart. +server+ is the transport's
  # normalized +api_base+, so the pair is exactly what {ModelCatalog#resolve}
  # matches on. An envelope missing either half reads as a conversation with no
  # saved connection — a key can be added here without a {SCHEMA} bump, because
  # {#load_meta} checks the version and ignores what it does not read.
  #
  # {#save} takes the pair per call rather than the store holding one, because
  # what gets written is the *agent's own* transport at turn end; a store-wide
  # field could only ever record the connection this process booted on.
  # {Conversation}'s +_at_mint+ pair runs the other way — what disk said when
  # the runner was minted — and a save deliberately does not refresh it.
  #
  # == Implementation details
  #
  # Co-tenancy in one directory is safe by upstream contract rather than by
  # luck: +History#save+ never deletes and never enumerates the folder it
  # writes into (pikuri +DECISIONS.md+ +D_history_attachments+).
  #
  # Directories are created 0700: a conversation holds everything the user
  # typed plus whatever the tools fetched, unencrypted. That covers
  # +attachments/+, which pikuri creates with the default mode — an unreadable
  # parent is what actually blocks traversal. Hence {#save}'s first step:
  # tightening the directory *after* writing into it leaves the contents
  # world-readable for as long as the write takes.
  #
  # == Thread-safety
  #
  # Thread-safe, in the narrow sense that is all this object can promise: it
  # holds no mutable state past its constructor arguments, so concurrent calls
  # need no lock *here*. The consistency of the *folder* rests elsewhere —
  #
  # - one conversation's directory has one writer at a time, which comes from
  #   the per-conversation partition (`D_conversation_owns_agent`), not from
  #   anything in this class;
  # - both files are written temp-file-and-rename, which is the whole of what
  #   a reader in another process gets (`D_no_multi_process_lock`);
  # - {#list} needs no coordination with a concurrent save or delete, because
  #   +#row+ takes a read's own +ENOENT+ as the answer.
  #
  # Cross-call sequences are *not* atomic: {#find} then {#delete} has a gap,
  # and a caller must tolerate the conversation having vanished inside it.
  class ConversationStore
    # Basename of the envelope whose *format* is ours. The +history.json+
    # beside it is pikuri's: {#save} causes it, nothing here parses it.
    META_FILE = 'meta.json'

    # +meta.json+'s format version. Bumped only for a change an old reader
    # could not survive; {#list} refuses that one conversation rather than
    # crash the whole listing.
    SCHEMA = 1

    # The start stamp an id opens with, +strftime+ing and matching halves of
    # the same format.
    ID_TIME = '%Y-%m-%dT%H-%M-%SZ'
    ID = /\A(\d{4})-(\d\d)-(\d\d)T(\d\d)-(\d\d)-(\d\d)Z-[0-9a-f]+\z/

    # One conversation's identity and where it lives; no history of its own —
    # that is +history.json+ under +dir+.
    #
    # @!attribute [r] id
    #   @return [String] the directory basename, e.g. +"2026-08-27T12-03-51Z-3f9a"+
    # @!attribute [r] dir
    #   @return [Pathname] the conversation's directory; may not exist yet
    # @!attribute [r] title
    #   @return [String] display title — the local-time start stamp
    # @!attribute [r] created_at
    #   @return [Time]
    # @!attribute [r] supported
    #   @return [Boolean] false for a conversation {#list} could not read —
    #     +title+ is then the stamp derived from the id, and nothing else on
    #     disk should be trusted
    # @!attribute [r] model_at_mint
    #   @return [String, nil] the model +meta.json+ held when this value object
    #     was built, or what {#create} inherited; nil for a conversation with
    #     no saved connection. Read once, when a runner is minted on it —
    #     the next save moves +meta.json+ on and this never follows, which is
    #     what the suffix is there to say at the call site
    # @!attribute [r] server_at_mint
    #   @return [String, nil] the +server+ half of the same pair
    Conversation = Data.define(:id, :dir, :title, :created_at, :supported,
                               :model_at_mint, :server_at_mint) do
      # Defaulted because "no saved connection" is a real and ordinary state —
      # every conversation is in it until its first turn lands.
      def initialize(model_at_mint: nil, server_at_mint: nil, **) = super
    end

    # Creates +root+ if it is not there — so the folder exists from boot,
    # rather than appearing on whichever later event happens to save first.
    #
    # @param root [String, Pathname] directory holding one subdirectory per
    #   conversation, e.g.
    #   +~/.local/state/pikuri/pikuri-web-chat/conversations+
    # @param shell [String] which binary is writing these, recorded in
    #   +meta.json+ so a later picker can say "saved by a different harness"
    def initialize(root:, shell:)
      @root = Pathname(root)
      @shell = shell
      mkdir_private(@root)
    end

    # @return [Pathname] the conversations root
    attr_reader :root

    # Mint a new conversation. No directory yet — a folder per click would
    # litter the root with conversations nothing was ever said in, so one
    # appears when there is something to put in it.
    #
    #   store.create.id     # => "2026-08-27T12-03-51Z-3f9a"
    #   store.create.title  # => "2026-08-27 14:03"
    #
    # The id sorts lexically and greps by date, so +ls+ is already a
    # newest-last listing; the random suffix keeps two processes minting in the
    # same second apart. UTC in the id, local time in the title.
    #
    # @param at [Time] the conversation's start time
    # @param model [String, nil] connection to start on, inherited from the
    #   conversation the tab was reading; nil starts on the catalog's first
    # @param server [String, nil] the +server+ half of the same pair
    # @return [Conversation]
    def create(at: Time.now, model: nil, server: nil)
      # #getutc / #getlocal, not #utc / #localtime: the destructive pair would
      # convert the caller's own Time object as a side effect.
      id = "#{at.getutc.strftime(ID_TIME)}-#{SecureRandom.hex(2)}"
      Conversation.new(
        id: id, dir: @root / id, title: stamp_title(at), created_at: at, supported: true,
        model_at_mint: model, server_at_mint: server
      )
    end

    # Every conversation committed to disk, newest first.
    #
    #   store.list.map { [_1.title, _1.supported] }
    #   # => [["2026-08-27 14:03", true], ["2026-08-26 09:14", false]]
    #
    # Newest-first is a lexical sort on the id, which *is* the start stamp: a
    # conversation holds its place in the list however long it goes on being
    # written to, and ordering never opens a file.
    #
    # A directory without +meta.json+ is not listed — that file is {#save}'s
    # commit point, so such a directory is a save interrupted between the
    # history and the envelope. One whose +meta.json+ is unreadable, or
    # stamped by a schema this version doesn't know, comes back
    # +supported: false+ rather than being dropped: a conversation the user
    # can see and not open beats one that silently isn't there.
    #
    # No index file fronts the per-conversation +meta.json+ reads: an index is
    # a cache of the directory, and it drifts from it. They are fine into the
    # hundreds — measure a slow sidebar before trading that away.
    #
    # @return [Array<Conversation>]
    def list
      @root.children.filter_map { |dir| row(dir) }.sort_by(&:id).reverse
    end

    # One listed conversation by id, or nil.
    #
    #   store.find(params['id'])   # => Conversation, or nil for anything else
    #
    # Resolution goes *through the listing* rather than by building a path, so
    # an id arriving from a URL can only ever name a conversation that is
    # already there — no caller has to think about traversal.
    #
    # @param id [String]
    # @return [Conversation, nil]
    def find(id)
      list.find { |conversation| conversation.id == id }
    end

    # Remove a conversation from disk — folder, +history.json+,
    # +attachments/+.
    #
    #   store.delete(store.find(params['id']))   # => true
    #
    # +meta.json+ is unlinked *before* the folder, inverting {#save}'s
    # commit point: a removal that dies half-way then leaves a conversation
    # unlisted, rather than one that lists and cannot be opened.
    #
    # Takes a +Conversation+ rather than an id, like {#find}, so no caller
    # turns user input into a path. Nothing is refcounted — attachments are
    # never shared between conversations.
    #
    # @param conversation [Conversation] from {#list} or {#find}
    # @return [Boolean] true when a folder was removed; false when there was
    #   nothing on disk — a conversation minted but never saved
    # @raise [ArgumentError] when the conversation does not live under the
    #   root
    def delete(conversation)
      raise ArgumentError, "#{conversation.id} is not under #{@root}" unless conversation.dir.parent == @root
      return false unless conversation.dir.exist?

      FileUtils.rm_f((conversation.dir / META_FILE).to_path)
      FileUtils.rm_r(conversation.dir.to_path)
      true
    end

    # Commit a conversation to disk — the directory, the history, the envelope.
    #
    #   store.save(conversation, agent.export_history,
    #              model: transport.model, server: transport.api_base)   # => the directory
    #
    # +meta.json+ goes last because it is the commit point: {#list} skips a
    # directory without one, so a save that dies half-way leaves an *unlisted*
    # conversation rather than a listed one that cannot be opened. {#delete}
    # inverts the order for the same reason.
    #
    # An empty history still commits — whether a conversation with no messages
    # deserves a folder is the caller's call, not the folder's.
    #
    # @param conversation [Conversation] from {#create}, {#list} or {#find}
    # @param history [Pikuri::Agent::History] anything answering
    #   +#save(Pathname)+ does, which is what makes this testable without an
    #   agent
    # @param model [String] what the agent is *on* — read off its transport,
    #   never off a selection, so this and +history.json+'s last +model_id+
    #   agree by construction
    # @param server [String] the transport's +api_base+
    # @param updated_at [Time] last-activity stamp; the sidebar's sort key
    # @return [Pathname] the conversation's directory
    def save(conversation, history, model:, server:, updated_at: Time.now)
      mkdir_private(conversation.dir)
      history.save(conversation.dir)
      write_meta(conversation, model: model, server: server, updated_at: updated_at)
      conversation.dir
    end

    # Whether this conversation still carries the start stamp it was minted
    # with — i.e. nothing has named it yet.
    #
    # The test is the stamp's *shape*, because +meta.json+'s +title+ always
    # holds something and +#row+ falls back to the stamp when it does not. A
    # model-written title colliding with +"%Y-%m-%d %H:%M"+ is not a real case.
    #
    # @param conversation [Conversation]
    # @return [Boolean]
    def stamp_titled?(conversation)
      conversation.title == stamp_title(conversation.created_at)
    end

    # Rename a conversation: in memory always, on disk when there is an
    # envelope to rewrite.
    #
    #   conversation = store.retitle(conversation, 'Sinatra Versus Roda For SSE')
    #
    # The renamed {Conversation} is the return value because it is frozen and
    # {#save} writes +conversation.title+ — a caller that kept the old value
    # would revert the rename at its next save.
    #
    # No envelope yet (minted, first turn not saved), or one this reader cannot
    # stand behind, is renamed in memory alone: the next {#save} writes
    # +meta.json+ whole and carries the title anyway. The directory is
    # untouched in every case — a title never appears in a path.
    #
    # @param conversation [Conversation]
    # @param title [String] stored as given — capping and sanitizing belong to
    #   whoever produced it.
    # @return [Conversation] the same conversation, retitled.
    # @raise [SystemCallError] like {#save}, when the write itself fails; a
    #   folder deleted underneath is the caller's to tolerate
    #   (`D_no_store_lock`).
    def retitle(conversation, title)
      path = conversation.dir / META_FILE
      meta = load_meta(path)
      atomic_write(path, "#{JSON.pretty_generate(meta.merge('title' => title))}\n") if meta.is_a?(Hash)
      conversation.with(title: title)
    end

    private

    # Write +meta.json+, into a directory {#save} has already created 0700.
    #
    # @param conversation [Conversation]
    # @param model [String]
    # @param server [String]
    # @param updated_at [Time]
    # @return [Pathname] the file written
    def write_meta(conversation, model:, server:, updated_at:)
      path = conversation.dir / META_FILE
      atomic_write(path, "#{JSON.pretty_generate(
        'schema' => SCHEMA,
        'id' => conversation.id,
        'title' => conversation.title,
        'created_at' => conversation.created_at.utc.iso8601,
        'updated_at' => updated_at.utc.iso8601,
        'shell' => @shell,
        'model' => model,
        'server' => server
      )}\n")
      path
    end

    # One listing row, or nil for a directory that is not a committed
    # conversation.
    #
    # @param dir [Pathname]
    # @return [Conversation, nil]
    def row(dir)
      return nil unless dir.directory?

      # The stamp comes from the directory name rather than meta.json's
      # created_at: the name is the sort key, so a disagreeing envelope would
      # sort a conversation in one place and date it in another.
      created_at = id_time(dir.basename.to_s)
      return nil if created_at.nil?

      # No +file?+ check first: the read's own ENOENT is the answer, and a
      # check-then-read would call a conversation being deleted right now
      # "unsupported format" instead of dropping it.
      meta = load_meta(dir / META_FILE)
      return nil if meta == :absent

      title = meta && meta['title']
      model, server = saved_connection(meta)
      Conversation.new(
        id: dir.basename.to_s,
        dir: dir,
        title: title.is_a?(String) ? title : stamp_title(created_at),
        created_at: created_at,
        supported: !meta.nil?,
        model_at_mint: model,
        server_at_mint: server
      )
    end

    # The envelope; nil when this reader can't stand behind it — corrupt, or
    # written by a schema it doesn't know — and +:absent+ when there is no
    # envelope at all, which is a save interrupted between pikuri's half and
    # ours rather than a conversation to list.
    #
    # @param path [Pathname]
    # @return [Hash, nil, :absent]
    def load_meta(path)
      meta = JSON.parse(path.read)
      meta if meta.is_a?(Hash) && meta['schema'] == SCHEMA
    rescue Errno::ENOENT
      :absent
    rescue JSON::ParserError, SystemCallError
      nil
    end

    # @param basename [String]
    # @return [Time, nil] nil when the name is not one of our ids
    def id_time(basename)
      match = ID.match(basename)
      match && Time.utc(*match.captures.map(&:to_i))
    rescue ArgumentError
      # Shaped like an id but not a date (month 99): one hand-made directory
      # must not take the whole listing down.
      nil
    end

    # @param at [Time]
    # @return [String] the local-time start stamp a conversation is titled by
    #   until something better replaces it
    def stamp_title(at) = at.getlocal.strftime('%Y-%m-%d %H:%M')

    # The pair is one value: half of it is none of it, and a half-written or
    # hand-edited one reads as no connection at all rather than travelling on
    # to the conversation factory.
    #
    # An envelope carrying a +model+ and no +server+ is the case that matters:
    # that +model+ named the connection its *writer* was booted on, not the
    # conversation's, so matching on it alone is the very conflation the pair
    # exists to prevent.
    #
    # @param meta [Hash, nil]
    # @return [Array(String, String), Array(nil, nil)]
    def saved_connection(meta)
      pair = %w[model server].map { |key| meta && meta[key] }
      pair.all?(String) ? pair : [nil, nil]
    end

    # 0700 explicitly rather than through +mkdir_p+'s +mode:+, which a umask
    # can widen.
    def mkdir_private(dir)
      FileUtils.mkdir_p(dir.to_path)
      FileUtils.chmod(0o700, dir.to_path)
    end

    # Sibling temp file plus rename, so a reader never sees a half-written
    # +meta.json+.
    def atomic_write(path, content)
      tmp = path.dirname / ".#{path.basename}.tmp"
      tmp.write(content)
      tmp.rename(path.to_path)
    end
  end
end
