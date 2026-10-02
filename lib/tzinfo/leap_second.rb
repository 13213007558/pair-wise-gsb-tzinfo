# encoding: UTF-8
# frozen_string_literal: true

module TZInfo
  # Represents one positive or negative leap second recorded in a TZif file.
  # Start and expiration boundary records are represented internally by the
  # same class with {#event?} returning `false`.
  class LeapSecond
    include Comparable

    # @return [Integer] the position on the continuous second axis.
    attr_reader :at

    # @return [Integer] the cumulative leap-second correction in effect at
    #   {#at}.
    attr_reader :correction

    # @return [Integer] the cumulative correction immediately before this
    #   record.
    attr_reader :previous_correction

    # Initializes an ordinary leap second.
    #
    # @param at [Integer] the continuous-axis position.
    # @param correction [Integer] the cumulative correction after the leap.
    # @raise [ArgumentError] if either parameter is not an Integer.
    def initialize(at, correction)
      raise ArgumentError, 'at must be an Integer' unless at.kind_of?(Integer)
      raise ArgumentError, 'correction must be an Integer' unless correction.kind_of?(Integer)
      raise ArgumentError, 'correction must not be zero' if correction == 0
      previous = correction > 0 ? correction - 1 : correction + 1
      initialize!(at, correction, previous, false, false)
    end

    # Constructs a record without validating parameters.
    #
    # @param at [Integer] the continuous-axis position.
    # @param correction [Integer] the cumulative correction at {#at}.
    # @param previous_correction [Integer] the prior cumulative correction.
    # @param start_boundary [Boolean] whether this is a truncated start.
    # @param expiration [Boolean] whether this is an expiration record.
    # @return [LeapSecond] the new record.
    # @private
    def self.new!(at, correction, previous_correction, start_boundary, expiration)
      result = allocate
      result.send(:initialize!, at, correction, previous_correction, start_boundary, expiration)
      result
    end

    # @return [Integer] the signed size of this leap second (`1` for an
    #   inserted second, `-1` for a removed second and `0` for a boundary).
    def delta
      event? ? correction <=> previous_correction : 0
    end

    # @return [Boolean] `true` if this record is an actual leap second.
    def event?
      !@start_boundary && !@expiration
    end

    # @return [Boolean] `true` if this is an inserted positive leap second.
    def positive?
      delta > 0
    end

    # @return [Boolean] `true` if this is a removed negative leap second.
    def negative?
      delta < 0
    end

    # @return [Boolean] `true` if this record marks a truncated table start.
    def start_boundary?
      @start_boundary
    end

    # @return [Boolean] `true` if this record marks table expiration.
    def expiration?
      @expiration
    end

    # Compares this leap second with another according to {#at}.
    #
    # @param other [Object] the object to compare with.
    # @return [Integer, nil] `-1`, `0` or `1`, or `nil` if `other` is not a
    #   {LeapSecond}.
    def <=>(other)
      return nil unless other.kind_of?(LeapSecond)
      [at, correction] <=> [other.at, other.correction]
    end

    alias eql? ==

    # @return [Integer] a hash based on {#at} and {#correction}.
    def hash
      [at, correction].hash
    end

    # @return [String] a programmer-readable representation.
    def inspect
      "#<#{self.class}: @at=#{at}, @correction=#{correction}>"
    end

    private

    def initialize!(at, correction, previous_correction, start_boundary, expiration)
      @at = at
      @correction = correction
      @previous_correction = previous_correction
      @start_boundary = start_boundary
      @expiration = expiration
    end
  end
end
