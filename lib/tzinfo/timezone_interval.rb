# encoding: UTF-8
# frozen_string_literal: true

module TZInfo
  # Represents a half-open interval of time, containing the start time but
  # not the end time. Intervals returned by {Timezone#local_to_utc_interval}
  # retain rational sub-second precision.
  class TimezoneInterval
    include Comparable

    # @return [Timestamp] the inclusive UTC start of the interval, or `nil`
    #   for a local-only interval that does not have a UTC representation.
    attr_reader :utc_start
    alias start_at utc_start
    alias starts_at utc_start

    # @return [Timestamp] the exclusive UTC end of the interval, or `nil`
    #   for a local-only interval that does not have a UTC representation.
    attr_reader :utc_end
    alias end_at utc_end
    alias ends_at utc_end
    alias finish utc_end

    # @return [Timestamp] the inclusive local wall-clock start of the
    #   interval, with an unspecified UTC offset.
    attr_reader :local_start

    # @return [Timestamp] the exclusive local wall-clock end of the interval,
    #   with an unspecified UTC offset.
    attr_reader :local_end

    # @return [Array<TimezonePeriod>] the {TimezonePeriod TimezonePeriods}
    #   observed by this interval. A contiguous UTC interval can cross
    #   transitions.
    attr_reader :periods

    # Initializes a new {TimezoneInterval}.
    #
    # {TimezoneInterval} instances should not normally be constructed
    # directly. Use {Timezone#local_to_utc_interval}.
    #
    # @param utc_start [Timestamp] the inclusive UTC start.
    # @param utc_end [Timestamp] the exclusive UTC end.
    # @param local_start [Timestamp] the inclusive local start.
    # @param local_end [Timestamp] the exclusive local end.
    # @param period [TimezonePeriod, Array<TimezonePeriod>] the observed
    #   period or periods.
    def initialize(utc_start, utc_end, local_start, local_end, period = nil, segment_key = nil)
      initialize_interval(utc_start, utc_end, local_start, local_end, period, segment_key)
      freeze
    end

    # Initializes the interval attributes without freezing.
    #
    # @param utc_start [Timestamp] the inclusive UTC start.
    # @param utc_end [Timestamp] the exclusive UTC end.
    # @param local_start [Timestamp] the inclusive local start.
    # @param local_end [Timestamp] the exclusive local end.
    # @param period [TimezonePeriod, Array<TimezonePeriod>] the observed
    #   period or periods.
    #
    # @private
    def initialize_interval(utc_start, utc_end, local_start, local_end, period = nil, segment_key = nil)
      @utc_start = utc_start
      @utc_end = utc_end
      @local_start = local_start
      @local_end = local_end
      @periods = period.nil? ? [] : Array(period)
      @segment_key = segment_key
    end

    # @return [TimezonePeriod] the first {TimezonePeriod} observed by this
    #   interval, or `nil` for a local-only interval.
    def period
      @periods.first
    end

    # @return [Object] an internal key identifying one occurrence of a period.
    #
    # @!visibility private
    def segment_key
      @segment_key
    end

    # @return [Boolean] `true` if this interval represents local wall-clock
    #   times with no corresponding UTC time, otherwise `false`.
    def local_only?
      !@utc_start
    end

    # Determines whether a UTC time is contained in this interval. The start
    # is included and the end is excluded.
    #
    # @param time [Object] a `Time`, `DateTime` or {Timestamp} with a
    #   specified UTC offset.
    # @return [Boolean] `true` if `time` is in the interval, otherwise
    #   `false`.
    def include_utc?(time)
      return false unless @utc_start
      timestamp = Timestamp.for(time)
      timestamp >= @utc_start && timestamp < @utc_end
    end

    # @return [Range<Timestamp>] the half-open UTC interval as a `Range`.
    def utc_range
      @utc_start...@utc_end
    end
    alias range utc_range

    # @return [Range<Timestamp>] the half-open local wall-clock interval as a
    #   `Range`.
    def local_range
      @local_start...@local_end
    end

    # @return [Numeric] the length of the UTC interval in seconds.
    def utc_duration
      duration(@utc_start, @utc_end)
    end

    # @return [Numeric] the length of the local interval in seconds.
    def local_duration
      duration(@local_start, @local_end)
    end

    # Compares this interval with another by UTC start and end time.
    #
    # @param other [Object] the interval to compare with.
    # @return [Integer] `-1`, `0` or `1` depending on whether this interval
    #   is before, equal to or after `other`.
    def <=>(other)
      return nil unless other.kind_of?(TimezoneInterval)
      [@utc_start, @utc_end, @local_start, @local_end] <=>
        [other.utc_start, other.utc_end, other.local_start, other.local_end]
    end

    # @param other [Object] the instance to compare with.
    # @return [Boolean] `true` if `other` is a {TimezoneInterval} with the
    #   same bounds and period, otherwise `false`.
    def ==(other)
      other.kind_of?(TimezoneInterval) &&
        @utc_start == other.utc_start && @utc_end == other.utc_end &&
        @local_start == other.local_start && @local_end == other.local_end &&
        @periods == other.periods
    end
    alias eql? ==

    # @return [Integer] a hash based on the bounds and period.
    def hash
      [@utc_start, @utc_end, @local_start, @local_end, @periods].hash
    end

    # @return [String] the internal object state as a programmer-readable
    #   `String`.
    def inspect
      "#<#{self.class}: #{@local_start}...#{@local_end} local -> #{@utc_start ? "#{@utc_start}...#{@utc_end} UTC" : 'no UTC'}>"
    end

    private

    # @param start [Timestamp] the inclusive start.
    # @param finish [Timestamp] the exclusive end.
    # @return [Numeric] the difference between two timestamps in seconds.
    def duration(start, finish)
      finish.value - start.value + finish.sub_second - start.sub_second
    end
  end

  # Represents a local wall-clock interval that is either missing (the clocks
  # jumped over it) or repeated (the clocks returned to it).
  class LocalTimezoneInterval < TimezoneInterval
    # Initializes a new {LocalTimezoneInterval}.
    #
    # @param local_start [Timestamp] the inclusive local start.
    # @param local_end [Timestamp] the exclusive local end.
    # @param missing [Boolean] `true` for a missing interval, `false` for a
    #   repeated interval.
    def initialize(local_start, local_end, missing)
      initialize_interval(nil, nil, local_start, local_end, nil)
      @missing = missing
      freeze
    end

    # @return [Boolean] `true` if the local interval was skipped by a forward
    #   clock change, otherwise `false`.
    def missing?
      @missing
    end

    # @return [Boolean] `true` if the local interval occurs more than once due
    #   to a backward clock change, otherwise `false`.
    def repeated?
      !@missing
    end
    alias ambiguous? repeated?
  end

  # The result returned by {Timezone#local_to_utc_interval}. UTC intervals are
  # always ordered, half-open and mutually non-overlapping.
  class TimezoneIntervalConversion
    include Enumerable

    # @return [Array<TimezoneInterval>] the UTC intervals covered by the
    #   requested local interval.
    attr_reader :utc_intervals
    alias utc_segments utc_intervals
    alias segments utc_intervals

    # @return [Array<LocalTimezoneInterval>] local intervals skipped by
    #   forward clock changes.
    attr_reader :missing_local_intervals

    # @return [Array<LocalTimezoneInterval>] local intervals that occur more
    #   than once due to backward clock changes.
    attr_reader :repeated_local_intervals

    # Initializes a new {TimezoneIntervalConversion}.
    #
    # {TimezoneIntervalConversion} instances should not normally be
    # constructed directly. Use {Timezone#local_to_utc_interval}.
    #
    # @param utc_intervals [Array<TimezoneInterval>] the UTC intervals.
    # @param missing_local_intervals [Array<LocalTimezoneInterval>] missing
    #   local intervals.
    # @param repeated_local_intervals [Array<LocalTimezoneInterval>] repeated
    #   local intervals.
    def initialize(utc_intervals, missing_local_intervals, repeated_local_intervals)
      @utc_intervals = utc_intervals.freeze
      @missing_local_intervals = missing_local_intervals.freeze
      @repeated_local_intervals = repeated_local_intervals.freeze
      freeze
    end

    # Yields each UTC interval.
    #
    # @yield [interval] each UTC interval.
    # @yieldparam interval [TimezoneInterval] a UTC interval.
    # @return [Enumerator] an {Enumerator} when no block is given.
    def each(&block)
      @utc_intervals.each(&block)
    end

    # @return [Array<TimezoneInterval>] an alias for {#utc_intervals}.
    def to_a
      @utc_intervals.dup
    end

    # @return [Boolean] `true` if the requested local interval contained
    #   skipped local time, otherwise `false`.
    def missing?
      !@missing_local_intervals.empty?
    end

    # @return [Boolean] `true` if the requested local interval contained
    #   repeated local time, otherwise `false`.
    def repeated?
      !@repeated_local_intervals.empty?
    end
    alias ambiguous? repeated?

    # @return [Array<LocalTimezoneInterval>] an alias for
    #   {#missing_local_intervals}.
    def nonexistent_local_intervals
      @missing_local_intervals
    end
    alias skipped_local_intervals nonexistent_local_intervals

    # @return [Array<LocalTimezoneInterval>] an alias for
    #   {#repeated_local_intervals}.
    def ambiguous_local_intervals
      @repeated_local_intervals
    end

    # @param other [Object] the instance to compare with.
    # @return [Boolean] `true` if `other` contains the same intervals, otherwise
    #   `false`.
    def ==(other)
      other.kind_of?(TimezoneIntervalConversion) &&
        @utc_intervals == other.utc_intervals &&
        @missing_local_intervals == other.missing_local_intervals &&
        @repeated_local_intervals == other.repeated_local_intervals
    end

    # @return [String] the internal object state as a programmer-readable
    #   `String`.
    def inspect
      "#<#{self.class}: #{@utc_intervals.length} UTC interval(s), #{@missing_local_intervals.length} missing, #{@repeated_local_intervals.length} repeated>"
    end
  end
end
