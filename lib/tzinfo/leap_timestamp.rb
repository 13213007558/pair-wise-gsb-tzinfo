# encoding: UTF-8
# frozen_string_literal: true

module TZInfo
  # Represents an integer position on the continuous second axis together with
  # its UTC calendar interpretation in a {LeapSecondTable}. This representation
  # distinguishes regular UTC seconds from inserted positive leap seconds and
  # never invents a label for a removed negative leap second.
  class LeapTimestamp
    include Comparable

    # @return [LeapSecondTable] the table used to interpret this timestamp.
    attr_reader :table

    # @return [Integer] the integer position on the continuous second axis.
    attr_reader :continuous_second

    # @return [Numeric] the fraction of a second elapsed since
    #   {#continuous_second}.
    attr_reader :sub_second

    # Initializes a timestamp from a continuous-axis position.
    #
    # @param table [LeapSecondTable] the leap second table.
    # @param continuous_second [Integer] the continuous-axis position.
    # @param sub_second [Numeric] the fraction within the second.
    # @raise [ArgumentError] for invalid parameters.
    # @raise [LeapSecondOutOfRangeError] outside the table's known range.
    def initialize(table, continuous_second, sub_second = 0)
      raise ArgumentError, 'table must be a LeapSecondTable' unless table.kind_of?(LeapSecondTable)
      raise ArgumentError, 'continuous_second must be an Integer' unless continuous_second.kind_of?(Integer)
      raise ArgumentError, 'sub_second must be a Rational or the Integer 0' unless (sub_second.kind_of?(Integer) && sub_second == 0) || sub_second.kind_of?(Rational)
      raise RangeError, 'sub_second must be >= 0 and < 1' if sub_second < 0 || sub_second >= 1
      table.correction_at(continuous_second)

      @table = table
      @continuous_second = continuous_second
      @sub_second = sub_second == 0 ? 0 : sub_second
    end

    # Creates a leap-aware timestamp from UTC calendar fields.
    #
    # @param table [LeapSecondTable] the leap second table.
    # @param year [Integer] the year.
    # @param month [Integer] the month.
    # @param day [Integer] the day.
    # @param hour [Integer] the hour.
    # @param minute [Integer] the minute.
    # @param second [Integer] the second (0-60).
    # @param sub_second [Numeric] the fraction within the second.
    # @return [LeapTimestamp] the timestamp.
    # @raise [LeapSecondOutOfRangeError] for removed seconds or unknown ranges.
    def self.utc(table, year, month = 1, day = 1, hour = 0, minute = 0, second = 0, sub_second = 0)
      raise ArgumentError, 'second must be between 0 and 60' unless second.kind_of?(Integer) && second >= 0 && second <= 60
      posix_second = Timestamp.create(year, month, day, hour, minute, second == 60 ? 59 : second).value
      continuous_second = table.posix_to_continuous(posix_second, second)
      new(table, continuous_second, sub_second)
    end

    # Creates a leap-aware timestamp from a POSIX timestamp. At a positive leap
    # second boundary, use {utc} with `second = 60` to select the inserted
    # second rather than the following regular second.
    #
    # @param table [LeapSecondTable] the leap second table.
    # @param posix_second [Integer] the POSIX timestamp.
    # @param sub_second [Numeric] the fraction within the second.
    # @return [LeapTimestamp] the timestamp.
    def self.from_posix(table, posix_second, sub_second = 0)
      new(table, table.posix_to_continuous(posix_second), sub_second)
    end

    # @return [Integer] the year in UTC.
    def year
      fields[:year]
    end

    # @return [Integer] the month in UTC (1-12).
    def month
      fields[:month]
    end

    # @return [Integer] the day of month in UTC.
    def day
      fields[:day]
    end

    # @return [Integer] the hour in UTC (0-23).
    def hour
      fields[:hour]
    end

    # @return [Integer] the minute in UTC (0-59).
    def minute
      fields[:minute]
    end

    # @return [Integer] the second in UTC (0-60).
    def second
      fields[:second]
    end

    # @return [LeapSecond, nil] the positive leap second represented by this
    #   timestamp, or `nil` for a regular UTC second.
    def leap_second
      fields[:leap]
    end

    # @return [Symbol] `:leap_second` for an inserted second, otherwise
    #   `:utc_second`.
    def kind
      leap_second ? :leap_second : :utc_second
    end

    # @return [Boolean] `true` for an inserted positive leap second.
    def leap_second?
      !!leap_second
    end

    # @return [Integer] the unambiguous POSIX timestamp for a regular second,
    #   or the repeated POSIX timestamp for an inserted leap second.
    def posix_second
      @table.continuous_to_posix(@continuous_second)
    end

    alias to_i continuous_second

    # Returns a Ruby `Time` only for a regular UTC second. Conversion of an
    # inserted leap second raises because Ruby Time uses POSIX semantics and
    # would otherwise fold `23:59:60` into a neighboring second.
    #
    # @return [Time] a regular UTC time.
    # @raise [LeapSecondError] if this is an inserted leap second.
    def to_time
      raise LeapSecondOutOfRangeError, 'Cannot convert an inserted leap second to Time without collapsing it.' if leap_second?
      Time.at(posix_second, @sub_second * 1_000_000).utc
    end

    # @return [String] the UTC timestamp using ISO 8601-like formatting with a
    #   second value of 60 where appropriate.
    def to_s
      f = fields
      '%04d-%02d-%02d %02d:%02d:%02d%s UTC' % [f[:year], f[:month], f[:day], f[:hour], f[:minute], f[:second], sub_second_to_s]
    end

    # Compares timestamps by continuous position and fractional second.
    #
    # @param other [Object] the timestamp to compare.
    # @return [Integer, nil] `-1`, `0`, `1`, or `nil` if `other` is not a
    #   {LeapTimestamp}.
    def <=>(other)
      return nil unless other.kind_of?(LeapTimestamp)
      result = continuous_second <=> other.continuous_second
      result = sub_second <=> other.sub_second if result == 0
      result
    end

    alias eql? ==

    # @return [Integer] a hash based on the continuous position and fraction.
    def hash
      [@continuous_second, @sub_second].hash
    end

    # @return [String] a programmer-readable representation.
    def inspect
      "#<#{self.class}: #{to_s}, continuous_second=#{@continuous_second}>"
    end

    private

    def fields
      @fields ||= @table.fields_for_continuous_second(@continuous_second)
    end

    def sub_second_to_s
      @sub_second == 0 ? '' : " #{@sub_second.numerator}/#{@sub_second.denominator}"
    end
  end
end
