# encoding: UTF-8
# frozen_string_literal: true

module TZInfo
  # The result of comparing the definition of a time zone in two {DataSource}
  # instances over a given window of UTC time.
  #
  # {DataSourceComparison} instances are returned by
  # {DataSourceComparer#compare}. They are not normally constructed manually.
  class DataSourceComparison
    # A half-open interval of UTC time over which the observed offset, DST
    # status or abbreviation of the compared time zone differs between the
    # two data sources.
    #
    # Segment boundaries always coincide with the start of the comparison
    # window, the end of the comparison window, or a transition in one of the
    # two data sources. The UTC offset, DST status and abbreviation observed
    # by each source is constant within a segment.
    class UtcSegment
      # @return [Timestamp] the start of the segment as a UTC {Timestamp}
      #   (inclusive).
      attr_reader :starts_at

      # @return [Timestamp] the end of the segment as a UTC {Timestamp}
      #   (exclusive).
      attr_reader :ends_at

      # @return [TimezonePeriod] the {TimezonePeriod} observed by the first
      #   data source for the duration of the segment.
      attr_reader :first_period

      # @return [TimezonePeriod] the {TimezonePeriod} observed by the second
      #   data source for the duration of the segment.
      attr_reader :second_period

      # Initializes a new {UtcSegment}.
      #
      # @param starts_at [Timestamp] the start of the segment as a UTC
      #   {Timestamp} (inclusive).
      # @param ends_at [Timestamp] the end of the segment as a UTC {Timestamp}
      #   (exclusive).
      # @param first_period [TimezonePeriod] the {TimezonePeriod} observed by
      #   the first data source for the duration of the segment.
      # @param second_period [TimezonePeriod] the {TimezonePeriod} observed by
      #   the second data source for the duration of the segment.
      def initialize(starts_at, ends_at, first_period, second_period)
        @starts_at = starts_at
        @ends_at = ends_at
        @first_period = first_period
        @second_period = second_period
        freeze
      end

      # @return [Boolean] whether the observed UTC offset differs between the
      #   two data sources over this segment.
      def offset_changed?
        first_period.observed_utc_offset != second_period.observed_utc_offset
      end

      # @return [Boolean] whether daylight savings time is observed by one
      #   data source but not the other over this segment.
      def dst_changed?
        first_period.dst? != second_period.dst?
      end

      # @return [Boolean] whether the abbreviation used to identify the
      #   observed offset differs between the two data sources over this
      #   segment.
      def abbreviation_changed?
        first_period.abbreviation != second_period.abbreviation
      end

      # @return [Boolean] whether the observed offset, DST status or
      #   abbreviation differs between the two data sources over this
      #   segment.
      def changed?
        offset_changed? || dst_changed? || abbreviation_changed?
      end
    end

    # A maximal continuous interval of UTC time over which the observed
    # offset, DST status or abbreviation of the compared time zone differs
    # between the two data sources.
    #
    # A single {UtcDifference} can span multiple transitions (for example,
    # when the two data sources switch between offsets at different instants,
    # or one source reaches the new offset via a different sequence of
    # transitions). The individual transitions that make up the difference
    # are available as {UtcSegment} instances from {#segments}.
    class UtcDifference
      # @return [Timestamp] the start of the difference as a UTC {Timestamp}
      #   (inclusive).
      attr_reader :starts_at

      # @return [Timestamp] the end of the difference as a UTC {Timestamp}
      #   (exclusive).
      attr_reader :ends_at

      # @return [Array<UtcSegment>] the minimal {UtcSegment} instances that
      #   make up this difference, in ascending order. The {Timestamp}
      #   boundaries of each segment can be passed to
      #   {Timezone#period_for_utc} on {DataSourceComparison#first_timezone}
      #   and {DataSourceComparison#second_timezone} to verify the reported
      #   difference against either data source.
      attr_reader :segments

      # Initializes a new {UtcDifference}.
      #
      # @param segments [Array<UtcSegment>] the {UtcSegment} instances that
      #   make up the difference. Must not be empty.
      # @raise [ArgumentError] if `segments` is empty.
      def initialize(segments)
        raise ArgumentError, 'segments must not be empty' if segments.empty?
        @segments = segments.freeze
        @starts_at = segments.first.starts_at
        @ends_at = segments.last.ends_at
        @offset_changed = @segments.any? {|s| s.offset_changed? }
        @dst_changed = @segments.any? {|s| s.dst_changed? }
        @abbreviation_changed = @segments.any? {|s| s.abbreviation_changed? }
        freeze
      end

      # @return [Boolean] whether the observed UTC offset differs between the
      #   two data sources over any part of this difference.
      def offset_changed?
        @offset_changed
      end

      # @return [Boolean] whether daylight savings time is observed by one
      #   data source but not the other over any part of this difference.
      def dst_changed?
        @dst_changed
      end

      # @return [Boolean] whether the abbreviation used to identify the
      #   observed offset differs between the two data sources over any part
      #   of this difference.
      def abbreviation_changed?
        @abbreviation_changed
      end
    end

    # A half-open interval of local time whose multiplicity (the number of
    # UTC times it corresponds to) differs between the two data sources.
    #
    # Local times that do not occur (because they fall within a gap created
    # by a transition) have a multiplicity of 0. Local times that occur once
    # have a multiplicity of 1. Local times that occur more than once
    # (because they fall within an overlap created by a transition) have a
    # multiplicity of 2 or more.
    class LocalTimeChange
      # @return [Timestamp] the start of the change as a local {Timestamp}
      #   with an unspecified UTC offset (inclusive).
      attr_reader :local_starts_at

      # @return [Timestamp] the end of the change as a local {Timestamp} with
      #   an unspecified UTC offset (exclusive).
      attr_reader :local_ends_at

      # @return [Integer] the multiplicity of the local time interval
      #   according to the first data source.
      attr_reader :first_multiplicity

      # @return [Integer] the multiplicity of the local time interval
      #   according to the second data source.
      attr_reader :second_multiplicity

      # Initializes a new {LocalTimeChange}.
      #
      # @param local_starts_at [Timestamp] the start of the change as a local
      #   {Timestamp} with an unspecified UTC offset (inclusive).
      # @param local_ends_at [Timestamp] the end of the change as a local
      #   {Timestamp} with an unspecified UTC offset (exclusive).
      # @param first_multiplicity [Integer] the multiplicity of the local
      #   time interval according to the first data source.
      # @param second_multiplicity [Integer] the multiplicity of the local
      #   time interval according to the second data source.
      def initialize(local_starts_at, local_ends_at, first_multiplicity, second_multiplicity)
        @local_starts_at = local_starts_at
        @local_ends_at = local_ends_at
        @first_multiplicity = first_multiplicity
        @second_multiplicity = second_multiplicity
        freeze
      end

      # @return [Symbol] `:added` if the local time interval occurs
      #   according to the second data source but not the first, `:removed`
      #   if it occurs according to the first data source but not the second,
      #   or `:multiplicity_changed` if it occurs according to both sources
      #   but a different number of times.
      def kind
        if @first_multiplicity == 0
          :added
        elsif @second_multiplicity == 0
          :removed
        else
          :multiplicity_changed
        end
      end

      # @return [Boolean] whether the local time interval occurs according to
      #   the second data source but not the first.
      def added?
        kind == :added
      end

      # @return [Boolean] whether the local time interval occurs according to
      #   the first data source but not the second.
      def removed?
        kind == :removed
      end

      # @return [Boolean] whether the local time interval occurs according to
      #   both data sources, but a different number of times.
      def multiplicity_changed?
        kind == :multiplicity_changed
      end
    end

    # @return [String] the time zone identifier that was compared.
    attr_reader :identifier

    # @return [Timestamp] the start of the compared window of UTC time
    #   (inclusive).
    attr_reader :from

    # @return [Timestamp] the end of the compared window of UTC time
    #   (exclusive).
    attr_reader :to

    # @return [Timezone] a {Timezone} for {#identifier} obtained from the
    #   first data source.
    attr_reader :first_timezone

    # @return [Timezone] a {Timezone} for {#identifier} obtained from the
    #   second data source.
    attr_reader :second_timezone

    # @return [String] the identifier of the canonical time zone
    #   {#identifier} resolves to in the first data source.
    attr_reader :first_canonical_identifier

    # @return [String] the identifier of the canonical time zone
    #   {#identifier} resolves to in the second data source.
    attr_reader :second_canonical_identifier

    # @return [Array<UtcDifference>] the maximal continuous intervals of UTC
    #   time within the compared window over which the observed offset, DST
    #   status or abbreviation differs between the two data sources, in
    #   ascending order.
    attr_reader :utc_differences

    # @return [Array<LocalTimeChange>] the intervals of local time that
    #   occur a different number of times according to each data source, in
    #   ascending order.
    attr_reader :local_time_changes

    # Initializes a new {DataSourceComparison}.
    #
    # {DataSourceComparison} instances should not normally be constructed
    # manually. Use {DataSourceComparer#compare} to compare two data sources.
    #
    # @param identifier [String] the time zone identifier that was compared.
    # @param from [Timestamp] the start of the compared window of UTC time
    #   (inclusive).
    # @param to [Timestamp] the end of the compared window of UTC time
    #   (exclusive).
    # @param first_timezone [Timezone] a {Timezone} for `identifier`
    #   obtained from the first data source.
    # @param second_timezone [Timezone] a {Timezone} for `identifier`
    #   obtained from the second data source.
    # @param first_canonical_identifier [String] the identifier of the
    #   canonical time zone `identifier` resolves to in the first data
    #   source.
    # @param second_canonical_identifier [String] the identifier of the
    #   canonical time zone `identifier` resolves to in the second data
    #   source.
    # @param utc_differences [Array<UtcDifference>] the {UtcDifference}
    #   instances found within the compared window.
    # @param local_time_changes [Array<LocalTimeChange>] the
    #   {LocalTimeChange} instances found within the compared window.
    def initialize(identifier, from, to, first_timezone, second_timezone,
        first_canonical_identifier, second_canonical_identifier,
        utc_differences, local_time_changes)
      @identifier = identifier
      @from = from
      @to = to
      @first_timezone = first_timezone
      @second_timezone = second_timezone
      @first_canonical_identifier = first_canonical_identifier
      @second_canonical_identifier = second_canonical_identifier
      @utc_differences = utc_differences.freeze
      @local_time_changes = local_time_changes.freeze
      freeze
    end

    # Determines whether the identifier resolves to a differently named
    # canonical time zone in each data source (for example, when a zone has
    # been renamed and replaced with a link in one of the sources).
    #
    # A rename may or may not be accompanied by changes to the observed
    # offsets. Use {#identical?} or {#rename_only?} to distinguish a pure
    # rename from a change to the observed local times.
    #
    # @return [Boolean] whether the canonical time zone identifiers differ
    #   between the two data sources.
    def renamed?
      @first_canonical_identifier != @second_canonical_identifier
    end

    # @return [Boolean] whether the two data sources observe identical
    #   offsets and local times for {#identifier} over the compared window.
    def identical?
      @utc_differences.empty? && @local_time_changes.empty?
    end

    # @return [Boolean] whether the identifier has been renamed (resolving to
    #   a different canonical time zone in each source) without any change to
    #   the observed offsets or local times over the compared window.
    def rename_only?
      renamed? && identical?
    end
  end
end
