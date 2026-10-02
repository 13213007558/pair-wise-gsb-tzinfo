# encoding: UTF-8
# frozen_string_literal: true

module TZInfo
  # Joins a finite, pre-computed history of {TimezoneTransition} instances to
  # an {AnnualRules} instance defining transitions that repeat annually in all
  # subsequent years. Rule transitions are generated on demand for just the
  # years required to answer a query, so memory use does not grow with the
  # furthest year queried.
  #
  # @private
  class AnnualRulesTimeline #:nodoc:
    # The number of years either side of a queried year for which rule
    # transitions are generated. A margin of one year covers rule times that
    # are negative or past 24:00 (moving a transition into an adjacent year)
    # and southern hemisphere rules that cross the calendar year boundary.
    YEAR_MARGIN = 1
    private_constant :YEAR_MARGIN

    # The maximum number of years worth of generated transitions to retain.
    CACHE_SIZE = (2 * YEAR_MARGIN) + 1
    private_constant :CACHE_SIZE

    # @return [Array<TimezoneTransition>] the finite history of transitions in
    #   ascending order. The final transition is the point at which the annual
    #   rules take effect.
    attr_reader :transitions

    # Initializes a new {AnnualRulesTimeline}.
    #
    # @param transitions [Array<TimezoneTransition>] the finite history of
    #   transitions in ascending order.
    # @param annual_rules [AnnualRules] the rules defining transitions for
    #   subsequent years.
    # @param rule_start_year [Integer] the local calendar year in which
    #   appended rule transitions begin (the year of the final historical
    #   transition when joining to a history).
    # @param seam_timestamp_value [Integer, nil] the UTC timestamp value at
    #   which rule transitions take over from the finite history. Defaults to
    #   the timestamp of the final transition.
    def initialize(transitions, annual_rules, rule_start_year, seam_timestamp_value = nil)
      raise ArgumentError, 'transitions must not be empty' if transitions.empty?
      @transitions = transitions.freeze
      @annual_rules = annual_rules
      @rule_start_year = rule_start_year
      @seam_timestamp_value = seam_timestamp_value.nil? ? last_history.timestamp_value : seam_timestamp_value
      @rule_transitions_by_year = {}
    end

    # Returns the {TransitionsTimezonePeriod} observed at the given UTC
    # {Timestamp}.
    #
    # @param timestamp [Timestamp] a {Timestamp} with a specified UTC offset.
    # @return [TransitionsTimezonePeriod] the period observed at +timestamp+.
    def period_for(timestamp)
      timestamp_value = timestamp.value
      index = find_minimum_history_transition {|t| t.timestamp_value >= timestamp_value }

      if index
        transition = @transitions[index]

        if transition.timestamp_value == timestamp_value
          start_transition = transition
          end_transition = transition_at_or_after(index + 1, timestamp_value)
        else
          start_transition = index == 0 ? nil : @transitions[index - 1]
          end_transition = transition
        end
      else
        start_transition, end_transition = period_for_rule_value(timestamp_value)
      end

      TransitionsTimezonePeriod.new(start_transition, end_transition)
    end

    # Returns an Array of {TransitionsTimezonePeriod} instances that could be
    # observed at the given local {Timestamp}.
    #
    # @param local_timestamp [Timestamp] a {Timestamp} with an unspecified UTC
    #   offset.
    # @return [Array<TransitionsTimezonePeriod>] the matching periods, ordered
    #   by increasing UTC start time.
    def periods_for_local(local_timestamp)
      local_timestamp_value = local_timestamp.value
      latest_possible_utc_value = local_timestamp_value + 86400
      earliest_possible_utc_value = local_timestamp_value - 86400

      result = []

      # Search the finite history first, mirroring
      # TransitionsDataTimezoneInfo#periods_for_local. Only periods ending at
      # or before the seam belong to the finite history; the period starting at
      # the seam is bounded by rule-generated transitions and handled below.
      history_index = find_minimum_history_transition {|t| t.timestamp_value >= latest_possible_utc_value }
      history_index = @transitions.length unless history_index

      # The period that ends at (and the open period after) the final
      # historical transition is resolved by the rule logic below.
      last_history_index = @transitions.length - 1
      history_index = last_history_index if history_index > last_history_index

      history_index.downto(0) do |i|
        next if i == last_history_index

        start_transition = i > 0 ? @transitions[i - 1] : nil
        end_transition = @transitions[i]

        offset = if start_transition
          start_transition.offset
        else
          end_transition.previous_offset
        end
        utc_timestamp_value = local_timestamp_value - offset.observed_utc_offset

        if (!start_transition || utc_timestamp_value >= start_transition.timestamp_value) &&
             utc_timestamp_value < end_transition.timestamp_value
          result << TransitionsTimezonePeriod.new(start_transition, end_transition)
        elsif end_transition.timestamp_value < earliest_possible_utc_value
          break
        end
      end

      # If the local time falls after the finite history, find the
      # rule-generated transitions that could bound a period containing it.
      # Mirroring the finite history search, this starts from the first
      # transition at or after the latest possible UTC representation and
      # searches backwards. To locate that transition without materializing
      # every intervening year, generate only the years covering the window
      # (plus a one year margin), then also include the final rule transition
      # preceding the window (which ends the period that overlaps the window).
      window = rule_transitions_in_range(earliest_possible_utc_value, latest_possible_utc_value)

      # The period containing the local time ends at the last transition at or
      # before its latest possible UTC representation (which may be years after
      # the seam but outside the +/- 1 day window). Find it by binary search
      # over years, then combine it with the bounds inside the window.
      ending = rule_transition_preceding(latest_possible_utc_value + 1)
      rule_bounds = (ending && (window.empty? || ending.timestamp_value < window.first.timestamp_value) ? [ending] : [])
      rule_bounds.concat(window)
      rule_bounds.uniq! {|t| t.timestamp_value }

      # Each consecutive pair of bounds defines a period. For the first bound
      # the period starts at the seam, but the observed offset is the bound's
      # previous_offset (which describes the offset throughout the gap, even
      # when it differs from the seam offset). Subsequent periods take their
      # offset from their start transition.
      rule_bounds.each_with_index do |end_transition, i|
        start_transition = i == 0 ? last_history : rule_bounds[i - 1]
        offset = i == 0 ? end_transition.previous_offset : start_transition.offset
        utc_timestamp_value = local_timestamp_value - offset.observed_utc_offset

        next unless utc_timestamp_value >= start_transition.timestamp_value &&
          utc_timestamp_value < end_transition.timestamp_value

        if i == 0 && offset != start_transition.offset
          start_transition = TimezoneTransition.new(
            offset, start_transition.previous_offset, start_transition.timestamp_value)
        end

        result << TransitionsTimezonePeriod.new(start_transition, end_transition)
      end

      # Open-ended period after the final rule bound.
      if (last_bound = rule_bounds.last)
        utc_timestamp_value = local_timestamp_value - last_bound.offset.observed_utc_offset
        if utc_timestamp_value >= last_bound.timestamp_value
          result << TransitionsTimezonePeriod.new(last_bound, nil)
        end
      else
        utc_timestamp_value = local_timestamp_value - last_history.offset.observed_utc_offset
        if utc_timestamp_value >= history_end_value
          result << TransitionsTimezonePeriod.new(last_history, nil)
        end
      end

      result.reverse!
    end

    # Returns the rule-generated transitions occurring at or after
    # +from_timestamp+ and before +to_timestamp+.
    #
    # @param to_timestamp [Timestamp] a {Timestamp} with a specified UTC
    #   offset (exclusive).
    # @param from_timestamp [Timestamp] an optional {Timestamp} with a
    #   specified UTC offset (inclusive).
    # @return [Array<TimezoneTransition>] the matching transitions.
    def rule_transitions_up_to(to_timestamp, from_timestamp)
      minimum_value = from_timestamp ? from_timestamp.value : history_end_value
      maximum_value = to_timestamp.value

      rule_transitions_in_range(minimum_value, maximum_value).find_all do |transition|
        (!from_timestamp || transition_on_or_after_timestamp?(transition, from_timestamp)) &&
          !transition_on_or_after_timestamp?(transition, to_timestamp)
      end
    end

    private

    # @return [TimezoneTransition] the final historical transition.
    def last_history
      @transitions.last
    end

    # @return [Integer] the UTC timestamp value at which the rules take over.
    def history_end_value
      @seam_timestamp_value
    end

    # Performs a binary search on the finite history to find the index of the
    # earliest transition for which the block returns true.
    #
    # @return [Integer, nil] the index or nil if no transition satisfies the
    #   condition.
    def find_minimum_history_transition
      low = 0
      high = @transitions.length
      satisfied = false

      while low < high
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

    # Returns the transition at the given historical index if it exists, or
    # the first rule-generated transition strictly after the given timestamp
    # value otherwise.
    #
    # @param index [Integer] the candidate historical index.
    # @param timestamp_value [Integer] the UTC value the transition must be
    #   after.
    # @return [TimezoneTransition, nil] the ending transition.
    def transition_at_or_after(index, timestamp_value)
      if index < @transitions.length
        @transitions[index]
      else
        rule_transition_following(timestamp_value)
      end
    end

    # Finds the period containing a UTC value that falls after the finite
    # history using rule-generated transitions.
    #
    # @param timestamp_value [Integer] a UTC timestamp in seconds since epoch.
    # @return [Array] a two element Array containing the start and end
    #   transitions (either may be nil if unbounded).
    def period_for_rule_value(timestamp_value)
      # Find the year containing the period using the fact that rule
      # transitions are annually recurring and ordered. Generate candidates
      # for the queried year and adjacent years only.
      year = utc_year(timestamp_value)

      candidates = rule_transitions_for_year(year) + rule_transitions_for_year(year - 1)
      candidates.select! {|t| t.timestamp_value > history_end_value }
      candidates.sort! {|a, b| a.timestamp_value <=> b.timestamp_value }

      candidates.each_with_index do |transition, index|
        value = transition.timestamp_value

        if value > timestamp_value
          previous = index == 0 ? rule_transition_preceding(value) : candidates[index - 1]
          previous ||= last_history
          return [previous, transition]
        elsif value == timestamp_value
          following = candidates[index + 1] || rule_transition_following(value)
          return [transition, following]
        end
      end

      [candidates.last || rule_transition_preceding(timestamp_value + 1) || last_history, nil]
    end

    # Returns the first rule-generated transition strictly after the given UTC
    # timestamp value, examining only the queried year and the following one
    # (sufficient because rule times move by at most a day and southern
    # hemisphere rules cross the year boundary).
    #
    # @param value [Integer] a UTC timestamp in seconds since epoch.
    # @return [TimezoneTransition, nil] the following rule transition.
    def rule_transition_following(value)
      year = utc_year(value)

      [year, year + 1].each do |candidate_year|
        next if candidate_year < @rule_start_year

        transition = rule_transitions_for_year(candidate_year).find do |t|
          t.timestamp_value > history_end_value && t.timestamp_value > value
        end
        return transition if transition
      end

      nil
    end

    # Returns rule-generated transitions (in ascending UTC order) whose UTC
    # timestamp values fall within the inclusive range given. Transitions at or
    # before the end of the finite history are never returned.
    #
    # @param minimum_value [Integer] the inclusive lower bound.
    # @param maximum_value [Integer] the inclusive upper bound.
    # @return [Array<TimezoneTransition>] the matching transitions.
    def rule_transitions_in_range(minimum_value, maximum_value)
      from_year = utc_year(minimum_value) - YEAR_MARGIN
      to_year = utc_year(maximum_value) + YEAR_MARGIN

      result = []

      from_year.upto(to_year) do |year|
        next if year < @rule_start_year

        rule_transitions_for_year(year).each do |transition|
          value = transition.timestamp_value
          result << transition if value > history_end_value && value >= minimum_value && value <= maximum_value
        end
      end

      result.sort! {|a, b| a.timestamp_value <=> b.timestamp_value }
      result
    end

    # Returns the last rule-generated transition that occurs strictly before
    # the given UTC timestamp value. The search first exponentially probes
    # backwards to bracket the year containing the result, then binary
    # searches that range. Only a logarithmic number of years are generated.
    #
    # @param value [Integer] the UTC timestamp value to search before.
    # @return [TimezoneTransition, nil] the preceding rule transition or nil if
    #   none exists after the finite history.
    def rule_transition_preceding(value)
      queried_year = utc_year(value)

      matches = lambda do |year|
        next [] if year < @rule_start_year

        @annual_rules.transitions(year).find_all do |transition|
          transition.timestamp_value > history_end_value && transition.timestamp_value < value
        end
      end

      # Look in the queried year and the preceding one. Rule times can move a
      # transition into the previous day (and southern hemisphere rules cross
      # the year boundary), so the preceding year is required to catch the
      # last transition before value.
      [queried_year, queried_year - 1].each do |year|
        transition = matches.call(year).last
        return transition if transition
      end

      # The latest transition before value is more than a year earlier (the
      # local time lies well after the finite history but between annual
      # transitions). Exponentially probe backwards to bracket the year, then
      # binary search for the latest year containing such a transition.
      high = queried_year - 2
      step = 2
      low_boundary = queried_year - 1

      while high >= @rule_start_year && (found = matches.call(high)).empty?
        low_boundary = high
        high -= step
        step *= 2
      end

      return nil if high < @rule_start_year

      low = high
      high = low_boundary

      while low + 1 < high
        mid = low + ((high - low).div(2))
        if matches.call(mid).empty?
          high = mid
        else
          low = mid
        end
      end

      matches.call(low).last
    end

    # Returns the rule-generated transitions for a given year (ordered by
    # ascending UTC time). Results are memoized with at most CACHE_SIZE years
    # retained, so memory use is bounded independently of the years queried.
    #
    # @param year [Integer] the rule year.
    # @return [Array<TimezoneTransition>] the transitions for the year.
    def rule_transitions_for_year(year)
      cached = @rule_transitions_by_year[year]
      return cached if cached

      transitions = @annual_rules.transitions(year)
      transitions = transitions.freeze

      if @rule_transitions_by_year.length >= CACHE_SIZE
        @rule_transitions_by_year.delete(@rule_transitions_by_year.keys.first)
      end

      @rule_transitions_by_year[year] = transitions
    end

    # Determines if a transition occurs at or after a given Timestamp,
    # taking the Timestamp sub-second into consideration.
    #
    # @param transition [TimezoneTransition] the transition to compare.
    # @param timestamp [Timestamp] the timestamp to compare.
    # @return [Boolean] true if the transition occurs at or after the
    #   timestamp.
    def transition_on_or_after_timestamp?(transition, timestamp)
      transition_timestamp_value = transition.timestamp_value
      timestamp_value = timestamp.value
      transition_timestamp_value > timestamp_value ||
        (transition_timestamp_value == timestamp_value && timestamp.sub_second == 0)
    end

    # Returns the proleptic Gregorian calendar year containing the given UTC
    # timestamp value using pure integer arithmetic, so results are not
    # limited by the range of the platform's Time class.
    #
    # @param timestamp_value [Integer] a UTC timestamp in seconds since epoch.
    # @return [Integer] the calendar year of the timestamp value.
    def utc_year(timestamp_value)
      days = timestamp_value.div(86400)

      # Inverse of the days_from_civil algorithm used by Timestamp.create.
      days += 719468
      era = (days >= 0 ? days : days - 146096).div(146097)
      day_of_era = days - era * 146097
      year_of_era = (day_of_era - day_of_era.div(1460) + day_of_era.div(36524) - day_of_era.div(146096)).div(365)
      year_of_era + era * 400
    end
  end
  private_constant :AnnualRulesTimeline
end
