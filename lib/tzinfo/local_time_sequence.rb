# encoding: UTF-8
# frozen_string_literal: true

module TZInfo
  # Represents the result of resolving a sequence of local times to UTC.
  class LocalTimeSequenceResult
    # @return [Array<Array<Timestamp>>] for each local time, the possible UTC
    #   {Timestamp} instances that are compatible with the sequence constraints.
    #   When {#impossible?} is `true`, possible UTC times are only returned up
    #   to (but excluding) {#conflict_index}.
    attr_reader :possible_utc_times

    # @return [Integer, nil] the zero-based index of the first local time at
    #   which no compatible continuation exists, or `nil` if the whole sequence
    #   is possible.
    attr_reader :conflict_index

    # @return [Symbol, nil] either `:invalid_local_time` or
    #   `:inconsistent_interval` when {#conflict_index} is set, otherwise
    #   `nil`.
    attr_reader :conflict_reason

    # @!visibility private
    def initialize(possible_utc_times, record_count = possible_utc_times.length,
      conflict_index = nil, conflict_reason = nil)
      @possible_utc_times = possible_utc_times
      @record_count = record_count
      @conflict_index = conflict_index
      @conflict_reason = conflict_reason
    end

    # @return [Boolean] `true` if every local time in the sequence has exactly
    #   one compatible UTC representation, otherwise `false`.
    def uniquely_determined?
      !impossible? && @possible_utc_times.all? {|times| times.length == 1 }
    end

    # @return [Boolean] `true` if at least one local time has more than one
    #   compatible UTC representation, otherwise `false`.
    def ambiguous?
      !impossible? && @possible_utc_times.any? {|times| times.length > 1 }
    end

    # @return [Boolean] `true` if there is no sequence of UTC times satisfying
    #   all the constraints, otherwise `false`.
    def impossible?
      !!@conflict_index
    end

    # @return [Array<Timestamp>] the uniquely determined UTC time for each local
    #   time. Local times that remain ambiguous are represented by `nil`.
    #   Returns an empty `Array` when {#impossible?} is `true`.
    def utc_times
      return [] if impossible?
      @possible_utc_times.collect {|times| times.length == 1 ? times.first : nil }
    end

    # @return [Array<Symbol>] one status for each input local time: either
    #   `:unique`, `:ambiguous`, `:invalid_local_time` or `:conflict`.
    def statuses
      result = @possible_utc_times.collect {|times| times.length == 1 ? :unique : :ambiguous }

      if impossible?
        result << nil while result.length < @conflict_index
        result << (@conflict_reason == :invalid_local_time ? :invalid_local_time : :conflict)
        result.fill(:conflict, result.length...@record_count)
      end

      result
    end
  end

  # Resolves ambiguities in an ordered sequence of local times using the allowed
  # range of real intervals between consecutive events.
  #
  # Each local time can have one or two valid UTC representations during a
  # repeated hour. Rather than enumerating all combinations, resolution is
  # performed in linear time with prefix and suffix reachability arrays.
  #
  # @!visibility private
  class LocalTimeSequence
    def initialize(timezone, local_times, options = {})
      raise ArgumentError, 'timezone must be specified' unless timezone
      raise ArgumentError, 'local_times must be specified' unless local_times

      @timezone = timezone
      unless local_times.respond_to?(:to_a)
        raise ArgumentError, 'local_times must be an Enumerable'
      end

      @local_times = local_times.to_a
      raise ArgumentError, 'local_times must not be empty' if @local_times.empty?
      raise ArgumentError, 'local_times must not contain nil' if @local_times.any?(&:nil?)

      unless options.is_a?(Hash)
        raise ArgumentError, 'options must be a Hash'
      end

      unknown_options = options.keys - [:order, :min_interval, :max_interval]
      unless unknown_options.empty?
        raise ArgumentError, 'unknown options: ' + unknown_options.join(', ')
      end

      unless options.key?(:order)
        raise ArgumentError, 'order must be specified as :non_decreasing or :strictly_increasing'
      end

      @strictly_increasing = case options[:order]
        when :strictly_increasing then true
        when :non_decreasing then false
        else raise ArgumentError, 'order must be :non_decreasing or :strictly_increasing'
      end

      @min_interval = options.fetch(:min_interval, 0)
      @max_interval = options.fetch(:max_interval, nil)

      unless @min_interval.kind_of?(Numeric) && @min_interval >= 0
        raise ArgumentError, 'min_interval must be a non-negative Numeric'
      end

      if @max_interval
        raise ArgumentError, 'max_interval must be a Numeric' unless @max_interval.kind_of?(Numeric)
        if @max_interval < @min_interval
          raise ArgumentError,
            'max_interval must be greater than or equal to min_interval'
        end
      end
    end

    def resolve
      candidates = []
      prefix = []

      @local_times.each_with_index do |local_time, index|
        times = candidates_for(local_time)

        if times.empty?
          return impossible_result(candidates, prefix, index, :invalid_local_time)
        end

        states = index == 0 ? times.collect { true } : reachable_states(candidates.last, times, prefix.last)

        unless states.any?
          return impossible_result(candidates, prefix, index, :inconsistent_interval)
        end

        candidates << times
        prefix << states
      end

      suffix = suffix_reachable(candidates)
      possible = candidates.each_with_index.collect do |times, index|
        times.each_with_index.collect do |time, candidate_index|
          time if prefix[index][candidate_index] && suffix[index][candidate_index]
        end.compact
      end

      LocalTimeSequenceResult.new(possible)
    end

    private

    def candidates_for(local_time)
      local_timestamp = Timestamp.for(local_time, :ignore)
      @timezone.periods_for_local(local_timestamp).collect do |period|
        Timestamp.utc(local_timestamp.value - period.observed_utc_offset, local_timestamp.sub_second)
      end.uniq.sort
    end

    def reachable_states(previous_times, current_times, previous_states)
      current_times.collect do |current|
        previous_times.each_with_index.any? do |previous, previous_index|
          previous_states[previous_index] && allowed_interval?(previous, current)
        end
      end
    end

    def suffix_reachable(candidates)
      reachable = Array.new(candidates.length)
      reachable[reachable.length - 1] = candidates.last.collect { true }

      (candidates.length - 2).downto(0) do |index|
        reachable[index] = candidates[index].collect do |current|
          candidates[index + 1].each_with_index.any? do |following, following_index|
            reachable[index + 1][following_index] && allowed_interval?(current, following)
          end
        end
      end

      reachable
    end

    def allowed_interval?(earlier, later)
      elapsed = later.value - earlier.value + later.sub_second - earlier.sub_second
      return false if elapsed < 0
      return false if @strictly_increasing && elapsed == 0
      elapsed >= @min_interval && (@max_interval.nil? || elapsed <= @max_interval)
    end

    def impossible_result(candidates, prefix, conflict_index, reason)
      possible = candidates.each_with_index.collect do |times, index|
        times.each_with_index.collect {|time, candidate_index| time if prefix[index][candidate_index] }.compact
      end
      LocalTimeSequenceResult.new(possible, @local_times.length, conflict_index, reason)
    end
  end
end
