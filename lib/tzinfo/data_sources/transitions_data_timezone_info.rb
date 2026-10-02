# encoding: UTF-8
# frozen_string_literal: true

module TZInfo
  module DataSources
    # Represents a data time zone defined by a list of transitions that change
    # the locally observed time.
    class TransitionsDataTimezoneInfo < DataTimezoneInfo
      # @return [Array<TimezoneTransition>] the transitions that define this
      #   time zone in order of ascending timestamp.
      attr_reader :transitions

      # Initializes a new {TransitionsDataTimezoneInfo}.
      #
      # The passed in `identifier` instance will be frozen. A reference to the
      # passed in `Array` will be retained.
      #
      # The `transitions` `Array` must be sorted in order of ascending
      # timestamp. Each transition must have a
      # {TimezoneTransition#timestamp_value timestamp_value} that is greater
      # than the {TimezoneTransition#timestamp_value timestamp_value} of the
      # prior transition.
      #
      # @param identifier [String] the identifier of the time zone.
      # @param transitions [Array<TimezoneTransitions>] an `Array` of
      #   transitions that each indicate when a change occurs in the locally
      #   observed time.
      # @param annual_rules [AnnualRules] optional annual rules that continue
      #   indefinitely after the defined transitions.
      # @param annual_rules_start_year [Integer] the first year for which
      #   annual rule transitions have not already been included in
      #   `transitions`.
      # @raise [ArgumentError] if `identifier` is `nil`.
      # @raise [ArgumentError] if `transitions` is `nil`.
      # @raise [ArgumentError] if `transitions` is an empty `Array`.
      def initialize(identifier, transitions, annual_rules = nil, annual_rules_start_year = nil)
        super(identifier)
        raise ArgumentError, 'transitions must be specified' unless transitions
        raise ArgumentError, 'transitions must not be an empty Array' if transitions.empty?
        if annual_rules
          raise ArgumentError, 'annual_rules_start_year must be specified' unless annual_rules_start_year
          raise ArgumentError, 'annual_rules_start_year must be an Integer' unless annual_rules_start_year.kind_of?(Integer)
        end

        @transitions = transitions.freeze
        @annual_rules = annual_rules
        @annual_rules_start_year = annual_rules_start_year
      end

      # @return [AnnualRules, nil] the annual rules that continue indefinitely
      #   after the defined transitions, or `nil` if the transitions are finite.
      attr_reader :annual_rules

      # @return [Integer, nil] the first year for which transitions from
      #   {#annual_rules} should be generated, or `nil` if {#annual_rules} is
      #   not specified.
      attr_reader :annual_rules_start_year

      # (see DataTimezoneInfo#period_for)
      def period_for(timestamp)
        raise ArgumentError, 'timestamp must be specified' unless timestamp
        raise ArgumentError, 'timestamp must have a specified utc_offset' unless timestamp.utc_offset

        timestamp_value = timestamp.value

        if @annual_rules && timestamp_value >= last_transition_timestamp_value
          return period_for_annual_rules(timestamp_value, timestamp.sub_second)
        end

        index = find_minimum_transition {|t| t.timestamp_value >= timestamp_value }

        if index
          transition = @transitions[index]

          if transition.timestamp_value == timestamp_value
            # timestamp occurs within the second of the found transition, so is
            # the transition that starts the period.
            start_transition = transition
            end_transition = @transitions[index + 1]
          else
            # timestamp occurs before the second of the found transition, so is
            # the transition that ends the period.
            start_transition = index == 0 ? nil : @transitions[index - 1]
            end_transition = transition
          end
        else
          start_transition = @transitions.last
          end_transition = nil
        end

        TransitionsTimezonePeriod.new(start_transition, end_transition)
      end

      # (see DataTimezoneInfo#periods_for_local)
      def periods_for_local(local_timestamp)
        raise ArgumentError, 'local_timestamp must be specified' unless local_timestamp
        raise ArgumentError, 'local_timestamp must have an unspecified utc_offset' if local_timestamp.utc_offset

        local_timestamp_value = local_timestamp.value
        return periods_for_local_with_annual_rules(local_timestamp_value) if @annual_rules

        latest_possible_utc_value = local_timestamp_value + 86400
        earliest_possible_utc_value = local_timestamp_value - 86400

        # Find the index of the first transition that occurs after a latest
        # possible UTC representation of the local timestamp and then search
        # backwards until an earliest possible UTC representation.

        index = find_minimum_transition {|t| t.timestamp_value >= latest_possible_utc_value }

        # No transitions after latest_possible_utc_value, set to max index + 1
        # to search backwards including the period after the last transition
        index = @transitions.length unless index

        result = []

        index.downto(0) do |i|
          start_transition = i > 0 ? @transitions[i - 1] : nil
          end_transition = @transitions[i]
          offset = start_transition ? start_transition.offset : end_transition.previous_offset
          utc_timestamp_value = local_timestamp_value - offset.observed_utc_offset

          # It is not necessary to compare the sub-seconds because a timestamp
          # is in the period if is >= the start transition (sub-seconds would
          # make == become >) and if it is < the end transition (which
          # sub-seconds cannot affect).
          if (!start_transition || utc_timestamp_value >= start_transition.timestamp_value) && (!end_transition || utc_timestamp_value < end_transition.timestamp_value)
            result << TransitionsTimezonePeriod.new(start_transition, end_transition)
          elsif end_transition && end_transition.timestamp_value < earliest_possible_utc_value
            break
          end
        end

        result.reverse!
      end

      # (see DataTimezoneInfo#transitions_up_to)
      def transitions_up_to(to_timestamp, from_timestamp = nil)
        raise ArgumentError, 'to_timestamp must be specified' unless to_timestamp
        raise ArgumentError, 'to_timestamp must have a specified utc_offset' unless to_timestamp.utc_offset

        if from_timestamp
          raise ArgumentError, 'from_timestamp must have a specified utc_offset' unless from_timestamp.utc_offset
          raise ArgumentError, 'to_timestamp must be greater than from_timestamp' if to_timestamp <= from_timestamp
        end

        if from_timestamp
          from_index = find_minimum_transition {|t| transition_on_or_after_timestamp?(t, from_timestamp) }
          if @annual_rules
            return transitions_for_range(to_timestamp, from_timestamp, from_index)
          else
            return [] unless from_index
          end
        else
          from_index = 0
        end

        if @annual_rules
          return transitions_for_range(to_timestamp, from_timestamp, from_index)
        end

        to_index = find_minimum_transition {|t| transition_on_or_after_timestamp?(t, to_timestamp) }

        if to_index
          return [] if to_index < 1
          to_index -= 1
        else
          to_index = -1
        end

        @transitions[from_index..to_index] || []
      end

      private

      # Array#bsearch_index was added in Ruby 2.3.0. Use bsearch_index to find
      # transitions if it is available, otherwise use a Ruby implementation.
      if [].respond_to?(:bsearch_index)
        # Performs a binary search on {transitions} to find the index of the
        # earliest transition satisfying a condition.
        #
        # @yield [transition] the caller will be yielded to to test the search
        #   condition.
        # @yieldparam transition [TimezoneTransition] a {TimezoneTransition}
        #   instance from {transitions}.
        # @yieldreturn [Boolean] `true` for the earliest transition that
        #   satisfies the condition and return `true` for all subsequent
        #   transitions. In all other cases, the result of the block must be
        #   `false`.
        # @return [Integer] the index of the earliest transition safisfying
        #   the condition or `nil` if there are no such transitions.
        #
        # :nocov_no_array_bsearch_index:
        def find_minimum_transition(&block)
          @transitions.bsearch_index(&block)
        end
        # :nocov_no_array_bsearch_index:
      else
        # Performs a binary search on {transitions} to find the index of the
        # earliest transition satisfying a condition.
        #
        # @yield [transition] the caller will be yielded to to test the search
        #   condition.
        # @yieldparam transition [TimezoneTransition] a {TimezoneTransition}
        #   instance from {transitions}.
        # @yieldreturn [Boolean] `true` for the earliest transition that
        #   satisfies the condition and return `true` for all subsequent
        #   transitions. In all other cases, the result of the block must be
        #   `false`.
        # @return [Integer] the index of the earliest transition safisfying
        #   the condition or `nil` if there are no such transitions.
        #
        # :nocov_array_bsearch_index:
        def find_minimum_transition
          # A Ruby implementation of the find-minimum mode of Array#bsearch_index.
          low = 0
          high = @transitions.length
          satisfied = false

          while low < high do
            mid = (low + high).div(2)
            if yield @transitions[mid]
              satisfied = true
              high = mid
            else
              low = mid + 1
            end
          end

          satisfied ? low : nil
        end
        # :nocov_array_bsearch_index:
      end

      # Determines if a transition occurs at or after a given {Timestamp},
      # taking the {Timestamp#sub_second sub_second} into consideration.
      #
      # @param transition [TimezoneTransition] the transition to compare.
      # @param timestamp [Timestamp] the timestamp to compare.
      # @return [Boolean] `true` if `transition` occurs at or after `timestamp`,
      #   otherwise `false`.
      def transition_on_or_after_timestamp?(transition, timestamp)
        transition_timestamp_value = transition.timestamp_value
        timestamp_value = timestamp.value
        transition_timestamp_value > timestamp_value || transition_timestamp_value == timestamp_value && timestamp.sub_second == 0
      end

      def last_transition_timestamp_value
        @transitions.last.timestamp_value
      end

      def period_for_annual_rules(timestamp_value, sub_second)
        year = year_for_timestamp_value(timestamp_value)
        transitions = generated_transitions(year - 2, year + 3)
        index = transitions.find_index {|t| transition_on_or_after_value?(t, timestamp_value, sub_second) } || transitions.length

        if index == 0
          start_transition = @transitions.last
          end_transition = transitions.first
        elsif index == transitions.length
          start_transition = transitions.last
          end_transition = nil
        else
          start_transition = transitions[index - 1]
          end_transition = transitions[index]
        end

        TransitionsTimezonePeriod.new(start_transition, end_transition)
      end

      def periods_for_local_with_annual_rules(local_timestamp_value)
        latest_possible_utc_value = local_timestamp_value + 86400
        earliest_possible_utc_value = local_timestamp_value - 86400

        if latest_possible_utc_value < last_transition_timestamp_value
          return scan_periods_for_local(local_timestamp_value, latest_possible_utc_value,
            earliest_possible_utc_value, @transitions)
        end

        year = year_for_timestamp_value(local_timestamp_value)
        transitions = transitions_for_local_year(year)

        scan_periods_for_local(local_timestamp_value, latest_possible_utc_value,
          earliest_possible_utc_value, transitions)
      end

      def transitions_for_local_year(year)
        start_year = [@annual_rules_start_year - 2, year - 2].max
        generated = generated_transitions(start_year, year + 2)
        [@transitions.last] + generated
      end

      def scan_periods_for_local(local_timestamp_value, latest_possible_utc_value,
        earliest_possible_utc_value, transitions)

        index = transitions.find_index {|t| t.timestamp_value >= latest_possible_utc_value } || transitions.length
        result = []

        index.downto(0) do |i|
          start_transition = i > 0 ? transitions[i - 1] : nil
          end_transition = transitions[i]
          offset = start_transition ? start_transition.offset : end_transition.previous_offset
          utc_timestamp_value = local_timestamp_value - offset.observed_utc_offset

          if (!start_transition || utc_timestamp_value >= start_transition.timestamp_value) && (!end_transition || utc_timestamp_value < end_transition.timestamp_value)
            result << TransitionsTimezonePeriod.new(start_transition, end_transition)
          elsif end_transition && end_transition.timestamp_value < earliest_possible_utc_value
            break
          end
        end

        result.reverse!
      end

      def transitions_for_range(to_timestamp, from_timestamp, from_index)
        from_value = from_timestamp ? from_timestamp.value : nil
        if to_timestamp.value <= last_transition_timestamp_value
          return [] unless from_index

          to_index = find_minimum_transition {|t| transition_on_or_after_timestamp?(t, to_timestamp) }
          to_index = to_index ? to_index - 1 : -1
          return @transitions[from_index..to_index] || []
        end

        finite_result = from_index ? (@transitions[from_index..-2] || []) : @transitions[0...-1]

        observed_utc_offset = @transitions.last.offset.observed_utc_offset
        to_year = year_for_timestamp_value(to_timestamp.value, observed_utc_offset) + 1
        from_year = from_value ? year_for_timestamp_value(from_value, observed_utc_offset) - 1 : @annual_rules_start_year
        generated = generated_transitions(from_year, to_year)
        result = finite_result

        generated.each do |transition|
          break if transition_on_or_after_timestamp?(transition, to_timestamp)
          next if from_value && transition.timestamp_value < from_value
          result << transition
        end

        result
      end

      def generated_transitions(first_year, last_year)
        return [] if last_year < @annual_rules_start_year

        first_year = [first_year, @annual_rules_start_year].max
        result = []

        first_year.upto(last_year) do |year|
          @annual_rules.transitions(year).each do |transition|
            result << transition if transition.timestamp_value > last_transition_timestamp_value
          end
        end

        result
      end

      def transition_on_or_after_value?(transition, value, sub_second)
        transition_timestamp_value = transition.timestamp_value
        transition_timestamp_value > value || transition_timestamp_value == value && sub_second == 0
      end

      def year_for_timestamp_value(value, observed_utc_offset = 0)
        days = (value + observed_utc_offset).div(86400)
        z = days + 719468
        era = (z >= 0 ? z : z - 146096).div(146097)
        doe = z - era * 146097
        yoe = (doe - doe.div(1460) + doe.div(36524) - doe.div(146096)).div(365)
        y = yoe + era * 400
        doy = doe - (365 * yoe + yoe.div(4) - yoe.div(100))
        mp = (5 * doy + 2).div(153)
        y += mp.div(10)
        y
      end
    end
  end
end
