# encoding: UTF-8
# frozen_string_literal: true

module TZInfo
  module LeapSeconds
    # A single entry in a {LeapSecondTable}, representing a change to the
    # total leap second correction at a given point in time.
    #
    # A positive leap second inserts an additional UTC second (labeled
    # 23:59:60) immediately before {#posix_time}. A negative leap second
    # removes the UTC second immediately before {#posix_time} (23:59:59 of
    # the prior day).
    class LeapSecond
      include Comparable

      # @return [Integer] the first POSIX second (a time as returned by
      #   `Time#to_i`, ignoring leap seconds) at which {#correction}
      #   applies. The leap second itself occurs immediately before this
      #   time.
      attr_reader :posix_time

      # @return [Integer] the total number of leap seconds in effect at and
      #   after {#posix_time}.
      attr_reader :correction

      # @return [Integer] the total number of leap seconds in effect before
      #   {#posix_time}.
      attr_reader :previous_correction

      # Initializes a new {LeapSecond}.
      #
      # @param posix_time [Integer] the first POSIX second at which
      #   `correction` applies.
      # @param correction [Integer] the total number of leap seconds in
      #   effect at and after `posix_time`.
      # @param previous_correction [Integer] the total number of leap seconds
      #   in effect before `posix_time`.
      # @raise [ArgumentError] if any parameter is not an `Integer`.
      def initialize(posix_time, correction, previous_correction)
        raise ArgumentError, 'posix_time must be an Integer' unless posix_time.kind_of?(Integer)
        raise ArgumentError, 'correction must be an Integer' unless correction.kind_of?(Integer)
        raise ArgumentError, 'previous_correction must be an Integer' unless previous_correction.kind_of?(Integer)

        @posix_time = posix_time
        @correction = correction
        @previous_correction = previous_correction
        freeze
      end

      # @return [Integer] the change to the correction at {#posix_time}
      #   (+1 for an inserted leap second, -1 for a removed leap second).
      def delta
        @correction - @previous_correction
      end

      # @return [Boolean] whether this {LeapSecond} inserts a UTC second
      #   (a 23:59:60).
      def positive?
        delta > 0
      end

      # @return [Boolean] whether this {LeapSecond} removes a UTC second
      #   (a 23:59:59).
      def negative?
        delta < 0
      end

      # The position on the continuous seconds axis of the inserted UTC
      # second (only meaningful for a positive leap second).
      #
      # @return [Integer] the continuous axis position of the inserted
      #   second, or `nil` if this is not a positive leap second.
      def inserted_continuous
        positive? ? @posix_time + @previous_correction : nil
      end

      # The POSIX time of the UTC second that was removed (only meaningful
      # for a negative leap second).
      #
      # @return [Integer] the POSIX time of the removed second, or `nil` if
      #   this is not a negative leap second.
      def deleted_posix_time
        negative? ? @posix_time - 1 : nil
      end

      # Compares this {LeapSecond} with another based on {#posix_time}.
      #
      # @param leap_second [LeapSecond] the {LeapSecond} to compare with.
      # @return [Integer] -1, 0 or 1, or `nil` if `leap_second` is not a
      #   {LeapSecond}.
      def <=>(leap_second)
        return nil unless leap_second.kind_of?(LeapSecond)
        result = posix_time <=> leap_second.posix_time
        result = correction <=> leap_second.correction if result == 0
        result = previous_correction <=> leap_second.previous_correction if result == 0
        result
      end

      alias eql? ==

      # @return [Integer] a hash based on {#posix_time}, {#correction} and
      #   {#previous_correction}.
      def hash
        [@posix_time, @correction, @previous_correction].hash
      end

      # @return [String] a `String` representation of this {LeapSecond}.
      def inspect
        "#<#{self.class}: @posix_time=#{@posix_time}, @correction=#{@correction}, @previous_correction=#{@previous_correction}>"
      end
    end
  end
end
