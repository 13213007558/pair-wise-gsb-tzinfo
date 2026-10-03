# encoding: UTF-8
# frozen_string_literal: true

module TZInfo
  # Compares the definition of a time zone in two explicitly specified
  # {DataSource} instances over a window of UTC time.
  #
  # {DataSourceComparer} can be used to preview the effect of updating time
  # zone data (for example, upgrading to a new release of the IANA Time Zone
  # Database) before switching over. Given a time zone identifier and a UTC
  # window, {#compare} returns a {DataSourceComparison} describing:
  #
  # * The half-open intervals of UTC time over which the observed UTC offset,
  #   DST status or abbreviation differ between the two sources. Adjacent
  #   transitions that form a single continuous change are coalesced into one
  #   {DataSourceComparison::UtcDifference}, even when the two sources switch
  #   at different instants.
  # * The intervals of local time that start occurring, stop occurring or
  #   occur a different number of times (because of changes to the gaps and
  #   overlaps created by transitions).
  # * Whether the identifier resolves to a differently named canonical time
  #   zone in each source, allowing a rename of a link or alias to be
  #   distinguished from a real change to the observed local times.
  #
  # {DataSourceComparer} works solely with the two {DataSource} instances it
  # is given. It neither reads nor changes the process-global data source
  # selected with {DataSource.set}, and does not affect the behaviour of any
  # {Timezone} instances that have already been obtained.
  #
  #     old_source = TZInfo::DataSources::ZoneinfoDataSource.new('/usr/share/zoneinfo')
  #     new_source = TZInfo::DataSources::ZoneinfoDataSource.new('/tmp/zoneinfo-new')
  #
  #     comparer = TZInfo::DataSourceComparer.new(old_source, new_source)
  #     comparison = comparer.compare('America/New_York', Time.utc(2026, 1, 1), Time.utc(2027, 1, 1))
  #
  #     comparison.utc_differences.each do |difference|
  #       puts "Differs from #{difference.starts_at} to #{difference.ends_at}"
  #     end
  class DataSourceComparer
    # @return [DataSource] the first (typically older) of the two data
    #   sources being compared.
    attr_reader :first_data_source

    # @return [DataSource] the second (typically newer) of the two data
    #   sources being compared.
    attr_reader :second_data_source

    # Initializes a new {DataSourceComparer}.
    #
    # @param first_data_source [DataSource] the first (typically older) of
    #   the two data sources to compare.
    # @param second_data_source [DataSource] the second (typically newer) of
    #   the two data sources to compare.
    # @raise [ArgumentError] if either parameter is not a {DataSource}.
    def initialize(first_data_source, second_data_source)
      raise ArgumentError, 'first_data_source must be a DataSource' unless first_data_source.kind_of?(DataSource)
      raise ArgumentError, 'second_data_source must be a DataSource' unless second_data_source.kind_of?(DataSource)

      @first_data_source = first_data_source
      @second_data_source = second_data_source
    end

    # Compares the definition of a time zone in the two data sources over a
    # window of UTC time.
    #
    # The returned {DataSourceComparison} exposes {Timezone} instances
    # obtained from each source ({DataSourceComparison#first_timezone} and
    # {DataSourceComparison#second_timezone}). Every boundary reported in the
    # result can be verified by querying both of these {Timezone} instances
    # (for example, with {Timezone#period_for_utc} for UTC boundaries and
    # {Timezone#periods_for_local} for local time boundaries).
    #
    # @param identifier [String] the time zone identifier to compare.
    # @param from [Object] the start of the window to compare as a Time,
    #   DateTime or {Timestamp} (treated as UTC, inclusive).
    # @param to [Object] the end of the window to compare as a Time,
    #   DateTime or {Timestamp} (treated as UTC, exclusive).
    # @return [DataSourceComparison] the result of the comparison.
    # @raise [ArgumentError] if identifier, from or to is nil, or if to is
    #   not greater than from.
    # @raise [InvalidTimezoneIdentifier] if identifier is not valid in
    #   either of the two data sources.
    def compare(identifier, from, to)
      raise ArgumentError, 'identifier must be specified' unless identifier
      raise ArgumentError, 'from must be specified' unless from
      raise ArgumentError, 'to must be specified' unless to

      from = Timestamp.for(from, :treat_as_utc)
      to = Timestamp.for(to, :treat_as_utc)
      raise ArgumentError, 'to must be greater than from' unless to > from

      first_timezone, first_canonical_identifier = resolve_timezone(@first_data_source, identifier)
      second_timezone, second_canonical_identifier = resolve_timezone(@second_data_source, identifier)

      first_transitions = first_timezone.transitions_up_to(to, from)
      second_transitions = second_timezone.transitions_up_to(to, from)

      boundaries = [from, to]
      first_transitions.each {|t| boundaries << t.at }
      second_transitions.each {|t| boundaries << t.at }
      boundaries = dedupe_sorted(boundaries.sort)

      segments = []
      boundaries.each_cons(2) do |starts_at, ends_at|
        first_period = first_timezone.period_for_utc(starts_at)
        second_period = second_timezone.period_for_utc(starts_at)

        if period_attributes(first_period) != period_attributes(second_period)
          segments << DataSourceComparison::UtcSegment.new(starts_at, ends_at, first_period, second_period)
        end
      end

      utc_differences = coalesce_segments(segments).map do |run|
        DataSourceComparison::UtcDifference.new(run)
      end

      local_time_changes = find_local_time_changes(
        first_timezone, second_timezone, first_transitions, second_transitions,
        from, to, boundaries)

      DataSourceComparison.new(
        identifier, from, to, first_timezone, second_timezone,
        first_canonical_identifier, second_canonical_identifier,
        utc_differences, local_time_changes)
    end

    private

    # Resolves an identifier to a {Timezone} and its canonical identifier
    # using only the given {DataSource}. Links are followed within the same
    # data source rather than via the process-global data source (which is
    # what {Timezone.get} and {LinkedTimezone} would use).
    #
    # @param data_source [DataSource] the {DataSource} to resolve the
    #   identifier with.
    # @param identifier [String] the time zone identifier to resolve.
    # @return [Array] a two element Array containing the {Timezone} and the
    #   canonical identifier.
    # @raise [InvalidTimezoneIdentifier] if the identifier is not valid or a
    #   circular chain of links is found.
    def resolve_timezone(data_source, identifier)
      info = data_source.get_timezone_info(identifier)
      visited = {}

      while info.kind_of?(DataSources::LinkedTimezoneInfo)
        if visited[info.identifier]
          raise InvalidTimezoneIdentifier, "circular link found whilst resolving #{identifier}"
        end

        visited[info.identifier] = true
        info = data_source.get_timezone_info(info.link_to_identifier)
      end

      [info.create_timezone, info.identifier]
    end

    # @param period [TimezonePeriod] a {TimezonePeriod}.
    # @return [Array] the attributes of period that are significant when
    #   comparing two data sources: the observed UTC offset, the DST status
    #   and the abbreviation.
    def period_attributes(period)
      [period.observed_utc_offset, period.dst?, period.abbreviation]
    end

    # @param timestamps [Array<Timestamp>] a sorted Array of {Timestamp}
    #   instances.
    # @return [Array<Timestamp>] the timestamps with consecutive duplicates
    #   removed.
    def dedupe_sorted(timestamps)
      result = []
      timestamps.each {|t| result << t if result.empty? || (result.last <=> t) != 0 }
      result
    end

    # Groups adjacent {DataSourceComparison::UtcSegment} instances into runs
    # so that a continuous change is reported once rather than being repeated
    # for each transition.
    #
    # @param segments [Array<DataSourceComparison::UtcSegment>] the differing
    #   segments in ascending order.
    # @return [Array<Array<DataSourceComparison::UtcSegment>>] an Array of
    #   runs of adjacent segments.
    def coalesce_segments(segments)
      runs = []

      segments.each do |segment|
        if !runs.empty? && runs.last.last.ends_at == segment.starts_at
          runs.last << segment
        else
          runs << [segment]
        end
      end

      runs
    end

    # Determines the intervals of local time that occur a different number of
    # times according to each data source.
    #
    # Each transition that changes the observed UTC offset creates an
    # interval of local time that either does not occur (a gap, when clocks
    # move forward) or occurs twice (an overlap, when clocks move back).
    # Comparing the gaps and overlaps of the two sources reveals the local
    # times that start occurring, stop occurring or change multiplicity.
    #
    # The analysis is limited to the local times that are covered by the
    # compared UTC window in both sources, so that differences in the offsets
    # observed at the edges of the window do not produce spurious results.
    #
    # @return [Array<DataSourceComparison::LocalTimeChange>] the local time
    #   changes in ascending order.
    def find_local_time_changes(first_timezone, second_timezone,
        first_transitions, second_transitions, from, to, boundaries)
      penultimate_boundary = boundaries[-2]

      first_open_offset = first_timezone.period_for_utc(from).observed_utc_offset
      second_open_offset = second_timezone.period_for_utc(from).observed_utc_offset
      first_close_offset = first_timezone.period_for_utc(penultimate_boundary).observed_utc_offset
      second_close_offset = second_timezone.period_for_utc(penultimate_boundary).observed_utc_offset

      local_lo = [from.value + first_open_offset, from.value + second_open_offset].max
      local_hi = [to.value + first_close_offset, to.value + second_close_offset].min
      return [] if local_hi <= local_lo

      first_anomalies = local_anomalies(first_transitions, local_lo, local_hi)
      second_anomalies = local_anomalies(second_transitions, local_lo, local_hi)

      points = [local_lo, local_hi]
      (first_anomalies + second_anomalies).each {|anomaly| points << anomaly[0] << anomaly[1] }
      points = points.sort.uniq

      changes = []
      points.each_cons(2) do |starts_at, ends_at|
        first_multiplicity = multiplicity_at(first_anomalies, starts_at)
        second_multiplicity = multiplicity_at(second_anomalies, starts_at)
        next if first_multiplicity == second_multiplicity

        last = changes.last
        if last && last[1] == starts_at && last[2] == first_multiplicity && last[3] == second_multiplicity
          last[1] = ends_at
        else
          changes << [starts_at, ends_at, first_multiplicity, second_multiplicity]
        end
      end

      changes.map do |starts_at, ends_at, first_multiplicity, second_multiplicity|
        DataSourceComparison::LocalTimeChange.new(
          local_timestamp(starts_at), local_timestamp(ends_at),
          first_multiplicity, second_multiplicity)
      end
    end

    # @param value [Integer] a local time as a {Timestamp}-style value.
    # @return [Timestamp] a {Timestamp} for the given value with an
    #   unspecified UTC offset, suitable for passing to
    #   {Timezone#periods_for_local}.
    def local_timestamp(value)
      Timestamp.for(Timestamp.utc(value), :ignore)
    end

    # Calculates the intervals of local time, clipped to a given range, where
    # a set of transitions causes local times to either not occur (a
    # multiplicity of 0) or occur twice (a multiplicity of 2).
    #
    # @param transitions [Array<TimezoneTransition>] the transitions to
    #   examine.
    # @param local_lo [Integer] the earliest local time of interest as a
    #   {Timestamp}-style value.
    # @param local_hi [Integer] the latest local time of interest as a
    #   {Timestamp}-style value.
    # @return [Array<Array>] an Array of [start, end, multiplicity]
    #   triplets.
    def local_anomalies(transitions, local_lo, local_hi)
      result = []

      transitions.each do |transition|
        previous_offset = transition.previous_offset.observed_utc_offset
        current_offset = transition.offset.observed_utc_offset
        at = transition.timestamp_value

        anomaly = nil
        if current_offset > previous_offset
          # Clocks move forward: the intervening local times do not occur.
          anomaly = [at + previous_offset, at + current_offset, 0]
        elsif current_offset < previous_offset
          # Clocks move back: the intervening local times occur twice.
          anomaly = [at + current_offset, at + previous_offset, 2]
        end

        if anomaly
          starts_at = anomaly[0] > local_lo ? anomaly[0] : local_lo
          ends_at = anomaly[1] < local_hi ? anomaly[1] : local_hi
          result << [starts_at, ends_at, anomaly[2]] if ends_at > starts_at
        end
      end

      result
    end

    # @param anomalies [Array<Array>] the result of {#local_anomalies}.
    # @param local_value [Integer] a local time as a {Timestamp}-style value.
    # @return [Integer] the number of times local_value occurs (0, 1 or 2).
    def multiplicity_at(anomalies, local_value)
      anomalies.each do |starts_at, ends_at, multiplicity|
        return multiplicity if local_value >= starts_at && local_value < ends_at
      end

      1
    end
  end
end
