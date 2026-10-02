# encoding: UTF-8
# frozen_string_literal: true

module TZInfo
  # Represents time zones that are defined by rules that set out when
  # transitions occur.
  class DataTimezone < InfoTimezone
    # The maximum difference in seconds between local and UTC time in a
    # supported offset. The IANA Time Zone Database limits offsets to less
    # than 24 hours.
    LOCAL_TO_UTC_INTERVAL_OFFSET_LIMIT = 86_400
    private_constant :LOCAL_TO_UTC_INTERVAL_OFFSET_LIMIT

    # (see Timezone#period_for)
    def period_for(time)
      raise ArgumentError, 'time must be specified' unless time
      timestamp = Timestamp.for(time)
      raise ArgumentError, 'time must have a specified utc_offset' unless timestamp.utc_offset
      info.period_for(timestamp)
    end

    # (see Timezone#periods_for_local)
    def periods_for_local(local_time)
      raise ArgumentError, 'local_time must be specified' unless local_time
      info.periods_for_local(Timestamp.for(local_time, :ignore))
    end

    # (see Timezone#transitions_up_to)
    def transitions_up_to(to, from = nil)
      raise ArgumentError, 'to must be specified' unless to
      to_timestamp = Timestamp.for(to)
      from_timestamp = from && Timestamp.for(from)

      begin
        info.transitions_up_to(to_timestamp, from_timestamp)
      rescue ArgumentError => e
        raise ArgumentError, e.message.gsub('_timestamp', '')
      end
    end

    # Returns the canonical {Timezone} instance for this {DataTimezone}.
    #
    # For a {DataTimezone}, this is always `self`.
    #
    # @return [Timezone] `self`.
    def canonical_zone
      self
    end

    # (see Timezone#local_to_utc_interval)
    def local_to_utc_interval(local_start_time, local_end_time, occurrence = :all)
      raise ArgumentError, 'local_start_time must be specified' unless local_start_time
      raise ArgumentError, 'local_end_time must be specified' unless local_end_time

      local_start = Timestamp.for(local_start_time, :ignore)
      local_end = Timestamp.for(local_end_time, :ignore)
      raise ArgumentError, 'local_end_time must be later than local_start_time' if local_end <= local_start

      occurrence = normalize_interval_occurrence(occurrence)

      start_seconds = timestamp_seconds(local_start)
      end_seconds = timestamp_seconds(local_end)
      limit = LOCAL_TO_UTC_INTERVAL_OFFSET_LIMIT

      search_start = utc_timestamp_for_seconds(start_seconds - 2 * limit)
      search_end = utc_timestamp_for_seconds(end_seconds + 2 * limit)

      transitions = transitions_up_to(search_end, search_start)
      transition_boundaries = []
      transitions.each do |transition|
        transition_seconds = Rational(transition.timestamp_value, 1)
        transition_boundaries << transition_seconds + transition.previous_offset.observed_utc_offset
        transition_boundaries << transition_seconds + transition.offset.observed_utc_offset
      end
      periods = []

      if transitions.empty?
        periods << period_for(search_start)
      else
        first = transitions.first
        before_first = period_for_utc(utc_timestamp_for_seconds(timestamp_seconds(search_start) - 1))
        periods << TransitionsTimezonePeriod.new(before_first.start_transition, first)

        transitions.each_with_index do |transition, index|
          periods << TransitionsTimezonePeriod.new(transition, transitions[index + 1])
        end
      end

      ordered_periods = periods.sort {|a,b| period_start_seconds(a) <=> period_start_seconds(b)}

      candidate_segments = ordered_periods.each_with_index.map do |period, sequence|
        offset = period.observed_utc_offset
        period_start = period.starts_at
        period_end = period.ends_at

        wall_start = period_start ? timestamp_seconds(period_start) + offset : -Float::INFINITY
        wall_end = period_end ? timestamp_seconds(period_end) + offset : Float::INFINITY

        clipped_start = [start_seconds, wall_start].max
        clipped_end = [end_seconds, wall_end].min
        next nil if clipped_start >= clipped_end

        {
          period: period,
          offset: offset,
          local_start: clipped_start,
          local_end: clipped_end,
          utc_start: clipped_start - offset,
          utc_end: clipped_end - offset,
          sequence: sequence
        }
      end.compact

      unique_candidates = {}
      candidate_segments.each do |candidate|
        key = [candidate[:period], candidate[:local_start], candidate[:local_end]]
        unique_candidates[key] = candidate
      end

      segments = unique_candidates.values.sort_by {|segment| segment[:utc_start]}

      boundaries = [start_seconds, end_seconds]
      segments.each do |segment|
        boundaries << segment[:local_start]
        boundaries << segment[:local_end]
      end
      boundaries.concat(transition_boundaries)
      boundaries = boundaries.sort.uniq

      utc_intervals = []
      missing_local_intervals = []
      repeated_local_intervals = []

      boundaries.each_cons(2) do |boundary_start, boundary_end|
        active_segments = segments.select do |segment|
          segment[:local_start] <= boundary_start && segment[:local_end] >= boundary_end
        end
        if active_segments.empty?
          missing_start = [boundary_start, start_seconds].max
          missing_end = [boundary_end, end_seconds].min
          next if missing_start >= missing_end
          missing_local_intervals << local_interval(missing_start, missing_end, true)
          next
        end

        originally_ambiguous = active_segments.length > 1

        if originally_ambiguous
          repeated_local_intervals << local_interval(boundary_start, boundary_end, false)
        end

        selected_segments = if originally_ambiguous
          case occurrence
            when :all then active_segments.sort_by {|segment| segment[:utc_start] }
            when :first then [active_segments.min_by {|segment| segment[:utc_start] }]
            when :last then [active_segments.max_by {|segment| segment[:utc_start] }]
          end
        else
          active_segments
        end

        selected_segments.each do |segment|
          utc_intervals << TimezoneInterval.new(
            utc_timestamp_for_seconds(boundary_start - segment[:offset]),
            utc_timestamp_for_seconds(boundary_end - segment[:offset]),
            local_timestamp_for_seconds(boundary_start),
            local_timestamp_for_seconds(boundary_end),
            segment[:period],
            segment[:sequence])
        end
      end

      TimezoneIntervalConversion.new(
        merge_utc_intervals(utc_intervals),
        merge_local_intervals(missing_local_intervals),
        merge_local_intervals(repeated_local_intervals))
    end

    private

    # Normalizes the requested handling of repeated local time.
    #
    # @param occurrence [Symbol] the requested occurrence.
    # @return [Symbol] `:all`, `:first` or `:last`.
    # @raise [ArgumentError] if `occurrence` is not supported.
    def normalize_interval_occurrence(occurrence)
      aliases = {
        all: :all, both: :all, every: :all,
        first: :first, earliest: :first, earlier: :first, early: :first,
        last: :last, latest: :last, later: :last, late: :last
      }

      occurrence = occurrence.to_sym if occurrence.respond_to?(:to_str)
      result = aliases[occurrence]
      raise ArgumentError, 'occurrence must be :all, :first or :last' unless result
      result
    end

    # @param timestamp [Timestamp] a {Timestamp}.
    # @return [Rational] the timestamp as a number of seconds since 1970-01-01
    #   UTC, including rational sub-seconds.
    def timestamp_seconds(timestamp)
      Rational(timestamp.value, 1) + timestamp.sub_second
    end

    # @param seconds [Rational] a number of UTC seconds.
    # @return [Timestamp] a UTC {Timestamp}.
    def utc_timestamp_for_seconds(seconds)
      timestamp_for_seconds(seconds, :utc)
    end

    # @param seconds [Rational] a number of local seconds.
    # @return [Timestamp] a {Timestamp} with an unspecified offset.
    def local_timestamp_for_seconds(seconds)
      timestamp_for_seconds(seconds, nil)
    end

    # Constructs a {Timestamp} from rational seconds, retaining fractional
    # seconds without rounding.
    #
    # @param seconds [Rational] a number of seconds.
    # @param utc_offset [Object] `:utc` or `nil`.
    # @return [Timestamp] the constructed {Timestamp}.
    def timestamp_for_seconds(seconds, utc_offset)
      value = seconds.floor
      sub_second = seconds - value
      sub_second = 0 if sub_second == 0
      Timestamp.send(:new!, value, sub_second, utc_offset)
    end

    # @param period [TimezonePeriod] a period.
    # @return [Rational] the UTC start of a period, or negative infinity.
    def period_start_seconds(period)
      start = period.starts_at
      start ? timestamp_seconds(start) : -Float::INFINITY
    end

    # Creates a {LocalTimezoneInterval} from rational local seconds.
    #
    # @param start_seconds [Rational] the inclusive start.
    # @param end_seconds [Rational] the exclusive end.
    # @param missing [Boolean] whether the interval is missing.
    # @return [LocalTimezoneInterval] the interval.
    def local_interval(start_seconds, end_seconds, missing)
      LocalTimezoneInterval.new(
        local_timestamp_for_seconds(start_seconds),
        local_timestamp_for_seconds(end_seconds),
        missing)
    end

    # Merges adjacent elementary UTC intervals from the same period. Intervals
    # that meet at a transition are retained separately so that half-open
    # transition boundary ownership remains explicit.
    #
    # @param intervals [Array<TimezoneInterval>] ordered UTC intervals.
    # @return [Array<TimezoneInterval>] the merged intervals.
    def merge_utc_intervals(intervals)
      intervals = intervals.sort_by {|interval| [interval.utc_start, interval.utc_end] }
      result = []

      intervals.each do |interval|
        previous = result.last
        if previous && previous.utc_end == interval.utc_start && previous.segment_key == interval.segment_key
          result[-1] = TimezoneInterval.new(
            previous.utc_start,
            interval.utc_end,
            previous.local_start,
            interval.local_end,
            previous.period,
            previous.segment_key)
        else
          result << interval
        end
      end

      result
    end

    # Merges adjacent local intervals of the same kind.
    #
    # @param intervals [Array<LocalTimezoneInterval>] ordered local intervals.
    # @return [Array<LocalTimezoneInterval>] the merged intervals.
    def merge_local_intervals(intervals)
      result = []

      intervals.each do |interval|
        previous = result.last
        if previous && previous.local_end == interval.local_start
          result[-1] = LocalTimezoneInterval.new(
            previous.local_start,
            interval.local_end,
            interval.missing?)
        else
          result << interval
        end
      end

      result
    end
  end
end
