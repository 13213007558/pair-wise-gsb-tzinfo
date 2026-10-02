# encoding: UTF-8
# frozen_string_literal: true

require_relative 'test_utils'

class TCLocalTimeSequenceResolution < Minitest::Test
  include TZInfo

  def setup
    @tz = Timezone.get('Europe/London')
  end

  def test_ambiguous_records_remain_multiple_possibilities
    local_times = [
      Time.utc(2004, 10, 31, 1, 30),
      Time.utc(2004, 10, 31, 1, 31),
      Time.utc(2004, 10, 31, 2, 30)
    ]

    resolution = @tz.disambiguate_local_sequence(local_times, 0, 7200, :order => :strict)

    assert_equal([0, 1], resolution.ambiguous_indexes)
    assert_equal([2], resolution.unique_indexes)
    assert_nil(resolution[0].utc_time)
    assert_equal(2, resolution[0].possibility_count)
    assert_equal([
      Time.utc(2004, 10, 31, 0, 30),
      Time.utc(2004, 10, 31, 1, 30)
    ], resolution[0].utc_times)
    assert_equal([
      Time.utc(2004, 10, 31, 0, 31),
      Time.utc(2004, 10, 31, 1, 31)
    ], resolution[1].utc_times)
    assert_equal(Time.utc(2004, 10, 31, 2, 30), resolution[2].utc_time)
    assert_equal([nil, nil, Time.utc(2004, 10, 31, 2, 30)], resolution.utc_times)
  end

  def test_surrounding_interval_constrains_candidates
    local_times = [
      Time.utc(2004, 10, 31, 1, 30),
      Time.utc(2004, 10, 31, 1, 31),
      Time.utc(2004, 10, 31, 2, 30)
    ]

    resolution = @tz.disambiguate_local_sequence(local_times, 1800, 3660, :order => :strict)

    assert_equal([0, 1, 2], resolution.unique_indexes)
    assert_equal([], resolution.ambiguous_indexes)
    assert_equal(Time.utc(2004, 10, 31, 0, 30), resolution[0].utc_time)
    assert_equal(Time.utc(2004, 10, 31, 1, 31), resolution[1].utc_time)
    assert_equal(Time.utc(2004, 10, 31, 2, 30), resolution[2].utc_time)
  end

  def test_non_decreasing_allows_equal_real_times
    local_times = [Time.utc(2004, 10, 31, 1, 30), Time.utc(2004, 10, 31, 1, 30)]

    resolution = @tz.disambiguate_local_sequence(local_times, 0, 0, :order => :non_decreasing)

    assert_equal([0, 1], resolution.ambiguous_indexes)
    assert_equal([
      Time.utc(2004, 10, 31, 0, 30),
      Time.utc(2004, 10, 31, 1, 30)
    ], resolution[0].utc_times)
  end

  def test_strict_rejects_equal_real_times
    local_times = [Time.utc(2004, 10, 31, 1, 30), Time.utc(2004, 10, 31, 1, 30)]

    error = assert_raises(InvalidLocalTimeSequence) do
      @tz.disambiguate_local_sequence(local_times, 0, 0, :order => :strict)
    end

    assert_equal(1, error.index)
    assert_equal(0, error.previous_index)
    assert_equal(:interval_or_order, error.reason)
  end

  def test_forward_spring_gap_remains_invalid
    local_times = [Time.utc(2004, 3, 28, 0, 30), Time.utc(2004, 3, 28, 1, 30)]

    error = assert_raises(InvalidLocalTimeSequence) do
      @tz.disambiguate_local_sequence(local_times, 0, 7200, :order => :strict)
    end

    assert_equal(1, error.index)
    assert_nil(error.previous_index)
    assert_equal(:invalid_local_time, error.reason)
  end

  def test_conflict_reports_first_impossible_adjacent_position
    local_times = [Time.utc(2004, 10, 31, 1, 30), Time.utc(2004, 10, 31, 3, 30)]

    error = assert_raises(InvalidLocalTimeSequence) do
      @tz.disambiguate_local_sequence(local_times, 3600, 3600, :order => :strict)
    end

    assert_equal(1, error.index)
    assert_equal(0, error.previous_index)
    assert_equal(:interval_or_order, error.reason)
  end

  def test_earliest_adjacent_conflict_is_reported_before_later_invalid_time
    local_times = [
      Time.utc(2004, 10, 31, 1, 30),
      Time.utc(2004, 10, 31, 1, 30),
      Time.utc(2004, 3, 28, 1, 30)
    ]

    error = assert_raises(InvalidLocalTimeSequence) do
      @tz.disambiguate_local_sequence(local_times, 0, 0, :order => :strict)
    end

    assert_equal(1, error.index)
    assert_equal(0, error.previous_index)
    assert_equal(:interval_or_order, error.reason)
  end

  def test_result_matches_exhaustive_candidate_combinations
    local_wall_seconds = (0...180).step(15).to_a
    local_times = local_wall_seconds.collect do |second|
      hour = second < 3600 ? 1 : 2
      minute = (second % 3600) / 60
      Time.utc(2004, 10, 31, hour, minute, second % 60)
    end

    candidates = local_times.collect {|local_time| candidate_utc_times(local_time) }
    exhaustive = exhaustive_sequences(candidates, 0, 7200, true)

    resolution = @tz.disambiguate_local_sequence(local_times, 0, 7200, :order => :strict)

    candidates.each_index do |index|
      expected = exhaustive.collect {|sequence| sequence[index] }.uniq.sort
      assert_equal(expected, resolution[index].utc_times.sort, "index #{index}")
    end
  end

  def test_large_sequence_does_not_require_expanding_all_combinations
    local_times = Enumerator.new do |yielder|
      20_000.times do |index|
        yielder.yield(Time.utc(2004, 10, 31, 1, 30))
      end
    end

    resolution = @tz.disambiguate_local_sequence(local_times, 0, 0, :order => :non_decreasing)

    assert_equal(20_000, resolution.length)
    assert_equal((0...20_000).to_a, resolution.ambiguous_indexes)
    assert_equal([
      Time.utc(2004, 10, 31, 0, 30),
      Time.utc(2004, 10, 31, 1, 30)
    ], resolution[0].utc_times)
    assert_equal([
      Time.utc(2004, 10, 31, 0, 30),
      Time.utc(2004, 10, 31, 1, 30)
    ], resolution[-1].utc_times)
  end

  def test_returns_supported_input_types_and_ignores_their_offsets
    time_types_test(:offset) do |h|
      local_times = [
        h.time(2004, 10, 31, 1, 30, 0, 0, 18_000),
        h.time(2004, 10, 31, 1, 31, 0, 0, 18_000),
        h.time(2004, 10, 31, 2, 30, 0, 0, 18_000)
      ]

      resolution = @tz.disambiguate_local_sequence(local_times, 0, 7200, :order => :strict)

      assert_equal([h.output_time(2004, 10, 31, 0, 30, 0, 0, :utc), h.output_time(2004, 10, 31, 1, 30, 0, 0, :utc)], resolution[0].utc_times)
      assert_equal(h.output_time(2004, 10, 31, 2, 30, 0, 0, :utc), resolution[2].utc_time)
    end
  end

  def test_class_method_accepts_identifier
    local_times = [Time.utc(2004, 10, 31, 2, 30)]

    resolution = Timezone.disambiguate_local_sequence('Europe/London', local_times, 0, 7200, :order => :strict)

    assert_equal(Time.utc(2004, 10, 31, 2, 30), resolution[0].utc_time)
  end

  def test_proxy_supports_resolution
    proxy = Timezone.get_proxy('Europe/London')
    local_times = [Time.utc(2004, 10, 31, 2, 30)]

    resolution = proxy.disambiguate_local_sequence(local_times, 0, 7200, :order => :strict)

    assert_equal(Time.utc(2004, 10, 31, 2, 30), resolution[0].utc_time)
  end

  def test_order_must_be_explicit
    local_times = [Time.utc(2004, 10, 31, 2, 30)]

    error = assert_raises(ArgumentError) do
      @tz.disambiguate_local_sequence(local_times, 0, 7200)
    end

    assert_equal('order must be :non_decreasing or :strict', error.message)
  end

  def test_interval_bounds_are_validated
    local_times = [Time.utc(2004, 10, 31, 2, 30)]

    assert_raises(ArgumentError) { @tz.disambiguate_local_sequence(local_times, -1, 7200, :order => :strict) }
    assert_raises(ArgumentError) { @tz.disambiguate_local_sequence(local_times, 7201, 7200, :order => :strict) }
    assert_raises(ArgumentError) { @tz.disambiguate_local_sequence(local_times, '0', 7200, :order => :strict) }
  end

  def test_sub_second_times_before_epoch_preserve_fractional_time
    utc_zone = Timezone.get('Etc/UTC')
    local_times = [Time.at(-Rational(1, 2)).utc]

    resolution = utc_zone.disambiguate_local_sequence(local_times, 0, 0, :order => :non_decreasing)

    assert_equal(Time.at(-Rational(1, 2)).utc, resolution[0].utc_time)
  end

  private

  def candidate_utc_times(local_time)
    local_timestamp = Timestamp.for(local_time, :ignore)
    @tz.periods_for_local(local_timestamp).collect do |period|
      local_timestamp.add_and_set_utc_offset(-period.observed_utc_offset, :utc).to_time
    end
  end

  def exhaustive_sequences(candidates, min_interval, max_interval, strict)
    candidates.reduce([[]]) do |sequences, record_candidates|
      sequences.product(record_candidates).collect do |sequence, candidate|
        sequence + [candidate]
      end.select do |sequence|
        sequence.length == 1 || valid_exhaustive_interval?(sequence[-2], sequence[-1], min_interval, max_interval, strict)
      end
    end
  end

  def valid_exhaustive_interval?(previous, current, min_interval, max_interval, strict)
    interval = current.to_r - previous.to_r
    interval >= 0 && (!strict || interval > 0) && interval >= min_interval && interval <= max_interval
  end
end
