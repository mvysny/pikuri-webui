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
  #   conversation = store.create                    # mints an id; writes nothing
  #   agent.export_history.save(conversation.dir)    # pikuri writes history.json
  #   store.write_meta(conversation)                 # our envelope, and the commit point
  #
  # A conversation directory holds both halves of that split, and each side
  # writes only its own files:
  #
  #   2026-08-27T12-03-51Z-3f9a/
  #       history.json   pikuri's — Pikuri::Agent::History#save
  #       attachments/   pikuri's — content-addressed, present only if there are any
  #       meta.json      ours — title, timestamps, and which shell/model wrote it
  #
  # Sharing one directory is safe by upstream contract, not by luck:
  # +History#save+ never deletes and never enumerates the folder it writes into
  # (pikuri +DECISIONS.md+ +D_history_attachments+), so +meta.json+ is not at
  # risk from a save. In the other direction this class only ever touches
  # +meta.json+.
  #
  # Pikuri-free by design (the seam rule in AGENTS.md): this class deals in
  # paths and plain hashes, never a +Pikuri::Agent::History+. That is what
  # +History#save+ taking a *directory* buys — {AgentRunner} holds the history,
  # this holds the folder.
  #
  # == Implementation details
  #
  # {#create} deliberately writes nothing. A "New conversation" click that
  # created a directory would litter the root with empty conversations, so a
  # conversation reaches disk only once it has something in it.
  #
  # Directories are created 0700: a conversation holds everything the user
  # typed plus whatever the tools scraped, unencrypted. That covers
  # +attachments/+ too — pikuri creates it with the default mode, but an
  # unreadable parent is what actually blocks traversal.
  #
  # Thread-safe: stateless past its constructor arguments. Which conversation
  # is *live* is deliberately not here — {AgentRunner} owns that, since it owns
  # the agent whose history it is.
  class ConversationStore
    # Basename of the envelope this class owns. +history.json+ next to it is
    # pikuri's and is never read or written here.
    META_FILE = 'meta.json'

    # +meta.json+'s format version. Bumped only for a change an old reader
    # could not survive; a sidebar meeting a higher one should grey the row out
    # rather than crash.
    SCHEMA = 1

    # One conversation's identity and where it lives. Carries no history — that
    # is on disk under {#dir}, and in the agent when this conversation is live.
    #
    # @!attribute [r] id
    #   @return [String] the directory basename, e.g. +"2026-08-27T12-03-51Z-3f9a"+
    # @!attribute [r] dir
    #   @return [Pathname] the conversation's directory; may not exist yet
    # @!attribute [r] title
    #   @return [String] display title; a local-time stamp until v2 retitles it
    # @!attribute [r] created_at
    #   @return [Time]
    Conversation = Data.define(:id, :dir, :title, :created_at)

    # @param root [String, Pathname] directory holding one subdirectory per
    #   conversation, e.g. +~/.local/state/pikuri/conversations+; created on
    #   first write, not here
    # @param shell [String] which binary is writing these, recorded in
    #   +meta.json+ so a later picker can say "saved by a different harness"
    # @param model [String] the model this conversation is talking to
    def initialize(root:, shell:, model:)
      @root = Pathname(root)
      @shell = shell
      @model = model
    end

    # @return [Pathname] the conversations root
    attr_reader :root

    # Mint a new conversation, writing nothing.
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
      id = "#{at.utc.strftime('%Y-%m-%dT%H-%M-%SZ')}-#{SecureRandom.hex(2)}"
      Conversation.new(
        id: id,
        dir: @root / id,
        title: at.localtime.strftime('%Y-%m-%d %H:%M'),
        created_at: at
      )
    end

    # Write +meta.json+, creating the conversation's directory if needed.
    #
    # Call it *after* the history is written: +history.json+ is the
    # conversation, +meta.json+ is what says it is worth listing, so an
    # interrupted save leaves an unlisted conversation rather than a listed
    # empty one.
    #
    # @param conversation [Conversation]
    # @param updated_at [Time] last-activity stamp; the sidebar's sort key
    # @return [Pathname] the file written
    def write_meta(conversation, updated_at: Time.now)
      mkdir_private(@root)
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
    # +meta.json+ — the same shape +History#save+ uses for its own files.
    def atomic_write(path, content)
      tmp = path.dirname / ".#{path.basename}.tmp"
      tmp.write(content)
      tmp.rename(path.to_path)
    end
  end
end
