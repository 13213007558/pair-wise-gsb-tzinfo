# encoding: UTF-8
# frozen_string_literal: true

module TZInfo
  module LeapSeconds
    # A table of leap seconds, as found in TZif version 4 (and earlier)
    # zoneinfo files.
    #
    # A {LeapSecondTable} converts between two representations of time:
    #
    # - POSIX seconds - the number of seconds since 1970-01-01 00:00:00 UTC,
    #   ignoring leap seconds (as returned by `Time#to_i`). Every day is
    #   treated as if it were exactly 86,400 seconds long.
    # - Continuous axis positions - the number of seconds since 1970-01-01
    #   00:00:00 UTC, counting every elapsed second, including inserted leap
    #   seconds.
    #
    # A table can optionally have an expiration time. Conversions for times
    # at or after the expiration time raise {LeapSecondTableExpired} - it
    # cannot be assumed that no further leap seconds will be introduced
    # beyond the known range of the table.
    class LeapSecondTable
      # @return [Array<LeapSecond>] the leap seconds in the table, ordered
      #   by {LeapSecond#posix_time}.
      attr_reader :leap_seconds

      # @return [Integer] the POSIX time at which the table expires, or
      #   `nil` if the table does not define an expiration time. The
      #   correction that applies at and after this time is unknown.
      attr_reader :expires_at

      # Initializes a new {LeapSecondTable}.
      #
      # @param leap_seconds [Array<Object>] an `Array` of leap seconds, each
      #   either a {LeapSecond} or a two element `Array` of
      #   `[posix_time, correction]`, where `posix_time` is the first POSIX
      #   second `correction` applies to and `correction` is the total
      #   number of leap seconds in effect at and after `posix_time`.
      # @param expires_at [Integer] an optional POSIX time at which the
      #   table expires (`nil` for a table without an expiration time).
      # @raise [ArgumentError] if `leap_seconds` is not ordered by ascending
      #   `posix_time`, or if successive corrections do not differ by
      #   exactly one second.
      def initialize(leap_seconds = [], expires_at = nil)
        raise ArgumentError, 'expires_at must be an Integer or nil' if expires_at && !expires_at.kind_of?(Integer)

        previous_posix_time = nil
        previous_correction = nil

        @leap_seconds = leap_seconds.collect do |leap|
          posix_time, correction = if leap.kind_of?(LeapSecond)
            [leap.posix_time, leap.correction]
          else
            leap
          end

          raise ArgumentError, 'posix_time must be an Integer' unless posix_time.kind_of?(Integer)
          raise ArgumentError, 'correction must be an Integer' unless correction.kind_of?(Integer)

          if previous_posix_time && posix_time <= previous_posix_time
            raise ArgumentError, 'leap seconds must be ordered by ascending posix_time'
          end

          if previous_correction && (correction - previous_correction).abs != 1
            raise ArgumentError, 'successive corrections must differ by exactly one second'
          end

          unless previous_correction
            # Assume the correction changed by a single second at the first
            # entry (as is the case for all published leap second tables).
            previous_correction = correction - (correction <=> 0)
          end

          ls = LeapSecond.new(posix_time, correction, previous_correction)
          previous_posix_time = posix_time
          previous_correction = correction
          ls
        end.freeze

        @initial_correction = @leap_seconds.empty? ? 0 : @leap_seconds.first.previous_correction
        @expires_at = expires_at
        freeze
      end

      # @return [Boolean] whether the table contains no leap seconds.
      def empty?
        @leap_seconds.empty?
      end

      # Returns the total leap second correction in effect at a POSIX time.
      #
      # @param posix_time [Integer] a POSIX time (seconds since 1970-01-01
      #   00:00:00 UTC, ignoring leap seconds).
      # @return [Integer] the total number of leap seconds in effect at
      #   `posix_time`.
      # @raise [LeapSecondTableExpired] if `posix_time` is at or after the
      #   expiration time of the table.
      def correction_at(posix_time)
        check_posix_time_known!(posix_time)

        result = @initial_correction
        @leap_seconds.each do |leap_second|
          break if leap_second.posix_time > posix_time
          result = leap_second.correction
        end
        result
      end

      # Returns the {LeapSecond} entry taking effect at exactly the given
      # POSIX time.
      #
      # @param posix_time [Integer] a POSIX time.
      # @return [LeapSecond] the {LeapSecond} with
      #   {LeapSecond#posix_time} equal to `posix_time`, or `nil` if there
      #   is no such entry.
      def leap_second_at(posix_time)
        @leap_seconds.find {|ls| ls.posix_time == posix_time }
      end

      # Converts a POSIX time to a position on the continuous seconds axis.
      #
      # @param posix_time [Integer] a POSIX time (seconds since 1970-01-01
      #   00:00:00 UTC, ignoring leap seconds).
      # @return [Integer] the position on the continuous seconds axis
      #   corresponding to `posix_time`.
      # @raise [UtcSecondNotFound] if `posix_time` identifies a UTC second
      #   that was removed by a negative leap second.
      # @raise [LeapSecondTableExpired] if `posix_time` is at or after the
      #   expiration time of the table.
      def to_continuous(posix_time)
        check_posix_time_known!(posix_time)

        deleted = @leap_seconds.find {|ls| ls.negative? && ls.deleted_posix_time == posix_time }
        if deleted
          raise UtcSecondNotFound, "The UTC second at POSIX time #{posix_time} was removed by a negative leap second"
        end

        posix_time + correction_at(posix_time)
      end

      # Converts a position on the continuous seconds axis to a POSIX time.
      #
      # @param continuous [Integer] a position on the continuous seconds
      #   axis.
      # @return [Integer] the POSIX time corresponding to `continuous`, or
      #   `nil` if `continuous` identifies an inserted leap second (which
      #   has no POSIX time representation).
      # @raise [LeapSecondTableExpired] if `continuous` is beyond the known
      #   range of the table.
      def posix_for_continuous(continuous)
        check_continuous_known!(continuous)
        return nil if leap_second_for_continuous(continuous)

        correction = @initial_correction
        @leap_seconds.each do |leap_second|
          break if leap_second.posix_time + leap_second.correction > continuous
          correction = leap_second.correction
        end

        continuous - correction
      end

      # Returns the positive {LeapSecond} that inserted the UTC second at a
      # position on the continuous seconds axis.
      #
      # @param continuous [Integer] a position on the continuous seconds
      #   axis.
      # @return [LeapSecond] the {LeapSecond} that inserted the second at
      #   `continuous`, or `nil` if `continuous` does not identify an
      #   inserted leap second.
      def leap_second_for_continuous(continuous)
        @leap_seconds.find {|ls| ls.positive? && ls.inserted_continuous == continuous }
      end

      # Compares this {LeapSecondTable} with another based on the leap
      # seconds and expiration time.
      #
      # @param table [LeapSecondTable] the {LeapSecondTable} to compare
      #   with.
      # @return [Boolean] whether `table` is a {LeapSecondTable} containing
      #   the same leap seconds and expiration time.
      def ==(table)
        table.kind_of?(LeapSecondTable) &&
          leap_seconds == table.leap_seconds &&
          expires_at == table.expires_at
      end

      alias eql? ==

      # @return [Integer] a hash based on the leap seconds and expiration
      #   time.
      def hash
        [@leap_seconds, @expires_at].hash
      end

      # @return [String] a `String` representation of this
      #   {LeapSecondTable}.
      def inspect
        "#<#{self.class}: #{@leap_seconds.length} leap seconds, @expires_at=#{@expires_at.inspect}>"
      end

      private

      # @param posix_time [Integer] a POSIX time to check.
      # @raise [LeapSecondTableExpired] if `posix_time` is at or after the
      #   expiration time of the table.
      def check_posix_time_known!(posix_time)
        if @expires_at && posix_time >= @expires_at
          raise LeapSecondTableExpired, "POSIX time #{posix_time} is at or after the expiration of the leap second table (#{@expires_at})"
        end
      end

      # @param continuous [Integer] a continuous axis position to check.
      # @raise [LeapSecondTableExpired] if `continuous` is beyond the known
      #   range of the table.
      def check_continuous_known!(continuous)
        if @expires_at
          last_known = @expires_at - 1 + correction_at(@expires_at - 1)
          if continuous > last_known
            raise LeapSecondTableExpired, "Continuous axis position #{continuous} is beyond the expiration of the leap second table"
          end
        end
      end
    end
  end
end
