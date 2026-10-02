# encoding: UTF-8
# frozen_string_literal: true

module TZInfo
  # Raised when a sequence of local times cannot be assigned UTC times while
  # satisfying the requested ordering and interval constraints.
  class InvalidLocalTimeSequence < ArgumentError
    # @return [Integer] the zero-based index of the record where the conflict
    #   was detected.
    attr_reader :index

    # @return [Integer, nil] the zero-based index of the preceding record for
    #   an adjacent-record conflict, or `nil` when the record at {#index} is an
    #   invalid local time.
    attr_reader :previous_index

    # @return [Symbol] the reason the sequence was rejected. Possible values
    #   are `:invalid_local_time` and `:interval_or_order`.
    attr_reader :reason

    # Initializes a new {InvalidLocalTimeSequence}.
    #
    # @param message [String] the exception message.
    # @param index [Integer] the zero-based index of the conflicting record.
    # @param previous_index [Integer, nil] the zero-based index of the preceding
    #   record, or `nil`.
    # @param reason [Symbol] the reason the sequence was rejected.
    def initialize(message, index, previous_index = nil, reason = :interval_or_order)
      super(message)
      @index = index
      @previous_index = previous_index
      @reason = reason
    end
  end

  # Represents the result of resolving one local time in a sequence. A record
  # has one possible UTC time when the surrounding sequence constrains it
  # uniquely, otherwise it has all globally feasible UTC times.
  class LocalTimeSequenceRecord
    # @return [Integer] the zero-based position of the local time in the input
    #   sequence.
    attr_reader :index

    # @return [Object] the local time supplied by the caller. The UTC offset of
    #   this object is ignored.
    attr_reader :local_time

    # Initializes a new {LocalTimeSequenceRecord}.
    #
    # @param index [Integer] the zero-based position of the record.
    # @param local_time [Object] the local time supplied by the caller.
    # @param utc_times [Array<Object>] the UTC times that are feasible within
    #   the complete sequence.
    def initialize(index, local_time, utc_times)
      @index = index
      @local_time = local_time
      @utc_times = utc_times
    end

    # @return [Boolean] `true` if exactly one UTC time is feasible for this
    #   record, otherwise `false`.
    def unique?
      @utc_times.length == 1
    end

    # @return [Boolean] `true` if more than one UTC time remains feasible for
    #   this record, otherwise `false`.
    def ambiguous?
      @utc_times.length > 1
    end

    # @return [Object, nil] the unique feasible UTC time, or `nil` when the
    #   record remains ambiguous.
    def utc_time
      @utc_times.first if unique?
    end

    # @return [Array<Object>] all UTC times that remain feasible within the
    #   complete sequence, sorted chronologically.
    def utc_times
      @utc_times.clone
    end

    # @return [Integer] the number of feasible UTC times.
    def possibility_count
      @utc_times.length
    end
  end

  # Represents the complete result of resolving a sequence of local times.
  class LocalTimeSequenceResolution
    include Enumerable

    # @return [Timezone] the time zone used to interpret the local times.
    attr_reader :timezone

    # @return [Symbol] the requested ordering (`:non_decreasing` or
    #   `:strict`).
    attr_reader :order

    # @return [Numeric] the minimum allowed interval between adjacent UTC
    #   times.
    attr_reader :min_interval

    # @return [Numeric] the maximum allowed interval between adjacent UTC
    #   times.
    attr_reader :max_interval

    # Initializes a new {LocalTimeSequenceResolution}.
    #
    # @param timezone [Timezone] the time zone used to interpret the local
    #   times.
    # @param records [Array<LocalTimeSequenceRecord>] the resolved records.
    # @param order [Symbol] the requested ordering.
    # @param min_interval [Numeric] the minimum adjacent interval in seconds.
    # @param max_interval [Numeric] the maximum adjacent interval in seconds.
    def initialize(timezone, records, order, min_interval, max_interval)
      @timezone = timezone
      @records = records
      @order = order
      @min_interval = min_interval
      @max_interval = max_interval
    end

    # Yields each resolved record.
    #
    # @yieldparam record [LocalTimeSequenceRecord] a resolved record.
    # @return [Enumerator, LocalTimeSequenceResolution] an `Enumerator` when no
    #   block is given, otherwise `self`.
    def each(&block)
      return @records.each unless block_given?
      @records.each(&block)
      self
    end

    # @param index [Integer] the zero-based record index.
    # @return [LocalTimeSequenceRecord] the record at `index`.
    def [](index)
      @records[index]
    end

    # @return [Integer] the number of records.
    def length
      @records.length
    end
    alias size length

    # @return [Array<Integer>] indexes with exactly one feasible UTC time.
    def unique_indexes
      collect_indexes {|record| record.unique? }
    end

    # @return [Array<Integer>] indexes with more than one feasible UTC time.
    def ambiguous_indexes
      collect_indexes {|record| record.ambiguous? }
    end

    # @return [Array<Object>] UTC times for uniquely resolved records. Ambiguous
    #   records contribute `nil`.
    def utc_times
      @records.collect {|record| record.unique? ? record.utc_time : nil }
    end

    # @return [Array<Array<Object>>] the feasible UTC times for each record.
    def possible_utc_times
      @records.collect {|record| record.utc_times }
    end

    private

    def collect_indexes
      result = []
      @records.each_with_index {|record, index| result << index if yield record }
      result
    end
  end

  # @private
  # Resolves a sequence of local wall-clock times using forward and backward
  # reachability without enumerating the Cartesian product of ambiguous local
  # times.
  class LocalTimeSequenceResolver
    def initialize(timezone, local_times, min_interval, max_interval, order)
      @timezone = timezone
      @local_times = local_times.to_a
      @min_interval = min_interval
      @max_interval = max_interval
      @order = order
    end

    def resolve
      candidates = []
      forward = build_forward_reachability(candidates)
      feasible = build_backward_reachability(candidates, forward)

      records = @local_times.each_with_index.collect do |local_time, index|
        utc_timestamps = candidates[index].each_with_index.collect do |candidate, candidate_index|
          candidate[:timestamp] if feasible[index][candidate_index]
        end.compact

        LocalTimeSequenceRecord.new(index, local_time, utc_timestamps.collect {|timestamp| convert(index, timestamp) })
      end

      LocalTimeSequenceResolution.new(@timezone, records, @order, @min_interval, @max_interval)
    end

    private

    def candidates_for(index)
      local_time = @local_times[index]

      begin
        local_timestamp = Timestamp.for(local_time, :ignore)
        periods = @timezone.periods_for_local(local_timestamp)

        if periods.empty?
          raise InvalidLocalTimeSequence.new("local_time at index #{index} is not a valid local time for the time zone.", index, nil, :invalid_local_time)
        end

        values = {}

        periods.each do |period|
          value = local_timestamp.value.to_r + local_timestamp.sub_second - period.observed_utc_offset
          next if values.has_key?(value)
          value_integer = value.floor
          values[value] = Timestamp.utc(value_integer, value - value_integer)
        end

        values.keys.sort.collect {|value| {:value => value, :timestamp => values[value]} }
      rescue InvalidLocalTimeSequence
        raise
      rescue ArgumentError => e
        raise ArgumentError, "local_time at index #{index} is not supported: #{e.message}"
      end
    end

    def build_forward_reachability(candidates)
      forward = []

      @local_times.each_index do |index|
        record_candidates = candidates_for(index)
        candidates[index] = record_candidates

        forward[index] = record_candidates.collect do |candidate|
          if index == 0
            true
          else
            candidates[index - 1].each_with_index.any? do |previous_candidate, previous_index|
              forward[index - 1][previous_index] && valid_interval?(previous_candidate, candidate)
            end
          end
        end

        unless forward[index].any?
          raise InvalidLocalTimeSequence.new("No UTC assignment satisfies the ordering and interval bounds between indexes #{index - 1} and #{index}.", index, index - 1)
        end
      end

      forward
    end

    def build_backward_reachability(candidates, forward)
      backward = Array.new(candidates.length)
      return backward if candidates.empty?

      backward[-1] = candidates[-1].collect { true }

      (candidates.length - 2).downto(0) do |index|
        backward[index] = candidates[index].each_with_index.collect do |candidate, candidate_index|
          forward[index][candidate_index] && candidates[index + 1].each_with_index.any? do |next_candidate, next_index|
            backward[index + 1][next_index] && valid_interval?(candidate, next_candidate)
          end
        end
      end

      backward
    end

    def valid_interval?(previous_candidate, candidate)
      interval = candidate[:value] - previous_candidate[:value]
      return false if interval < 0
      return false if @order == :strict && interval == 0
      interval >= @min_interval && interval <= @max_interval
    end

    def convert(index, utc_timestamp)
      Timestamp.for(@local_times[index], :ignore) { utc_timestamp }
    end
  end
end
