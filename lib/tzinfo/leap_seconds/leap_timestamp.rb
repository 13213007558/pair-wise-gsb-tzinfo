# encoding: UTF-8
# frozen_string_literal: true

require 'date'

module TZInfo
  module LeapSeconds
    # A leap-second-aware time, represented as a position on a continuous
    # seconds axis (counting every elapsed second since 1970-01-01
    # 00:00:00 UTC, including inserted leap seconds) together with the
    # {LeapSecondTable} used to interpret that position.
    #
    # A {LeapTimestamp} distinguishes ordinary UTC seconds from inserted
    # leap seconds (23:59:60). An inserted leap second has no POSIX time
    # representation - {#posix} returns `nil` for such times rather than
    # silently folding them onto a neighboring second.
    #
    # {LeapTimestamp} is independent of TZInfo's {Timestamp}, `Time` and
    # `DateTime` handling, which continue to use POSIX semantics (ignoring
    # leap seconds).
    class LeapTimestamp
      include Comparable

      # The Unix epoch (1970-01-01 00:00:00 UTC) as a chronological Julian
      # day number.
      JD_EPOCH = 2440588
      private_constant :JD_EPOCH

      # The number of seconds in a day on the POSIX axis.
      SECONDS_PER_DAY = 86400
      private_constant :SECONDS_PER_DAY

      class << self
        # Returns a new {LeapTimestamp} for a POSIX time.
        #
        # @param table [LeapSecondTable] the {LeapSecondTable} to use to
        #   interpret the time.
        # @param posix_time [Integer] a POSIX time (seconds since
        #   1970-01-01 00:00:00 UTC, ignoring leap seconds).
        # @return [LeapTimestamp] a new {LeapTimestamp}.
        # @raise [UtcSecondNotFound] if `posix_time` identifies a UTC
        #   second that was removed by a negative leap second.
        # @raise [LeapSecondTableExpired] if `posix_time` is at or after
        #   the expiration time of the table.
        def for_posix(table, posix_time)
          new!(table, table.to_continuous(posix_time))
        end

        # Returns a new {LeapTimestamp} for a position on the continuous
        # seconds axis.
        #
        # @param table [LeapSecondTable] the {LeapSecondTable} to use to
        #   interpret the position.
        # @param continuous [Integer] a position on the continuous seconds
        #   axis.
        # @return [LeapTimestamp] a new {LeapTimestamp}.
        # @raise [LeapSecondTableExpired] if `continuous` is beyond the
        #   known range of the table.
        def for_continuous(table, continuous)
          # Validates that the position is within the known range.
          table.posix_for_continuous(continuous)
          new!(table, continuous)
        end

        # Returns a new {LeapTimestamp} for a (proleptic Gregorian
        # calendar) UTC date and time.
        #
        # A `second` of 60 denotes an inserted leap second (23:59:60) and
        # is only valid when the table contains a positive leap second at
        # the end of the specified day.
        #
        # @param table [LeapSecondTable] the {LeapSecondTable} to use to
        #   interpret the time.
        # @param year [Integer] the year.
        # @param month [Integer] the month (1-12).
        # @param day [Integer] the day of the month (1-31).
        # @param hour [Integer] the hour (0-23).
        # @param minute [Integer] the minute (0-59).
        # @param second [Integer] the second (0-60, where 60 denotes an
        #   inserted leap second).
        # @return [LeapTimestamp] a new {LeapTimestamp}.
        # @raise [ArgumentError] if any parameter is not an `Integer`.
        # @raise [RangeError] if a parameter is outside of its valid
        #   range.
        # @raise [UtcSecondNotFound] if the specified UTC second does not
        #   exist according to the table (either removed by a negative
        #   leap second, or 23:59:60 specified when no positive leap
        #   second was inserted).
        # @raise [LeapSecondTableExpired] if the specified time is at or
        #   after the expiration time of the table.
        def for_utc(table, year, month, day, hour, minute, second)
          raise ArgumentError, 'year must be an Integer' unless year.kind_of?(Integer)
          raise ArgumentError, 'month must be an Integer' unless month.kind_of?(Integer)
          raise ArgumentError, 'day must be an Integer' unless day.kind_of?(Integer)
          raise ArgumentError, 'hour must be an Integer' unless hour.kind_of?(Integer)
          raise ArgumentError, 'minute must be an Integer' unless minute.kind_of?(Integer)
          raise ArgumentError, 'second must be an Integer' unless second.kind_of?(Integer)
          raise RangeError, 'month must be between 1 and 12' if month < 1 || month > 12
          raise RangeError, 'day is not valid for the given year and month' unless Date.valid_civil?(year, month, day)
          raise RangeError, 'hour must be between 0 and 23' if hour < 0 || hour > 23
          raise RangeError, 'minute must be between 0 and 59' if minute < 0 || minute > 59
          raise RangeError, 'second must be between 0 and 60' if second < 0 || second > 60

          if second == 60
            unless hour == 23 && minute == 59
              raise RangeError, 'second can only be 60 for the time 23:59:60'
            end

            next_day = Date.civil(year, month, day) + 1
            posix_time = posix_from_civil(next_day.year, next_day.month, next_day.day)
            # Validates that the time is within the known range.
            table.correction_at(posix_time)
            leap_second = table.leap_second_at(posix_time)

            unless leap_second && leap_second.positive?
              raise UtcSecondNotFound, "#{format_utc(year, month, day, hour, minute, second)} did not exist (no positive leap second was inserted at the end of that day)"
            end

            new!(table, leap_second.inserted_continuous)
          else
            posix_time = posix_from_civil(year, month, day) + hour * 3600 + minute * 60 + second
            for_posix(table, posix_time)
          end
        end

        private

        # @param table [LeapSecondTable] the {LeapSecondTable}.
        # @param continuous [Integer] a position on the continuous seconds
        #   axis.
        # @return [LeapTimestamp] a new {LeapTimestamp} without further
        #   validation.
        def new!(table, continuous)
          raise ArgumentError, 'table must be a LeapSecondTable' unless table.kind_of?(LeapSecondTable)
          raise ArgumentError, 'continuous must be an Integer' unless continuous.kind_of?(Integer)
          ts = allocate
          ts.send(:initialize!, table, continuous)
          ts
        end

        # @param year [Integer] the year.
        # @param month [Integer] the month (1-12).
        # @param day [Integer] the day of the month (1-31).
        # @return [Integer] the POSIX time of 00:00:00 UTC on the given
        #   date.
        def posix_from_civil(year, month, day)
          (Date.civil(year, month, day).jd - JD_EPOCH) * SECONDS_PER_DAY
        end

        # @return [String] the given UTC date and time formatted as
        #   YYYY-MM-DDTHH:MM:SSZ.
        def format_utc(year, month, day, hour, minute, second)
          format('%04d-%02d-%02dT%02d:%02d:%02dZ', year, month, day, hour, minute, second)
        end
      end

      # @return [LeapSecondTable] the {LeapSecondTable} used to interpret
      #   this {LeapTimestamp}.
      attr_reader :table

      # @return [Integer] the position of this {LeapTimestamp} on the
      #   continuous seconds axis (the number of seconds since 1970-01-01
      #   00:00:00 UTC, counting every elapsed second, including inserted
      #   leap seconds).
      attr_reader :continuous

      # @return [Boolean] whether this {LeapTimestamp} represents an
      #   inserted leap second (23:59:60).
      def leap_second?
        !@table.leap_second_for_continuous(@continuous).nil?
      end

      # The POSIX time of this {LeapTimestamp}.
      #
      # Inserted leap seconds have no POSIX time representation. `nil` is
      # returned for such times rather than silently folding them onto a
      # neighboring second.
      #
      # @return [Integer] the POSIX time (seconds since 1970-01-01
      #   00:00:00 UTC, ignoring leap seconds), or `nil` if this
      #   {LeapTimestamp} represents an inserted leap second.
      def posix
        @table.posix_for_continuous(@continuous)
      end

      # Returns the UTC date and time of this {LeapTimestamp}.
      #
      # @return [Array<Integer>] an `Array` of
      #   `[year, month, day, hour, minute, second]`. `second` will be 60
      #   for an inserted leap second.
      def utc
        posix_time = posix

        if posix_time
          civil_from_posix(posix_time)
        else
          # An inserted leap second. Take the fields of the POSIX second
          # immediately before the leap second's transition time (the
          # 23:59:59 of the prior day) and report the second as 60.
          leap_second = @table.leap_second_for_continuous(@continuous)
          fields = civil_from_posix(leap_second.posix_time - 1)
          fields[5] = 60
          fields
        end
      end

      # Compares this {LeapTimestamp} with another based on the continuous
      # axis position.
      #
      # {LeapTimestamp} instances can only be compared if they use equal
      # {LeapSecondTable}s.
      #
      # @param leap_timestamp [LeapTimestamp] the {LeapTimestamp} to
      #   compare with.
      # @return [Integer] -1, 0 or 1, or `nil` if `leap_timestamp` is not
      #   a {LeapTimestamp} or uses a different {LeapSecondTable}.
      def <=>(leap_timestamp)
        return nil unless leap_timestamp.kind_of?(LeapTimestamp)
        return nil unless table == leap_timestamp.table
        continuous <=> leap_timestamp.continuous
      end

      alias eql? ==

      # @return [Integer] a hash based on the {LeapSecondTable} and the
      #   continuous axis position.
      def hash
        [@table, @continuous].hash
      end

      # @return [String] a `String` representation of this
      #   {LeapTimestamp} as YYYY-MM-DDTHH:MM:SSZ (with the second
      #   reported as 60 for an inserted leap second).
      def to_s
        year, month, day, hour, minute, second = utc
        self.class.send(:format_utc, year, month, day, hour, minute, second)
      end

      # @return [String] a `String` representation of this
      #   {LeapTimestamp}.
      def inspect
        "#<#{self.class}: #{self} (continuous: #{@continuous})>"
      end

      private

      # @param table [LeapSecondTable] the {LeapSecondTable}.
      # @param continuous [Integer] a position on the continuous seconds
      #   axis.
      def initialize!(table, continuous)
        @table = table
        @continuous = continuous
        freeze
      end

      # @param posix_time [Integer] a POSIX time.
      # @return [Array<Integer>] the UTC date and time
      #   `[year, month, day, hour, minute, second]` of `posix_time`.
      def civil_from_posix(posix_time)
        days, remainder = posix_time.divmod(SECONDS_PER_DAY)
        date = Date.jd(JD_EPOCH + days)
        year, month, day = date.year, date.month, date.day
        hour, remainder = remainder.divmod(3600)
        minute, second = remainder.divmod(60)
        [year, month, day, hour, minute, second]
      end
    end
  end
end
