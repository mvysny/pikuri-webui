# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'pathname'
require 'securerandom'
require 'time'

module PikuriWeb
  # The on-disk home of saved conversations: one directory per conversation
  # under a single root. Minting an id and writing the envelope are separate
  # steps, because the history itself is written by pikuri in between:
  #
  #   store = ConversationStore.new(root: dir, shell: 'pikuri-web-chat', model: 'qwen3.6')
  #   conversation = store.create                    # mints an id; no folder yet
  #   agent.export_history.save(conversation.dir)    # pikuri writes history.json
  #   store.write_meta(conversation)                 # our envelope, and the commit point
  #
  # The root exists from construction; a conversation's own directory appears
  # with its first save.
  #
  # Both halves land in the one directory, and each side writes only its own:
  #
  #   2026-08-27T12-03-51Z-3f9a/
  #       history.json   pikuri's — Pikuri::Agent::History#save
  #       attachments/   pikuri's — content-addressed, only if there are any
  #       meta.json      ours — title, timestamps, shell and model
  #
  # Pikuri-free by design (the seam rule in AGENTS.md): this deals in paths and
  # plain hashes, never a +Pikuri::Agent::History+ — which is what
  # +History#save+ taking a *directory* buys.
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
  # parent is what actually blocks traversal.
  #
  # Thread-safe: stateless past its constructor arguments.
  class ConversationStore
    # Basename of the envelope this class owns. The +history.json+ beside it is
    # pikuri's, and is never read or written here.
    META_FILE = 'meta.json'

    # +meta.json+'s format version. Bumped only for a change an old reader
    # could not survive; a reader meeting a higher one should refuse that one
    # conversation rather than crash.
    SCHEMA = 1

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
    Conversation = Data.define(:id, :dir, :title, :created_at)

    # Creates +root+ if it is not there — so the folder exists from boot,
    # rather than appearing on whichever later event happens to save first.
    #
    # @param root [String, Pathname] directory holding one subdirectory per
    #   conversation, e.g.
    #   +~/.local/state/pikuri/pikuri-web-chat/conversations+
    # @param shell [String] which binary is writing these, recorded in
    #   +meta.json+ so a later picker can say "saved by a different harness"
    # @param model [String] the model this conversation is talking to
    def initialize(root:, shell:, model:)
      @root = Pathname(root)
      @shell = shell
      @model = model
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
    # @return [Conversation]
    def create(at: Time.now)
      # #getutc / #getlocal, not #utc / #localtime: the destructive pair would
      # convert the caller's own Time object as a side effect.
      id = "#{at.getutc.strftime('%Y-%m-%dT%H-%M-%SZ')}-#{SecureRandom.hex(2)}"
      Conversation.new(
        id: id,
        dir: @root / id,
        title: at.getlocal.strftime('%Y-%m-%d %H:%M'),
        created_at: at
      )
    end

    # Write +meta.json+, creating the conversation's directory if pikuri has
    # not already — and re-asserting 0700 either way, since +History#save+
    # creates it with the default mode.
    #
    # Call it *after* the history: +history.json+ is the conversation,
    # +meta.json+ is what says it is worth listing, so an interrupted save
    # leaves an unlisted conversation rather than a listed empty one.
    #
    # @param conversation [Conversation]
    # @param updated_at [Time] last-activity stamp; the sidebar's sort key
    # @return [Pathname] the file written
    def write_meta(conversation, updated_at: Time.now)
      mkdir_private(conversation.dir)
      path = conversation.dir / META_FILE
      atomic_write(path, "#{JSON.pretty_generate(
        'schema' => SCHEMA,
        'id' => conversation.id,
        'title' => conversation.title,
        'created_at' => conversation.created_at.utc.iso8601,
        'updated_at' => updated_at.utc.iso8601,
        'shell' => @shell,
        'model' => @model
      )}\n")
      path
    end

    private

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
