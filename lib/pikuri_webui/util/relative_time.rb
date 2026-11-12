# frozen_string_literal: true

module PikuriWebUI
  module Util
    # Coarse "how long ago" for the conversation sidebar:
    #
    #   RelativeTime.humanize(now - 30)      # => "just now"
    #   RelativeTime.humanize(now - 5400)    # => "1 hour ago"
    #   RelativeTime.humanize(now - 200_000) # => "2 days ago"
    #   RelativeTime.humanize(now - 5e6)     # => "2026-06-30"
    #
    # Coarse on purpose: this is rendered server-side into a page that may sit
    # open for hours, so it goes stale between renders. Rounding to the unit
    # keeps "3 hours ago" honest for the whole hour it is wrong by.
    module RelativeTime
      # Absolute date past this age, where "N days ago" stops being how anyone
      # thinks about it.
      #
      # @return [Integer]
      CUTOFF = 30 * 86_400

      # @param time [Time]
      # @param now [Time]
      # @return [String] never empty; a future +time+ (clock skew) reads
      #   "just now" rather than a negative count
      def self.humanize(time, now: Time.now)
        case (seconds = now - time)
        when ...120 then 'just now'
        when ...3600 then plural(seconds / 60, 'minute')
        when ...86_400 then plural(seconds / 3600, 'hour')
        when ...CUTOFF then plural(seconds / 86_400, 'day')
        else time.getlocal.strftime('%Y-%m-%d')
        end
      end

      # @param count [Numeric] truncated to whole units
      # @param unit [String]
      # @return [String]
      def self.plural(count, unit)
        count = count.to_i
        "#{count} #{unit}#{'s' unless count == 1} ago"
      end
      private_class_method :plural
    end
  end
end
