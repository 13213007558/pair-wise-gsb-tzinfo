# encoding: UTF-8
# frozen_string_literal: true

require_relative 'test_utils'

class TCTimezoneInterval < Minitest::Test
  include TZInfo

  def setup
    std = TimezoneOffset.new(0, 0, 'STD')
    dst = TimezoneOffset.new(0, 3600, 'DST')
    spring = TimezoneTransition.new(dst, std, Time.utc(2000, 4, 1, 2).to_i)
    fall = TimezoneTransition.new(std, dst, Time.utc(2000, 10, 1, 1).to_i)
    info = DataSources::TransitionsDataTimezoneInfo.new('Test/Annual', [spring, fall])
    @timezone = DataTimezone.new(info)

    half_std = TimezoneOffset.new(36_000, 0, '+10:00')
    half_dst = TimezoneOffset.new(36_000, 1800, '+10:30')
    half_spring = TimezoneTransition.new(half_dst, half_std, Time.utc(2000, 3, 31, 16).to_i)
    half_fall = TimezoneTransition.new(half_std, half_dst, Time.utc(2000, 10, 1, 14).to_i)
    half_info = DataSources::TransitionsDataTimezoneInfo.new('Test/HalfHour', [half_spring, half_fall])
    @half_hour_timezone = DataTimezone.new(half_info)

    old_offset = TimezoneOffset.new(-39_600, 0, '-11:00')
    new_offset = TimezoneOffset.new(50_400, 0, '+14:00')
    day_jump = TimezoneTransition.new(new_offset, old_offset, Time.utc(2011, 12, 30, 10).to_i)
    day_info = DataSources::TransitionsDataTimezoneInfo.new('Test/DayJump', [day_jump])
    @day_jump_timezone = DataTimezone.new(day_info)
  end

  def test_converts_interval_across_spring_and_fall_transitions
    result = @timezone.local_to_utc_interval(
      Timestamp.create(2000, 4, 1, 1, 15, 0, Rational(1, 3)),
      Timestamp.create(2000, 10, 1, 2, 45, 0, Rational(2, 3)))

    assert_intervals(
      [
        [utc(2000, 4, 1, 1, 15, 0, Rational(1, 3)), utc(2000, 4, 1, 2, 0), 'STD'],
        [utc(2000, 4, 1, 2, 0), utc(2000, 10, 1, 1, 0), 'DST'],
        [utc(2000, 10, 1, 1, 0), utc(2000, 10, 1, 2, 45, 0, Rational(2, 3)), 'STD']
      ],
      result.utc_intervals)

    assert_local_intervals(
      [[local(2000, 4, 1, 2, 0), local(2000, 4, 1, 3, 0)]],
      [[local(2000, 10, 1, 1, 0), local(2000, 10, 1, 2, 0)]],
      result)
  end

  def test_spring_boundary_half_open_ownership
    result = @timezone.local_to_utc_interval(
      Timestamp.create(2000, 4, 1, 1, 45),
      Timestamp.create(2000, 4, 1, 3, 15))

    assert_intervals(
      [
        [utc(2000, 4, 1, 1, 45), utc(2000, 4, 1, 2, 0), 'STD'],
        [utc(2000, 4, 1, 2, 0), utc(2000, 4, 1, 2, 15), 'DST']
      ],
      result.utc_intervals)

    assert_equal(false, result.utc_intervals[0].include_utc?(utc(2000, 4, 1, 2, 0)))
    assert_equal(true, result.utc_intervals[1].include_utc?(utc(2000, 4, 1, 2, 0)))
  end

  def test_fall_returns_all_repeated_occurrences
    result = @timezone.local_to_utc_interval(
      Timestamp.create(2000, 10, 1, 0, 45),
      Timestamp.create(2000, 10, 1, 2, 45),
      :all)

    assert_intervals(
      [
        [utc(2000, 9, 30, 23, 45), utc(2000, 10, 1, 1, 0), 'DST'],
        [utc(2000, 10, 1, 1, 0), utc(2000, 10, 1, 2, 45), 'STD']
      ],
      result.utc_intervals)

    assert_projection(result, utc(2000, 10, 1, 0, 30), local(2000, 10, 1, 1, 30, utc_offset: 3600), 'DST', @timezone)
    assert_projection(result, utc(2000, 10, 1, 1, 30), local(2000, 10, 1, 1, 30), 'STD')
  end

  def test_fall_selects_earlier_or_later_repeated_occurrence
    start = Timestamp.create(2000, 10, 1, 0, 45)
    finish = Timestamp.create(2000, 10, 1, 2, 45)

    first = @timezone.local_to_utc_interval(start, finish, :first)
    assert_intervals(
      [
        [utc(2000, 9, 30, 23, 45), utc(2000, 10, 1, 1, 0), 'DST'],
        [utc(2000, 10, 1, 2, 0), utc(2000, 10, 1, 2, 45), 'STD']
      ],
      first.utc_intervals)

    last = @timezone.local_to_utc_interval(start, finish, :last)
    assert_intervals(
      [
        [utc(2000, 9, 30, 23, 45), utc(2000, 10, 1, 0, 0), 'DST'],
        [utc(2000, 10, 1, 1, 0), utc(2000, 10, 1, 2, 45), 'STD']
      ],
      last.utc_intervals)
  end

  def test_half_hour_transition
    result = @half_hour_timezone.local_to_utc_interval(
      Timestamp.create(2000, 4, 1, 1, 45, 0, Rational(1, 7)),
      Timestamp.create(2000, 4, 1, 2, 45))

    assert_intervals(
      [
        [utc(2000, 3, 31, 15, 45, 0, Rational(1, 7)), utc(2000, 3, 31, 16, 0), '+10:00'],
        [utc(2000, 3, 31, 16, 0), utc(2000, 3, 31, 16, 15), '+10:30']
      ],
      result.utc_intervals)

    assert_local_intervals(
      [[local(2000, 4, 1, 2, 0), local(2000, 4, 1, 2, 30)]],
      [],
      result)
  end

  def test_day_jump_across_date_line
    result = @day_jump_timezone.local_to_utc_interval(
      Timestamp.create(2011, 12, 28, 23, 45),
      Timestamp.create(2011, 12, 31, 0, 15))

    assert_intervals(
      [
        [utc(2011, 12, 29, 10, 45), utc(2011, 12, 30, 10, 0), '-11:00'],
        [utc(2011, 12, 30, 10, 0), utc(2011, 12, 30, 10, 15), '+14:00']
      ],
      result.utc_intervals)

    assert_local_intervals(
      [[local(2011, 12, 29, 23, 0), local(2011, 12, 31, 0, 0)]],
      [],
      result)
  end

  def test_interval_entirely_within_day_jump_is_empty
    result = @day_jump_timezone.local_to_utc_interval(
      Timestamp.create(2011, 12, 30, 1, 15),
      Timestamp.create(2011, 12, 30, 2, 45))

    assert_equal([], result.utc_intervals)
    assert_local_intervals(
      [[local(2011, 12, 30, 1, 15), local(2011, 12, 30, 2, 45)]],
      [],
      result)
  end

  def test_retains_rational_sub_seconds_and_preserves_input_offset_semantics
    sub_second = Rational(1, 3)
    start_time = Time.new(2000, 4, 1, 1, 15, sub_second, 19_800)
    end_time = Time.new(2000, 4, 1, 4, 15, sub_second, 19_800)
    result = @timezone.local_to_utc_interval(start_time, end_time)

    assert_equal(sub_second, result.utc_intervals.first.utc_start.sub_second)
    assert_equal(sub_second, result.utc_intervals.last.utc_end.sub_second)
    assert_projection(result, utc(2000, 4, 1, 1, 15, 0, sub_second), local(2000, 4, 1, 1, 15, 0, sub_second), 'STD', @timezone)
    assert_projection(result, utc(2000, 4, 1, 2, 15, 0, sub_second), local(2000, 4, 1, 2, 15, 0, sub_second), 'DST', @timezone)
  end

  def test_invalid_arguments
    start = Timestamp.create(2000, 4, 1, 1)
    finish = Timestamp.create(2000, 4, 1, 2)

    assert_raises(ArgumentError) { @timezone.local_to_utc_interval(nil, finish) }
    assert_raises(ArgumentError) { @timezone.local_to_utc_interval(start, nil) }
    assert_raises(ArgumentError) { @timezone.local_to_utc_interval(start, start) }
    assert_raises(ArgumentError) { @timezone.local_to_utc_interval(finish, start) }
    assert_raises(ArgumentError) { @timezone.local_to_utc_interval(start, finish, :middle) }
  end

  private

  def utc(year, month, day, hour, minute = 0, second = 0, sub_second = 0)
    Timestamp.create(year, month, day, hour, minute, second, sub_second, :utc)
  end

  def local(year, month, day, hour, minute = 0, second = 0, sub_second = 0, utc_offset: nil)
    Timestamp.create(year, month, day, hour, minute, second, sub_second, utc_offset)
  end

  def assert_intervals(expected, actual)
    assert_equal(expected.length, actual.length)

    expected.each_with_index do |(start, finish, abbreviation), index|
      interval = actual[index]
      assert_equal_with_offset(start, interval.utc_start)
      assert_equal_with_offset(finish, interval.utc_end)
      assert_equal(true, interval.utc_start < interval.utc_end)
      assert_equal(abbreviation, interval.period.abbreviation)
    end
  end

  def assert_local_intervals(expected_missing, expected_repeated, result)
    assert_equal(expected_missing.length, result.missing_local_intervals.length)
    assert_equal(expected_repeated.length, result.repeated_local_intervals.length)

    expected_missing.each_with_index do |(start, finish), index|
      interval = result.missing_local_intervals[index]
      assert_equal(start, interval.local_start)
      assert_equal(finish, interval.local_end)
      assert_equal(true, interval.missing?)
      assert_nil(interval.utc_start)
    end

    expected_repeated.each_with_index do |(start, finish), index|
      interval = result.repeated_local_intervals[index]
      assert_equal(start, interval.local_start)
      assert_equal(finish, interval.local_end)
      assert_equal(true, interval.repeated?)
      assert_nil(interval.utc_start)
    end
  end

  def assert_projection(result, utc_sample, expected_local, abbreviation, timezone = @timezone)
    interval = result.utc_intervals.find {|candidate| candidate.include_utc?(utc_sample) }
    refute_nil(interval)
    assert_equal(abbreviation, interval.period.abbreviation)

    projected = timezone.utc_to_local(utc_sample)
    assert_equal(expected_local.value, projected.value)
    assert_equal(expected_local.sub_second, projected.sub_second)
    assert_equal(abbreviation, projected.timezone_offset.abbreviation)
  end
end
