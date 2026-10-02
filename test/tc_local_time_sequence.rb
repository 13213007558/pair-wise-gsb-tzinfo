# encoding: UTF-8
# frozen_string_literal: true

require_relative 'test_utils'

class TCLocalTimeSequence < Minitest::Test
  include TZInfo

  AMBIGUOUS_UTC = [
    Timestamp.utc(1099200600), # 2004-10-31 05:30:00 UTC (EDT)
    Timestamp.utc(1099204200)  # 2004-10-31 06:30:00 UTC (EST)
  ].freeze

  def test_unique_and_ambiguous_records
    result = resolve([[0, 30], [1, 30], [2, 30]], 3600, 7200)

    refute_predicate(result, :impossible?)
    refute_predicate(result, :uniquely_determined?)
    assert_predicate(result, :ambiguous?)
    assert_equal([:unique, :ambiguous, :unique], result.statuses)
    assert_equal([Timestamp.utc(1099197000), nil, Timestamp.utc(1099207800)], result.utc_times)
    assert_equal([
      [Timestamp.utc(1099197000)],
      AMBIGUOUS_UTC,
      [Timestamp.utc(1099207800)]
    ], result.possible_utc_times)
  end

  def test_interval_constraint_can_determine_second_occurrence
    result = resolve([[1, 0], [1, 30], [2, 0]], 1800, 1800)

    assert_predicate(result, :uniquely_determined?)
    assert_equal([
      Timestamp.utc(1099202400),
      Timestamp.utc(1099204200),
      Timestamp.utc(1099206000)
    ], result.utc_times)
  end

  def test_impossible_interval_conflict
    result = resolve([[0, 30], [1, 30], [2, 30]], 3600, 3600)

    assert_predicate(result, :impossible?)
    refute_predicate(result, :ambiguous?)
    refute_predicate(result, :uniquely_determined?)
    assert_equal(2, result.conflict_index)
    assert_equal(:inconsistent_interval, result.conflict_reason)
    assert_equal([:unique, :unique, :conflict], result.statuses)
    assert_equal([
      [Timestamp.utc(1099197000)],
      [Timestamp.utc(1099200600)]
    ], result.possible_utc_times)
    assert_equal([], result.utc_times)
  end

  def test_skipped_local_time_remains_invalid
    result = timezone.disambiguate_local_times([
      Time.utc(2004, 4, 4, 1, 30),
      Time.utc(2004, 4, 4, 2, 30),
      Time.utc(2004, 4, 4, 3, 30)
    ], order: :non_decreasing)

    assert_predicate(result, :impossible?)
    assert_equal(1, result.conflict_index)
    assert_equal(:invalid_local_time, result.conflict_reason)
    assert_equal([:unique, :invalid_local_time, :conflict], result.statuses)
    assert_equal([[Timestamp.utc(1081060200)]], result.possible_utc_times)
  end

  def test_earlier_interval_conflict_is_reported_before_later_invalid_local_time
    result = timezone.disambiguate_local_times([
      Time.utc(2004, 10, 31, 0, 30),
      Time.utc(2004, 10, 31, 1, 30),
      Time.utc(2004, 4, 4, 2, 30)
    ], order: :non_decreasing, min_interval: 86_400)

    assert_predicate(result, :impossible?)
    assert_equal(1, result.conflict_index)
    assert_equal(:inconsistent_interval, result.conflict_reason)
    assert_equal([:unique, :conflict, :conflict], result.statuses)
  end

  def test_non_decreasing_allows_equal_utc_times
    result = resolve([[1, 30], [1, 30]], 0, nil, :non_decreasing)

    refute_predicate(result, :impossible?)
    assert_equal([:ambiguous, :ambiguous], result.statuses)
    assert_equal([AMBIGUOUS_UTC, AMBIGUOUS_UTC], result.possible_utc_times)
  end

  def test_strictly_increasing_forbids_equal_utc_times
    result = resolve([[1, 30], [1, 30]], 0, nil, :strictly_increasing)

    assert_predicate(result, :uniquely_determined?)
    assert_equal([
      Timestamp.utc(1099200600),
      Timestamp.utc(1099204200)
    ], result.utc_times)
  end

  def test_min_interval_requires_positive_for_equal_local_times
    result = resolve([[1, 30], [1, 30]], 3600, 3600, :non_decreasing)

    assert_predicate(result, :uniquely_determined?)
    assert_equal([
      Timestamp.utc(1099200600),
      Timestamp.utc(1099204200)
    ], result.utc_times)
  end

  def test_sub_second_intervals
    times = [
      Timestamp.create(2004, 10, 31, 1, 59, 59, Rational(1, 2)),
      Timestamp.create(2004, 10, 31, 1, 0, 0, Rational(1, 2))
    ]

    result = timezone.disambiguate_local_times(times, order: :non_decreasing, max_interval: 1)

    assert_predicate(result, :uniquely_determined?)
    assert_equal(1099202400, result.utc_times[1].value)
    assert_equal(Rational(1, 2), result.utc_times[1].sub_second)
  end

  def test_input_time_type_does_not_change_utc_timestamp_results
    time_types_test(:output) do |helper|
      result = timezone.disambiguate_local_times([
        helper_time(helper, 2004, 10, 31, 1, 30),
        helper_time(helper, 2004, 10, 31, 1, 30)
      ], order: :strictly_increasing)

      assert_equal(AMBIGUOUS_UTC, result.utc_times)
      result.utc_times.each {|time| assert_instance_of(Timestamp, time) }
    end
  end

  def test_module_entry_accepts_identifier
    result = TZInfo.disambiguate_local_times('America/New_York',
      [Time.utc(2004, 10, 31, 1, 30), Time.utc(2004, 10, 31, 1, 30)],
      order: :strictly_increasing)

    assert_equal(AMBIGUOUS_UTC, result.utc_times)
  end

  def test_small_sequence_matches_full_enumeration
    wall_times = [[0, 0], [1, 30], [3, 0], [4, 0]]
    local_times = wall_times.collect {|hour, minute| Time.utc(2004, 10, 31, hour, minute) }
    candidates = wall_times.collect {|hour, minute| candidates_for(hour, minute) }

    [[3600, 7200], [5400, 9000], [0, nil]].each do |min_interval, max_interval|
      paths = enumerate_paths(candidates, min_interval, max_interval, false)
      result = resolve(wall_times, min_interval, max_interval)

      if paths.empty?
        assert_predicate(result, :impossible?)
      else
        expected = paths.transpose.collect {|times| times.uniq.sort }
        assert_equal(expected, result.possible_utc_times)
      end
    end
  end

  def test_long_sequence_is_linear_and_does_not_enumerate_combinations
    length = 10_000
    local_times = [Time.utc(2004, 10, 31, 0, 30)] + Array.new(length - 1) { Time.utc(2004, 10, 31, 1, 30) }
    result = timezone.disambiguate_local_times(local_times, order: :non_decreasing, min_interval: 1, max_interval: 3600)

    assert_predicate(result, :impossible?)
    assert_equal(3, result.conflict_index)
    assert_equal(:unique, result.statuses[0])
    assert_equal(:unique, result.statuses[1])
    assert_equal(:unique, result.statuses[2])
    assert_equal(:conflict, result.statuses[3])
    assert_equal(length, result.statuses.length)
  end

  def test_invalid_options
    error = assert_raises(ArgumentError) { timezone.disambiguate_local_times([Time.utc(2004, 10, 31, 1, 30)]) }
    assert_match(/\border\b/, error.message)
    assert_raises(ArgumentError) { resolve([[1, 30]], 0, nil, :later) }
    assert_raises(ArgumentError) { resolve([[1, 30]], -1) }
    assert_raises(ArgumentError) { resolve([[1, 30]], 3600, 3599) }
    assert_raises(ArgumentError) { timezone.disambiguate_local_times([]) }
    assert_raises(ArgumentError) { timezone.disambiguate_local_times([nil]) }
  end

  private

  def timezone
    @timezone ||= Timezone.get('America/New_York')
  end

  def local_time(hour, minute)
    Time.utc(2004, 10, 31, hour, minute)
  end

  def helper_time(helper, year, month, day, hour, minute)
    helper.time(year, month, day, hour, minute, 0)
  end

  def resolve(wall_times, min_interval = 0, max_interval = nil, order = :non_decreasing)
    timezone.disambiguate_local_times(
      wall_times.collect {|hour, minute| local_time(hour, minute) },
      order: order,
      min_interval: min_interval,
      max_interval: max_interval
    )
  end

  def candidates_for(hour, minute)
    local_timestamp = Timestamp.create(2004, 10, 31, hour, minute)
    timezone.periods_for_local(local_timestamp).collect do |period|
      Timestamp.utc(local_timestamp.value - period.observed_utc_offset)
    end.uniq.sort
  end

  def enumerate_paths(candidates, min_interval, max_interval, strictly_increasing)
    candidates.reduce([[]]) do |paths, times|
      paths.flat_map do |path|
        times.select do |time|
          path.empty? || allowed_interval?(path.last, time, min_interval, max_interval, strictly_increasing)
        end.collect {|time| path + [time] }
      end
    end
  end

  def allowed_interval?(earlier, later, min_interval, max_interval, strictly_increasing)
    elapsed = later.value - earlier.value + later.sub_second - earlier.sub_second
    (!strictly_increasing || elapsed > 0) && elapsed >= min_interval &&
      (max_interval.nil? || elapsed <= max_interval)
  end
end
