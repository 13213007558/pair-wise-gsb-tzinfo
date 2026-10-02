# encoding: UTF-8
# frozen_string_literal: true

module TZInfo
  module DataSources
    # Represents a data time zone defined by a finite history of transitions
    # followed by a set of annually repeating rules (as derived from the
    # POSIX-style TZ string footer of a zoneinfo file). The annual rules are
    # evaluated lazily, allowing queries for arbitrarily distant years without
    # pre-generating (and retaining) transitions for every intervening year.
    class AnnualRulesDataTimezoneInfo < DataTimezoneInfo
      # Initializes a new {AnnualRulesDataTimezoneInfo}.
      #
      # @param identifier [String] the identifier of the time zone.
      # @param timeline [AnnualRulesTimeline] the finite history joined to the
      #   annual rules.
      # @raise [ArgumentError] if either identifier or timeline is nil.
      def initialize(identifier, timeline)
        super(identifier)
        raise ArgumentError, 'timeline must be specified' unless timeline
        @timeline = timeline
        @transitions = timeline.transitions
      end

      # (see DataTimezoneInfo#period_for)
      def period_for(timestamp)
        raise ArgumentError, 'timestamp must be specified' unless timestamp
        raise ArgumentError, 'timestamp must have a specified utc_offset' unless timestamp.utc_offset
        @timeline.period_for(timestamp)
      end

      # (see DataTimezoneInfo#periods_for_local)
      def periods_for_local(local_timestamp)
        raise ArgumentError, 'local_timestamp must be specified' unless local_timestamp
        raise ArgumentError, 'local_timestamp must have an unspecified utc_offset' if local_timestamp.utc_offset
        @timeline.periods_for_local(local_timestamp)
      end

      # (see DataTimezoneInfo#transitions_up_to)
      def transitions_up_to(to_timestamp, from_timestamp = nil)
        raise ArgumentError, 'to_timestamp must be specified' unless to_timestamp
        raise ArgumentError, 'to_timestamp must have a specified utc_offset' unless to_timestamp.utc_offset

        if from_timestamp
          raise ArgumentError, 'from_timestamp must have a specified utc_offset' unless from_timestamp.utc_offset
          raise ArgumentError, 'to_timestamp must be greater than from_timestamp' if to_timestamp <= from_timestamp
        end

        result = historical_transitions_up_to(to_timestamp, from_timestamp)
        result.concat(@timeline.rule_transitions_up_to(to_timestamp, from_timestamp))
        result
      end

      private

      # Returns the transitions from the finite history that occur at or after
      # the optional from timestamp and before the to timestamp.
      #
      # @param to_timestamp [Timestamp] the exclusive upper bound.
      # @param from_timestamp [Timestamp, nil] the optional inclusive lower
      #   bound.
      # @return [Array<TimezoneTransition>] the matching historical
      #   transitions.
      def historical_transitions_up_to(to_timestamp, from_timestamp)
        if from_timestamp
          from_index = find_minimum_historical_transition {|t| transition_on_or_after_timestamp?(t, from_timestamp) }
          return [] unless from_index
        else
          from_index = 0
        end

        to_index = find_minimum_historical_transition {|t| transition_on_or_after_timestamp?(t, to_timestamp) }

        if to_index
          return [] if to_index < 1
          to_index -= 1
        else
          to_index = -1
        end

        from_index <= to_index ? @transitions[from_index..to_index].to_a : []
      end

      # Performs a binary search on the finite history to find the index of the
      # earliest transition satisfying the block.
      #
      # @return [Integer, nil] the index or nil if no transition satisfies
      #   the condition.
      def find_minimum_historical_transition(&block)
        if @transitions.respond_to?(:bsearch_index)
          @transitions.bsearch_index(&block)
        else
          low = 0
          high = @transitions.length
          satisfied = false

          while low < high
            mid = (low + high).div(2)
            if yield(@transitions[mid])
              satisfied = true
              high = mid
            else
              low = mid + 1
            end
          end

          satisfied ? low : nil
        end
      end

      # Determines if a transition occurs at or after a given Timestamp,
      # taking the Timestamp sub-second into consideration.
      #
      # @param transition [TimezoneTransition] the transition to compare.
      # @param timestamp [Timestamp] the timestamp to compare.
      # @return [Boolean] true if transition occurs at or after the timestamp.
      def transition_on_or_after_timestamp?(transition, timestamp)
        transition_timestamp_value = transition.timestamp_value
        timestamp_value = timestamp.value
        transition_timestamp_value > timestamp_value ||
          (transition_timestamp_value == timestamp_value && timestamp.sub_second == 0)
      end
    end
  end
end
