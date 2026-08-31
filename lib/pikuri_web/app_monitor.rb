# frozen_string_literal: true

require 'monitor'

module PikuriWeb
  # The serialization domain: one re-entrant monitor over all of this server's
  # cross-thread mutable state. Work happens in *tasks* — blocks run to
  # completion, alone in the domain — so the system is only ever observed
  # *between* tasks, never inside one, and two objects mutated or read
  # together stay one unit:
  #
  #   monitor.run do                 # a task
  #     runner = registry.open_id(id)
  #     runner&.submit(prompt)       # resolve + submit, untearable
  #   end
  #
  # Guarded classes ({AgentRunner}, {ConversationRegistry}, {Transcript}) open
  # their public methods with {#assert!}, so a call from outside a task raises
  # instead of racing. Who enters the domain: every route body ({App}), and
  # the turn worker's bookkeeping brackets (+AgentRunner#run_turn+) — the
  # agent loop itself, and all rendering, stay outside.
  #
  # A task must be **rapid-fire**: never a network wait, never a wait on
  # another thread, never anything unbounded. Bounded disk work is allowed
  # (the turn-end save, the restore replay — capped by context-window
  # economics). A stall inside a task stalls every conversation and every
  # request; the `SIGPWR` dump (`D_puma_thread_dump`) is the debugger for one.
  # See `D_global_monitor` for the whole contract.
  class AppMonitor
    # Raised by {#assert!} for a call outside a task. An +Exception+, not a
    # +StandardError+, so the blanket recovery paths (`rescue StandardError`
    # around the turn job and the registry's delete) cannot mask a guarding
    # bug as an operational failure.
    class OutsideTask < Exception; end # rubocop:disable Lint/InheritException

    def initialize
      @monitor = Monitor.new
    end

    # Run one task: the block executes inline on the calling thread, alone in
    # the domain. Re-entrant — a task may open another task, so a guarded
    # method calling back into the domain (the Interloper's +on_change+) just
    # works.
    #
    # @return [Object] the block's value
    def run(&) = @monitor.synchronize(&)

    # Guard clause for methods that must only run inside a task.
    #
    #   def submit(message)
    #     @monitor.assert!
    #     ...
    #
    # @return [void]
    # @raise [OutsideTask] when the calling thread is not inside {#run}
    def assert!
      raise OutsideTask, 'must be called inside an AppMonitor task' unless @monitor.mon_owned?

      nil
    end
  end
end
