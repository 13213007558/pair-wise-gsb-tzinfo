# encoding: UTF-8
# frozen_string_literal: true

module TZInfo
  # The result of converting an interval of local times to UTC using
  # {Timezone#local_interval_to_utc}.
  #
  # Each interval is represented as a half-open Range of {Timestamp}
  # instances (the start is inclusive and the end is exclusive).
  class LocalIntervalConversion
    # @return [Array<Range>] half-open Ranges of UTC {Timestamp} instances
    #   covering the local interval that was converted. The Ranges are
    #   sorted, do not overlap and are merged where they would otherwise be
    #   adjacent. Every UTC time within these Ranges has an equivalent local
    #   time within the converted interval. No UTC time outside of these
    #   Ranges has an equivalent local time within the converted interval
    #   (according to the repeated option that was selected).
    attr_reader :utc_intervals

    # @return [Array<Range>] half-open Ranges of local {Timestamp} instances
    #   (without a UTC offset) within the converted interval that do not exist
    #   as local times (and therefore have no UTC equivalent). Such times
    #   occur when the clocks are put forward, for example, when transitioning
    #   to daylight savings time.
    attr_reader :gaps

    # @return [Array<Range>] half-open Ranges of local {Timestamp} instances
    #   (without a UTC offset) within the converted interval that occur more
    #   than once (having more than one UTC equivalent). Such times occur when
    #   the clocks are put back, for example, when transitioning from daylight
    #   savings time to standard time.
    attr_reader :repeated

    # Initializes a new {LocalIntervalConversion}.
    #
    # {LocalIntervalConversion} instances should not normally be constructed
    # manually. Use {Timezone#local_interval_to_utc} to convert an interval of
    # local times to UTC.
    #
    # @param utc_intervals [Array<Range>] the value of the {#utc_intervals}
    #   attribute.
    # @param gaps [Array<Range>] the value of the {#gaps} attribute.
    # @param repeated [Array<Range>] the value of the {#repeated} attribute.
    # @raise [ArgumentError] if any parameter is nil.
    def initialize(utc_intervals, gaps, repeated)
      raise ArgumentError, 'utc_intervals must be specified' unless utc_intervals
      raise ArgumentError, 'gaps must be specified' unless gaps
      raise ArgumentError, 'repeated must be specified' unless repeated

      @utc_intervals = utc_intervals.freeze
      @gaps = gaps.freeze
      @repeated = repeated.freeze
      freeze
    end

    # Determines if this {LocalIntervalConversion} is equal to another. The
    # two instances are equal if all their intervals are equal.
    #
    # @param other [Object] the instance to compare with.
    # @return [Boolean] true if other is a {LocalIntervalConversion} with
    #   equal {#utc_intervals}, {#gaps} and {#repeated} attributes, otherwise
    #   false.
    def ==(other)
      other.kind_of?(LocalIntervalConversion) &&
        utc_intervals == other.utc_intervals &&
        gaps == other.gaps &&
        repeated == other.repeated
    end
    alias eql? ==

    # @return [Integer] a hash based on the intervals.
    def hash
      [@utc_intervals, @gaps, @repeated].hash
    end
  end
end
