# encoding: UTF-8
# frozen_string_literal: true

module TZInfo
  module DataSources
    # An opt-in {ZoneinfoDataSource} subclass that also reads leap second
    # data from zoneinfo files.
    #
    # Unlike {ZoneinfoDataSource} (which requires zoneinfo files that omit
    # leap seconds), {LeapAwareZoneinfoDataSource} accepts TZif files that
    # contain leap second records, including TZif version 4 files with a
    # leap second expiration time. The leap second data is made available as
    # a {LeapSeconds::LeapSecondTable} via {#leap_second_table}.
    #
    # Time zone information and all {Time}- and {DateTime}-based interfaces
    # continue to use POSIX semantics (leap seconds are ignored). The leap
    # second table can be used to explicitly convert between POSIX times,
    # UTC times (distinguishing inserted leap seconds such as 23:59:60) and
    # positions on a continuous seconds axis using
    # {LeapSeconds::LeapTimestamp}.
    #
    # To use {LeapAwareZoneinfoDataSource}, set it as the {DataSource}:
    #
    #     TZInfo::DataSource.set(TZInfo::DataSources::LeapAwareZoneinfoDataSource.new)
    #
    # Or use it directly:
    #
    #     data_source = TZInfo::DataSources::LeapAwareZoneinfoDataSource.new
    #     table = data_source.leap_second_table
    #     timestamp = data_source.leap_timestamp_for_utc(2016, 12, 31, 23, 59, 60)
    class LeapAwareZoneinfoDataSource < ZoneinfoDataSource
      # Initializes a new {LeapAwareZoneinfoDataSource}.
      #
      # The parameters are the same as for {ZoneinfoDataSource#initialize}.
      #
      # @param zoneinfo_dir [String] an optional path to a directory to use
      #   as the source of zoneinfo files.
      # @param alternate_iso3166_tab_path [String] an optional path to the
      #   iso3166.tab file.
      def initialize(zoneinfo_dir = nil, alternate_iso3166_tab_path = nil)
        @leap_second_table = nil
        @leap_second_table_searched = false
        super
      end

      # Returns the leap second table read from the zoneinfo files.
      #
      # The table is taken from the first loaded zoneinfo file that
      # contains leap second data. If no time zone has been loaded yet, a
      # small set of candidate zones (`UTC`, `Etc/UTC` and the first
      # available zone) will be loaded in an attempt to find leap second
      # data.
      #
      # @return [LeapSeconds::LeapSecondTable] the leap second table, or
      #   `nil` if the zoneinfo files do not contain leap second data.
      def leap_second_table
        unless @leap_second_table_searched
          @leap_second_table_searched = true
          search_for_leap_second_table unless @leap_second_table
        end

        @leap_second_table
      end

      # Returns a {LeapSeconds::LeapTimestamp} for a POSIX time.
      #
      # @param posix_time [Integer] a POSIX time (seconds since 1970-01-01
      #   00:00:00 UTC, ignoring leap seconds).
      # @return [LeapSeconds::LeapTimestamp] a {LeapSeconds::LeapTimestamp}.
      # @raise [LeapSeconds::LeapSecondsError] if the zoneinfo files do not
      #   contain leap second data.
      # @raise [LeapSeconds::UtcSecondNotFound] if `posix_time` identifies
      #   a UTC second that was removed by a negative leap second.
      # @raise [LeapSeconds::LeapSecondTableExpired] if `posix_time` is at
      #   or after the expiration time of the leap second table.
      def leap_timestamp_for_posix(posix_time)
        LeapSeconds::LeapTimestamp.for_posix(require_leap_second_table, posix_time)
      end

      # Returns a {LeapSeconds::LeapTimestamp} for a position on the
      # continuous seconds axis.
      #
      # @param continuous [Integer] a position on the continuous seconds
      #   axis (counting every elapsed second since 1970-01-01 00:00:00
      #   UTC, including inserted leap seconds).
      # @return [LeapSeconds::LeapTimestamp] a {LeapSeconds::LeapTimestamp}.
      # @raise [LeapSeconds::LeapSecondsError] if the zoneinfo files do not
      #   contain leap second data.
      # @raise [LeapSeconds::LeapSecondTableExpired] if `continuous` is
      #   beyond the known range of the leap second table.
      def leap_timestamp_for_continuous(continuous)
        LeapSeconds::LeapTimestamp.for_continuous(require_leap_second_table, continuous)
      end

      # Returns a {LeapSeconds::LeapTimestamp} for a UTC date and time. A
      # `second` of 60 denotes an inserted leap second (23:59:60).
      #
      # @param year [Integer] the year.
      # @param month [Integer] the month (1-12).
      # @param day [Integer] the day of the month (1-31).
      # @param hour [Integer] the hour (0-23).
      # @param minute [Integer] the minute (0-59).
      # @param second [Integer] the second (0-60, where 60 denotes an
      #   inserted leap second).
      # @return [LeapSeconds::LeapTimestamp] a {LeapSeconds::LeapTimestamp}.
      # @raise [LeapSeconds::LeapSecondsError] if the zoneinfo files do not
      #   contain leap second data.
      # @raise [LeapSeconds::UtcSecondNotFound] if the specified UTC second
      #   does not exist according to the leap second table.
      # @raise [LeapSeconds::LeapSecondTableExpired] if the specified time
      #   is at or after the expiration time of the leap second table.
      def leap_timestamp_for_utc(year, month, day, hour, minute, second)
        LeapSeconds::LeapTimestamp.for_utc(require_leap_second_table, year, month, day, hour, minute, second)
      end

      private

      # Reads a zoneinfo file, capturing any leap second data it contains.
      #
      # @param path [String] the path of the zoneinfo file.
      # @return [Object] either a {TimezoneOffset} or an `Array` of
      #   {TimezoneTransition}s.
      def read_zoneinfo_file(path)
        zoneinfo, leap_second_table = @zoneinfo_reader.read_with_leap_seconds(path)
        @leap_second_table ||= leap_second_table if leap_second_table
        zoneinfo
      end

      # Attempts to find leap second data by loading candidate time zones.
      def search_for_leap_second_table
        candidates = []
        candidates << 'UTC' if @timezone_identifiers.include?('UTC')
        candidates << 'Etc/UTC' if @timezone_identifiers.include?('Etc/UTC')
        candidates << @timezone_identifiers.first unless @timezone_identifiers.empty?

        candidates.each do |identifier|
          break if @leap_second_table

          begin
            load_timezone_info(identifier)
          rescue InvalidTimezoneIdentifier
            # Ignore and try the next candidate.
          end
        end
      end

      # @return [LeapSeconds::LeapSecondTable] the leap second table.
      # @raise [LeapSeconds::LeapSecondsError] if the zoneinfo files do not
      #   contain leap second data.
      def require_leap_second_table
        table = leap_second_table

        unless table
          raise LeapSeconds::LeapSecondsError, 'The zoneinfo files do not contain leap second data'
        end

        table
      end
    end
  end
end
