# encoding: UTF-8
# frozen_string_literal: true

module TZInfo
  # Compares the behaviour of a time zone between two explicitly supplied
  # {DataSource} instances over a given UTC window.
  #
  # This is intended to help assess the impact of an update to time zone data
  # (for example, before upgrading to a new tzdata release). Given the data
  # sources for the old and new versions of the data, a time zone identifier
  # and a UTC window, {DataSourceComparator#compare} reports the minimal
  # intervals where the observed UTC offset, DST flag or abbreviation differ,
  # together with the local time periods that are added, removed or change
  # multiplicity (the number of UTC times that map to the same local time) as
  # a result.
  #
  # The comparison uses only the two {DataSource} instances passed to
  # {initialize}. The process-wide data source selected with {DataSource.set}
  # is never read or modified, and {Timezone} instances previously obtained
  # with {Timezone.get} are unaffected.
  #
  #     comparator = TZInfo::DataSourceComparator.new(old_source, new_source)
  #     comparison = comparator.compare(
  #       'America/New_York', Time.utc(2026, 1, 1), Time.utc(2027, 1, 1))
  #     comparison.intervals.each do |interval|
  #       puts interval.starts_at.to_s + " - " + interval.ends_at.to_s
  #     end
  class DataSourceComparator
    # The attributes of a time zone period that are compared, in the order
    # they are reported in {ComparisonSegment#differences} and
    # {DifferenceInterval#differences}.
    #
    # @private
    COMPARED_ATTRIBUTES = [:offset, :dst, :abbreviation].freeze

    # An atomic portion of a compared UTC window, bounded by the window edges
    # and the transition times of both data sources. The observed offset, DST
    # flag and abbreviation of each source are constant within a segment.
    class ComparisonSegment
      # @return [Timestamp] the UTC start of the segment (inclusive).
      attr_reader :starts_at

      # @return [Timestamp] the UTC end of the segment (exclusive).
      attr_reader :ends_at

      # @return [TimezonePeriod] the period observed by the old data source
      #   during the segment.
      attr_reader :old_period

      # @return [TimezonePeriod] the period observed by the new data source
      #   during the segment.
      attr_reader :new_period

      # @return [Array<Symbol>] the attributes that differ between the two
      #   sources during the segment - a subset of :offset, :dst and
      #   :abbreviation. Empty if the sources agree.
      attr_reader :differences

      # @private
      def initialize(starts_at, ends_at, old_period, new_period, differences)
        @starts_at = starts_at
        @ends_at = ends_at
        @old_period = old_period
        @new_period = new_period
        @differences = differences.freeze
      end

      # @return [Boolean] true if the two sources differ during the segment.
      def different?
        !@differences.empty?
      end

      # @return [Boolean] true if the observed UTC offset differs during the
      #   segment.
      def offset_difference?
        @differences.include?(:offset)
      end

      # @return [Boolean] true if the DST flag differs during the segment.
      def dst_difference?
        @differences.include?(:dst)
      end

      # @return [Boolean] true if the abbreviation differs during the
      #   segment.
      def abbreviation_difference?
        @differences.include?(:abbreviation)
      end
    end

    # A maximal continuous UTC interval over which the two compared data
    # sources differ. Adjacent {ComparisonSegment ComparisonSegments} that
    # both differ are merged, so a continuous change is reported once even
    # when the two sources transition at different instants or one source
    # transitions multiple times within the interval.
    class DifferenceInterval
      # @return [Array<ComparisonSegment>] the atomic segments that make up
      #   the interval, in ascending order.
      attr_reader :segments

      # @private
      def initialize(segments)
        @segments = segments.freeze
      end

      # @return [Timestamp] the UTC time the difference starts (inclusive).
      def starts_at
        @segments.first.starts_at
      end

      # @return [Timestamp] the UTC time the difference ends (exclusive).
      def ends_at
        @segments.last.ends_at
      end

      # @return [Array<Symbol>] the attributes that differ at any point
      #   within the interval - a subset of :offset, :dst and :abbreviation.
      def differences
        @differences ||= COMPARED_ATTRIBUTES.select do |attribute|
          @segments.any? {|s| s.differences.include?(attribute) }
        end.freeze
      end

      # @return [Boolean] true if the observed UTC offset differs at any
      #   point within the interval.
      def offset_difference?
        differences.include?(:offset)
      end

      # @return [Boolean] true if the DST flag differs at any point within
      #   the interval.
      def dst_difference?
        differences.include?(:dst)
      end

      # @return [Boolean] true if the abbreviation differs at any point
      #   within the interval.
      def abbreviation_difference?
        differences.include?(:abbreviation)
      end
    end

    # A local time period for which the number of matching UTC times (the
    # multiplicity) differs between the two compared data sources. This
    # covers local times that only exist in one source (a gap that was added
    # or removed) and local times that are ambiguous in one source but not
    # the other.
    class LocalTimeChange
      # @return [Symbol] :added if the local times only exist in the new
      #   source, :removed if they only exist in the old source, or
      #   :multiplicity_changed if they exist in both sources but with a
      #   different number of matching UTC times.
      attr_reader :kind

      # @return [Timestamp] the start of the local time period (inclusive),
      #   as a {Timestamp} with an unspecified offset.
      attr_reader :local_starts_at

      # @return [Timestamp] the end of the local time period (exclusive),
      #   as a {Timestamp} with an unspecified offset.
      attr_reader :local_ends_at

      # @return [Integer] the number of UTC times matching each local time
      #   in the period according to the old data source.
      attr_reader :old_count

      # @return [Integer] the number of UTC times matching each local time
      #   in the period according to the new data source.
      attr_reader :new_count

      # @private
      def initialize(kind, local_starts_at, local_ends_at, old_count, new_count)
        @kind = kind
        @local_starts_at = local_starts_at
        @local_ends_at = local_ends_at
        @old_count = old_count
        @new_count = new_count
      end

      # @return [Boolean] true if the local times only exist in the new
      #   source.
      def added?
        @kind == :added
      end

      # @return [Boolean] true if the local times only exist in the old
      #   source.
      def removed?
        @kind == :removed
      end

      # @return [Boolean] true if the local times exist in both sources but
      #   with a different number of matching UTC times.
      def multiplicity_changed?
        @kind == :multiplicity_changed
      end
    end

    # The result of comparing a time zone between two data sources over a
    # UTC window. Returned by {DataSourceComparator#compare}.
    class TimezoneComparison
      # @return [String] the time zone identifier that was compared.
      attr_reader :identifier

      # @return [Timestamp] the UTC start of the compared window.
      attr_reader :from

      # @return [Timestamp] the UTC end of the compared window.
      attr_reader :to

      # @return [String] the identifier of the data time zone that provided
      #   the data in the old source (the link target if the compared zone
      #   is a link).
      attr_reader :old_canonical_identifier

      # @return [String] the identifier of the data time zone that provided
      #   the data in the new source (the link target if the compared zone
      #   is a link).
      attr_reader :new_canonical_identifier

      # @return [Array<ComparisonSegment>] the atomic segments covering the
      #   whole compared window, in ascending order.
      attr_reader :segments

      # @return [Array<DifferenceInterval>] the maximal continuous UTC
      #   intervals over which the two sources differ, in ascending order.
      attr_reader :intervals

      # @return [Array<LocalTimeChange>] the local time periods that are
      #   added, removed or change multiplicity between the two sources, in
      #   ascending order.
      attr_reader :local_time_changes

      # @private
      def initialize(identifier, from, to, old_linked, new_linked,
                     old_canonical_identifier, new_canonical_identifier,
                     segments, intervals, local_time_changes)
        @identifier = identifier
        @from = from
        @to = to
        @old_linked = old_linked
        @new_linked = new_linked
        @old_canonical_identifier = old_canonical_identifier
        @new_canonical_identifier = new_canonical_identifier
        @segments = segments.freeze
        @intervals = intervals.freeze
        @local_time_changes = local_time_changes.freeze
      end

      # @return [Boolean] true if the compared zone is a link (alias) in the
      #   old source.
      def old_linked?
        @old_linked
      end

      # @return [Boolean] true if the compared zone is a link (alias) in the
      #   new source.
      def new_linked?
        @new_linked
      end

      # @return [Boolean] true if the way the compared zone resolves to a
      #   data time zone differs between the sources (for example, an alias
      #   that was renamed to target a differently named zone).
      def link_difference?
        @old_linked != @new_linked || @old_canonical_identifier != @new_canonical_identifier
      end

      # @return [Boolean] true if the observed offset, DST flag,
      #   abbreviation or local time multiplicities differ at any point in
      #   the compared window.
      def clock_changes?
        !@intervals.empty? || !@local_time_changes.empty?
      end

      # @return [Boolean] true if the only difference is how the compared
      #   zone resolves to a data time zone (for example, a renamed alias)
      #   and the observed behaviour is identical.
      def link_only_change?
        link_difference? && !clock_changes?
      end

      # @return [Boolean] true if there are no differences of any kind
      #   between the two sources for the compared zone and window.
      def identical?
        !clock_changes? && !link_difference?
      end
    end

    # @return [DataSource] the data source compared as the old version of
    #   the data.
    attr_reader :old_source

    # @return [DataSource] the data source compared as the new version of
    #   the data.
    attr_reader :new_source

    # Initializes a new {DataSourceComparator}.
    #
    # @param old_source [DataSource] the data source providing the old
    #   version of the data.
    # @param new_source [DataSource] the data source providing the new
    #   version of the data.
    # @raise [ArgumentError] if either source is not a {DataSource}.
    def initialize(old_source, new_source)
      raise ArgumentError, "old_source must be a DataSource" unless old_source.kind_of?(DataSource)
      raise ArgumentError, "new_source must be a DataSource" unless new_source.kind_of?(DataSource)
      @old_source = old_source
      @new_source = new_source
    end

    # Compares a time zone between the old and new data sources over a UTC
    # window.
    #
    # The window is bounded by transition times from either source: reported
    # interval boundaries are the exact instants at which the sources start
    # or stop agreeing, and can be queried against either source (for
    # example with {Timezone#period_for_utc}).
    #
    # @param identifier [String] the identifier of the time zone to compare.
    # @param from [Object] a Time, DateTime or {Timestamp} with a specified
    #   offset giving the inclusive UTC start of the window.
    # @param to [Object] a Time, DateTime or {Timestamp} with a specified
    #   offset giving the exclusive UTC end of the window.
    # @return [TimezoneComparison] the result of the comparison.
    # @raise [ArgumentError] if from or to is nil, has no specified offset,
    #   or to is not later than from.
    # @raise [InvalidTimezoneIdentifier] if the identifier is not valid in
    #   both sources.
    def compare(identifier, from, to)
      from_timestamp = utc_timestamp(from, "from")
      to_timestamp = utc_timestamp(to, "to")
      raise ArgumentError, "to must be greater than from" unless to_timestamp > from_timestamp

      old_timezone, old_canonical_identifier, old_linked = resolve_timezone(@old_source, identifier)
      new_timezone, new_canonical_identifier, new_linked = resolve_timezone(@new_source, identifier)

      old_transitions = old_timezone.transitions_up_to(to_timestamp, from_timestamp)
      new_transitions = new_timezone.transitions_up_to(to_timestamp, from_timestamp)

      points = [from_timestamp.value, to_timestamp.value]
      old_transitions.each {|t| points << t.timestamp_value }
      new_transitions.each {|t| points << t.timestamp_value }
      points.uniq!
      points.sort!

      segments = points.each_cons(2).map do |starts_value, ends_value|
        starts_at = Timestamp.utc(starts_value)
        old_period = old_timezone.period_for(starts_at)
        new_period = new_timezone.period_for(starts_at)
        differences = segment_differences(old_period, new_period)
        ComparisonSegment.new(starts_at, Timestamp.utc(ends_value), old_period, new_period, differences)
      end

      intervals = merge_intervals(segments)
      local_time_changes = find_local_time_changes(old_timezone, new_timezone, old_transitions, new_transitions)

      TimezoneComparison.new(
        identifier, from_timestamp, to_timestamp,
        old_linked, new_linked,
        old_canonical_identifier, new_canonical_identifier,
        segments, intervals, local_time_changes)
    end

    private

    # Converts a Time-like value to a {Timestamp} with a specified offset.
    #
    # @param value [Object] the value to convert.
    # @param name [String] the parameter name used in error messages.
    # @return [Timestamp] the converted value.
    # @raise [ArgumentError] if value is nil or has no specified offset.
    def utc_timestamp(value, name)
      raise ArgumentError, name + " must be specified" unless value
      timestamp = Timestamp.for(value)
      raise ArgumentError, name + " must have a specified utc_offset" unless timestamp.utc_offset
      timestamp
    end

    # Resolves an identifier in a data source to a {Timezone} that can be
    # queried directly, following links within that source only. Returns the
    # {Timezone}, the identifier of the data zone that was resolved and
    # whether the identifier was a link.
    #
    # @param source [DataSource] the data source to resolve within.
    # @param identifier [String] the identifier to resolve.
    # @return [Array] a [Timezone, String, Boolean] triple.
    # @raise [InvalidTimezoneIdentifier] if the identifier is invalid or the
    #   links are circular.
    def resolve_timezone(source, identifier)
      info = source.get_timezone_info(identifier)
      linked = info.kind_of?(DataSources::LinkedTimezoneInfo)
      seen = {}

      while info.kind_of?(DataSources::LinkedTimezoneInfo)
        target = info.link_to_identifier
        raise InvalidTimezoneIdentifier, "Circular link for identifier: " + identifier if seen[target]
        seen[target] = true
        info = source.get_timezone_info(target)
      end

      [info.create_timezone, info.identifier, linked]
    end

    # Determines which of the compared attributes differ between two
    # {TimezonePeriod} instances.
    #
    # @param old_period [TimezonePeriod] the period from the old source.
    # @param new_period [TimezonePeriod] the period from the new source.
    # @return [Array<Symbol>] the differing attributes.
    def segment_differences(old_period, new_period)
      differences = []
      differences << :offset if old_period.observed_utc_offset != new_period.observed_utc_offset
      differences << :dst if old_period.dst? != new_period.dst?
      differences << :abbreviation if old_period.abbreviation != new_period.abbreviation
      differences
    end

    # Merges runs of adjacent differing segments into {DifferenceInterval}
    # instances.
    #
    # @param segments [Array<ComparisonSegment>] the atomic segments covering
    #   the compared window.
    # @return [Array<DifferenceInterval>] the merged intervals.
    def merge_intervals(segments)
      runs = []
      current_run = nil

      segments.each do |segment|
        if segment.different?
          if current_run
            current_run << segment
          else
            current_run = [segment]
            runs << current_run
          end
        else
          current_run = nil
        end
      end

      runs.map {|run| DifferenceInterval.new(run) }
    end

    # Finds local time periods where the number of matching UTC times
    # differs between the two sources. Local time multiplicities can only
    # change at the local start and end times of transitions, so the local
    # edges of every transition in the window from both sources are used as
    # breakpoints. Adjacent sections with the same kind of change and counts
    # are merged.
    #
    # @param old_timezone [Timezone] the time zone from the old source.
    # @param new_timezone [Timezone] the time zone from the new source.
    # @param old_transitions [Array<TimezoneTransition>] the old source
    #   transitions within the window.
    # @param new_transitions [Array<TimezoneTransition>] the new source
    #   transitions within the window.
    # @return [Array<LocalTimeChange>] the local time changes.
    def find_local_time_changes(old_timezone, new_timezone, old_transitions, new_transitions)
      points = []

      (old_transitions + new_transitions).each do |transition|
        points << transition.timestamp_value + transition.previous_offset.observed_utc_offset
        points << transition.timestamp_value + transition.offset.observed_utc_offset
      end

      return [] if points.empty?

      points.uniq!
      points.sort!

      changes = []

      points.each_cons(2) do |starts_value, ends_value|
        local_starts_at = Timestamp.new(starts_value)
        old_count = old_timezone.periods_for_local(local_starts_at).length
        new_count = new_timezone.periods_for_local(local_starts_at).length
        next if old_count == new_count

        kind = if old_count == 0
          :added
        elsif new_count == 0
          :removed
        else
          :multiplicity_changed
        end

        last = changes.last

        if last && last.kind == kind && last.old_count == old_count &&
           last.new_count == new_count && last.local_ends_at.value == starts_value
          changes[-1] = LocalTimeChange.new(kind, last.local_starts_at, Timestamp.new(ends_value), old_count, new_count)
        else
          changes << LocalTimeChange.new(kind, local_starts_at, Timestamp.new(ends_value), old_count, new_count)
        end
      end

      changes
    end
  end
end
