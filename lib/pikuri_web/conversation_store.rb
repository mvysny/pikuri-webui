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
  #   store.list                                     # everything committed, newest first
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
    Conversation = Data.define(:id, :dir, :title, :created_at, :supported)

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
      id = "#{at.getutc.strftime(ID_TIME)}-#{SecureRandom.hex(2)}"
      Conversation.new(
        id: id, dir: @root / id, title: stamp_title(at), created_at: at, supported: true
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
    # A directory without +meta.json+ is not listed — {#write_meta} is the
    # commit point, so that is a save interrupted between pikuri's half and
    # ours. One whose +meta.json+ is unreadable, or stamped by a schema this
    # version doesn't know, comes back +supported: false+ rather than being
    # dropped: a conversation the user can see and not open beats one that
    # silently isn't there.
    #
    # @return [Array<Conversation>]
    def list
      @root.children.filter_map { |dir| row(dir) }.sort_by(&:id).reverse
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
      return nil unless (dir / META_FILE).file?

      meta = load_meta(dir / META_FILE)
      title = meta && meta['title']
      Conversation.new(
        id: dir.basename.to_s,
        dir: dir,
        title: title.is_a?(String) ? title : stamp_title(created_at),
        created_at: created_at,
        supported: !meta.nil?
      )
    end

    # The envelope, or nil when this reader can't stand behind it — corrupt,
    # unreadable, or written by a schema it doesn't know.
    #
    # @param path [Pathname]
    # @return [Hash, nil]
    def load_meta(path)
      meta = JSON.parse(path.read)
      meta if meta.is_a?(Hash) && meta['schema'] == SCHEMA
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
