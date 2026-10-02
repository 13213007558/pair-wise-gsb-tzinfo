# encoding: UTF-8
# frozen_string_literal: true

module TZInfo
  # A leap second table parsed from a TZif v2 or later file. It maps integer
  # positions on the continuous second axis to POSIX seconds and UTC calendar
  # labels, without folding inserted seconds or inventing removed seconds.
  class LeapSecondTable
    include Enumerable

    # @return [Integer] the first continuous-axis position covered by the
    #   table.
    attr_reader :valid_from

    # @return [Integer] the first continuous-axis position beyond the range
    #   reliably covered by the table.
    attr_reader :valid_until

    # @return [LeapSecond, nil] the record at which the table expires.
    attr_reader :expiration

    # Initializes a table from parsed TZif leap records.
    #
    # @param records [Array<LeapSecond>] raw TZif records, including any
    #   truncated-start or expiration boundary records.
    # @raise [LeapSecondError] if the records do not describe a valid table.
    # @private
    def initialize(records)
      records = records.dup
      validate_records(records)

      @start_boundary = records.first && records.first.start_boundary? ? records.shift : nil
      @expiration = records.last && records.last.expiration? ? records.pop : nil
      @records = records.freeze

      @valid_from = @start_boundary ? @start_boundary.at : 0
      @valid_until = @expiration ? @expiration.at : (@records.empty? ? @valid_from : @records.last.at + 1)
    end

    # @return [Array<LeapSecond>] actual positive and negative leap seconds in
    #   chronological order.
    def leap_seconds
      @records
    end

    # Yields each actual leap second.
    #
    # @yieldparam leap_second [LeapSecond] a leap second record.
    def each(&block)
      @records.each(&block)
    end

    # @return [Boolean] `true` if the continuous-axis position is within the
    #   range reliably represented by this table.
    def valid_continuous_second?(continuous_second)
      continuous_second.kind_of?(Integer) && continuous_second >= @valid_from && continuous_second < @valid_until
    end

    # @return [Boolean] `true` if the POSIX second is within the range
    #   reliably represented by this table.
    def valid_posix_second?(posix_second)
      posix_second.kind_of?(Integer) && posix_second >= first_posix_second && posix_second <= last_posix_second
    end

    # @return [Integer] the first represented POSIX second.
    def first_posix_second
      continuous_to_posix(@valid_from)
    end

    # @return [Integer] the last represented POSIX second. At a final positive
    #   leap second, this integer has both a regular and leap interpretation.
    def last_posix_second
      return continuous_to_posix(@valid_until - 1) unless @expiration
      @expiration.at - @expiration.previous_correction - 1
    end

    # Returns the UTC calendar fields for a continuous-axis second.
    #
    # @param continuous_second [Integer] an integer continuous second.
    # @return [Hash{Symbol => Object}] `:year`, `:month`, `:day`, `:hour`,
    #   `:minute`, `:second` and `:leap`.
    # @raise [LeapSecondOutOfRangeError] if the position is outside the known
    #   table range.
    def fields_for_continuous_second(continuous_second)
      check_continuous_second!(continuous_second)
      leap = event_at_continuous_second(continuous_second)

      if leap && leap.positive? && continuous_second == leap.at
        fields = Timestamp.send(:civil_fields_for_value, leap.at - leap.correction)
        fields[:second] = 60
        fields[:leap] = leap
      else
        fields = Timestamp.send(:civil_fields_for_value, continuous_to_posix(continuous_second))
        fields[:leap] = nil
      end

      fields
    end

    # Converts a continuous second to a POSIX second.
    #
    # @param continuous_second [Integer] an integer continuous second.
    # @return [Integer] the POSIX timestamp.
    # @raise [LeapSecondOutOfRangeError] if the position is outside the known
    #   table range.
    def continuous_to_posix(continuous_second)
      check_continuous_second!(continuous_second)
      leap = event_at_continuous_second(continuous_second)

      if leap && leap.positive? && continuous_second == leap.at
        leap.at - leap.correction
      else
        continuous_second - correction_at(continuous_second)
      end
    end

    # Converts a POSIX timestamp to its continuous second.
    #
    # @param posix_second [Integer] a POSIX timestamp.
    # @param second [Integer] the UTC second within the minute (normally 0-59,
    #   or 60 for an inserted leap second).
    # @return [Integer] the continuous-axis position.
    # @raise [LeapSecondOutOfRangeError] if a removed or leap second is
    #   encountered without an unambiguous explicit label, or the result is
    #   outside the known table range.
    def posix_to_continuous(posix_second, second = nil)
      raise ArgumentError, 'posix_second must be an Integer' unless posix_second.kind_of?(Integer)
      raise ArgumentError, 'second must be an Integer or nil' unless second.nil? || second.kind_of?(Integer)
      raise ArgumentError, 'second must be between 0 and 60' if second && (second < 0 || second > 60)
      check_posix_second!(posix_second)

      if second == 60
        return positive_leap_for_posix_second(posix_second).at
      end

      duplicate_positive_leap = positive_leap_for_posix_second(posix_second) rescue nil
      if duplicate_positive_leap
        if second.nil?
          raise LeapSecondOutOfRangeError, "POSIX second #{posix_second} is ambiguous: specify second 59 for the regular UTC second or 60 for the inserted leap second."
        end

        regular_second = Timestamp.send(:civil_fields_for_value, posix_second)[:second]
        if second == regular_second
          continuous_second = duplicate_positive_leap.at - 1
          check_continuous_second!(continuous_second)
          return continuous_second
        end

        raise LeapSecondOutOfRangeError, "UTC second #{second} does not match POSIX second #{posix_second} near an inserted leap second."
      end

      if removed_second?(posix_second)
        raise LeapSecondOutOfRangeError, "POSIX second #{posix_second} is a UTC second removed by a negative leap second." if second.nil? || second == 59

        previous_label = Timestamp.send(:civil_fields_for_value, posix_second - 1)[:second]
        next_label = Timestamp.send(:civil_fields_for_value, posix_second + 1)[:second]
        unless second == previous_label || second == next_label
          raise LeapSecondOutOfRangeError, "UTC second #{second} does not match POSIX second #{posix_second} near a removed leap second."
        end
      end

      continuous_second = continuous_for_posix_second(posix_second)
      check_continuous_second!(continuous_second)
      continuous_second
    end

    # Returns the cumulative correction at a continuous position.
    #
    # @param continuous_second [Integer] a continuous second.
    # @return [Integer] the signed cumulative correction.
    # @raise [LeapSecondOutOfRangeError] outside the known table range.
    def correction_at(continuous_second)
      check_continuous_second!(continuous_second)
      leap = event_at_continuous_second(continuous_second)
      leap ? leap.correction : initial_correction
    end

    # @return [String] a programmer-readable representation.
    def inspect
      "#<#{self.class}: #{@records.length} leap seconds, valid #{@valid_from}...#{@valid_until}>"
    end

    private

    def validate_records(records)
      previous = nil

      records.each_with_index do |record, index|
        unless record.kind_of?(LeapSecond)
          raise LeapSecondError, 'Leap second records must be LeapSecond instances.'
        end

        raise LeapSecondError, 'Leap second times must be non-negative.' if record.at < 0
        raise LeapSecondError, 'Leap second times must be strictly increasing.' if previous && record.at <= previous.at

        if record.start_boundary?
          unless index == 0 && record.correction != 0
            raise LeapSecondError, 'A truncated leap second table start must be the first record and have a non-zero correction.'
          end
        elsif record.expiration?
          unless index == records.length - 1 && (index == 0 ? record.correction == 0 : record.correction == previous.correction)
            raise LeapSecondError, 'A leap second expiration must be the final record and repeat the final correction.'
          end
        elsif previous
          difference = record.correction - previous.correction
          unless difference == 1 || difference == -1
            raise LeapSecondError, 'Leap second corrections must change by exactly 1.'
          end
        elsif ![-1, 1].include?(record.correction)
          raise LeapSecondError, 'The first leap second correction must be 1 or -1.'
        end

        previous = record
      end
    end

    def initial_correction
      @start_boundary ? @start_boundary.correction : 0
    end

    def event_at_continuous_second(continuous_second)
      @records.reverse_each.detect {|leap| leap.at <= continuous_second }
    end

    def continuous_for_posix_second(posix_second)
      @records.reverse_each do |leap|
        continuous_second = posix_second + leap.correction
        if leap.at <= continuous_second
          return continuous_second
        end
      end

      posix_second + initial_correction
    end

    def positive_leap_for_posix_second(posix_second)
      leap = @records.reverse_each.detect do |candidate|
        candidate.positive? && candidate.at - candidate.correction == posix_second
      end
      raise LeapSecondOutOfRangeError, "POSIX second #{posix_second} is not an inserted leap second." unless leap
      leap
    end

    def removed_second?(posix_second)
      @records.any? do |leap|
        leap.negative? && leap.at - leap.previous_correction == posix_second
      end
    end

    def check_continuous_second!(continuous_second)
      unless valid_continuous_second?(continuous_second)
        raise LeapSecondOutOfRangeError, "Continuous second #{continuous_second} is outside the known leap second table range (#{@valid_from}...#{@valid_until})."
      end
    end

    def check_posix_second!(posix_second)
      unless valid_posix_second?(posix_second)
        raise LeapSecondOutOfRangeError, "POSIX second #{posix_second} is outside the known leap second table range (#{first_posix_second}..#{last_posix_second})."
      end
    end
  end
end
