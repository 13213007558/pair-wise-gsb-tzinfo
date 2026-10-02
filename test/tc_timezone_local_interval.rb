# encoding: UTF-8
# frozen_string_literal: true

require_relative 'test_utils'

class TCTimezoneLocalInterval < Minitest::Test
  include TZInfo

  # Creates a local Timestamp (without a UTC offset).
  def l(year, month, day, hour, minute, second = 0, sub_second = 0)
    Timestamp.create(year, month, day, hour, minute, second, sub_second)
  end

  # Creates a UTC Timestamp.
  def u(year, month, day, hour, minute, second = 0, sub_second = 0)
    Timestamp.create(year, month, day, hour, minute, second, sub_second, :utc)
  end

  # The Integer timestamp value of a UTC time.
  def v(year, month, day, hour, minute, second = 0)
    u(year, month, day, hour, minute, second).value
  end

  # Adds a Rational number of seconds to a Timestamp, preserving the UTC
  # offset and Rational precision.
  def shift(timestamp, seconds)
    total = timestamp.value + timestamp.sub_second + seconds
    value = total.floor
    Timestamp.new(value, total - value, timestamp.utc? ? :utc : timestamp.utc_offset)
  end

  # Creates a DataTimezone with a fixed initial offset that changes to a new
  # offset at each of the given [timestamp_value, offset] changes.
  def transitions_zone(initial_offset, changes)
    previous_offset = initial_offset

    transitions = changes.collect do |timestamp_value, offset|
      transition = TimezoneTransition.new(
        TimezoneOffset.new(offset, 0, "O#{offset}"),
        TimezoneOffset.new(previous_offset, 0, "O#{previous_offset}"),
        timestamp_value)
      previous_offset = offset
      transition
    end

    DataTimezone.new(DataSources::TransitionsDataTimezoneInfo.new('Test/Zone', transitions))
  end

  # Samples local times within a half-open local Range.
  def local_samples(range)
    total = (range.end.value - range.begin.value) + (range.end.sub_second - range.begin.sub_second)
    [0, Rational(1, 3), Rational(2, 3)].collect do |fraction|
      shift(range.begin, total * fraction)
    end
  end

  # Converts samples of each returned UTC interval back to local times and
  # checks that they all fall within the converted local interval and outside
  # of any reported gap. When check_outside is true, UTC times immediately
  # outside of each interval are also checked to fall outside of the local
  # interval (only valid when all occurrences of repeated local times are
  # included).
  def assert_utc_coverage(tz, conversion, from, to, check_outside)
    conversion.utc_intervals.each do |interval|
      total = (interval.end.value - interval.begin.value) + (interval.end.sub_second - interval.begin.sub_second)

      [0, Rational(1, 7), Rational(1, 2), Rational(6, 7)].each do |fraction|
        sample = shift(interval.begin, total * fraction)
        local = Timestamp.for(tz.utc_to_local(sample), :ignore)
        assert(local >= from && local < to, "UTC #{sample} maps to local #{local}, outside [#{from}, #{to})")

        conversion.gaps.each do |gap|
          assert(local < gap.begin || local >= gap.end, "UTC #{sample} maps to local #{local}, inside gap #{gap}")
        end
      end

      if check_outside
        [shift(interval.begin, Rational(-1, 1000)), interval.end].each do |sample|
          local = Timestamp.for(tz.utc_to_local(sample), :ignore)
          assert(local < from || local >= to, "UTC #{sample} maps to local #{local}, inside [#{from}, #{to})")
        end
      end
    end

    conversion.gaps.each do |gap|
      local_samples(gap).each do |sample|
        assert_equal([], tz.periods_for_local(sample), "local #{sample} should not exist")
      end
    end

    conversion.repeated.each do |repeated|
      local_samples(repeated).each do |sample|
        assert(tz.periods_for_local(sample).length > 1, "local #{sample} should occur more than once")
      end
    end
  end
  def test_constant_offset
    tz = Timezone.get('EST')
    result = tz.local_interval_to_utc(l(2017,1,15,10,0), l(2017,1,15,12,0))

    assert_equal([u(2017,1,15,15,0)...u(2017,1,15,17,0)], result.utc_intervals)
    assert_equal([], result.gaps)
    assert_equal([], result.repeated)
    assert_utc_coverage(tz, result, l(2017,1,15,10,0), l(2017,1,15,12,0), true)
  end

  def test_time_and_datetime_parameters
    tz = Timezone.get('Europe/London')
    expected = tz.local_interval_to_utc(l(2017,6,1,10,0), l(2017,6,1,12,0))

    assert_equal(expected, tz.local_interval_to_utc(Time.utc(2017,6,1,10,0), Time.utc(2017,6,1,12,0)))
    assert_equal(expected, tz.local_interval_to_utc(DateTime.new(2017,6,1,10,0), DateTime.new(2017,6,1,12,0)))
  end

  def test_gap_london
    # Europe/London 2004-03-28: clocks went forward at 01:00 UTC. Local times
    # 01:00:00 to 01:59:59 did not exist.
    tz = Timezone.get('Europe/London')
    result = tz.local_interval_to_utc(l(2004,3,28,0,30), l(2004,3,28,2,30))

    # The UTC coverage is continuous even though the local hour is missing.
    assert_equal([u(2004,3,28,0,30)...u(2004,3,28,1,30)], result.utc_intervals)
    assert_equal([l(2004,3,28,1,0)...l(2004,3,28,2,0)], result.gaps)
    assert_equal([], result.repeated)
    assert_utc_coverage(tz, result, l(2004,3,28,0,30), l(2004,3,28,2,30), true)
  end

  def test_repeated_london_all
    # Europe/London 2004-10-31: clocks went back at 01:00 UTC. Local times
    # 01:00:00 to 01:59:59 occurred twice.
    tz = Timezone.get('Europe/London')
    result = tz.local_interval_to_utc(l(2004,10,31,0,30), l(2004,10,31,2,30))

    assert_equal([u(2004,10,30,23,30)...u(2004,10,31,2,30)], result.utc_intervals)
    assert_equal([], result.gaps)
    assert_equal([l(2004,10,31,1,0)...l(2004,10,31,2,0)], result.repeated)
    assert_utc_coverage(tz, result, l(2004,10,31,0,30), l(2004,10,31,2,30), true)
  end

  def test_repeated_london_first
    tz = Timezone.get('Europe/London')
    result = tz.local_interval_to_utc(l(2004,10,31,0,30), l(2004,10,31,2,30), :first)

    assert_equal([
      u(2004,10,30,23,30)...u(2004,10,31,1,0),
      u(2004,10,31,2,0)...u(2004,10,31,2,30)
    ], result.utc_intervals)
    assert_equal([], result.gaps)
    assert_equal([l(2004,10,31,1,0)...l(2004,10,31,2,0)], result.repeated)
    assert_utc_coverage(tz, result, l(2004,10,31,0,30), l(2004,10,31,2,30), false)
  end

  def test_repeated_london_last
    tz = Timezone.get('Europe/London')
    result = tz.local_interval_to_utc(l(2004,10,31,0,30), l(2004,10,31,2,30), :last)

    assert_equal([
      u(2004,10,30,23,30)...u(2004,10,31,0,0),
      u(2004,10,31,1,0)...u(2004,10,31,2,30)
    ], result.utc_intervals)
    assert_equal([], result.gaps)
    assert_equal([l(2004,10,31,1,0)...l(2004,10,31,2,0)], result.repeated)
    assert_utc_coverage(tz, result, l(2004,10,31,0,30), l(2004,10,31,2,30), false)
  end

  def test_repeated_london_sub_interval
    # The repeated local range is limited to the converted interval.
    tz = Timezone.get('Europe/London')
    result = tz.local_interval_to_utc(l(2004,10,31,1,15), l(2004,10,31,2,45))

    assert_equal([
      u(2004,10,31,0,15)...u(2004,10,31,1,0),
      u(2004,10,31,1,15)...u(2004,10,31,2,45)
    ], result.utc_intervals)
    assert_equal([], result.gaps)
    assert_equal([l(2004,10,31,1,15)...l(2004,10,31,2,0)], result.repeated)
    assert_utc_coverage(tz, result, l(2004,10,31,1,15), l(2004,10,31,2,45), true)
  end
  def test_interval_exactly_within_gap
    tz = Timezone.get('Europe/London')
    result = tz.local_interval_to_utc(l(2004,3,28,1,0), l(2004,3,28,2,0))

    assert_equal([], result.utc_intervals)
    assert_equal([l(2004,3,28,1,0)...l(2004,3,28,2,0)], result.gaps)
    assert_equal([], result.repeated)
  end

  def test_interval_ending_at_transition_local_time
    # The end is exclusive. Local 01:00 is the exact local end of the GMT
    # period (and the start of the gap), so is not included.
    tz = Timezone.get('Europe/London')
    result = tz.local_interval_to_utc(l(2004,3,28,0,0), l(2004,3,28,1,0))

    assert_equal([u(2004,3,28,0,0)...u(2004,3,28,1,0)], result.utc_intervals)
    assert_equal([], result.gaps)
    assert_equal([], result.repeated)
  end

  def test_interval_starting_at_transition_local_time
    # The start is inclusive. Local 02:00 is the exact local start of the BST
    # period (the end of the gap), so belongs to the BST period.
    tz = Timezone.get('Europe/London')
    result = tz.local_interval_to_utc(l(2004,3,28,2,0), l(2004,3,28,3,0))

    assert_equal([u(2004,3,28,1,0)...u(2004,3,28,2,0)], result.utc_intervals)
    assert_equal([], result.gaps)
    assert_equal([], result.repeated)
  end

  def test_interval_exactly_repeated_hour
    # The UTC transition instant (01:00 UTC) belongs to the second (GMT)
    # occurrence of the repeated hour.
    tz = Timezone.get('Europe/London')

    result = tz.local_interval_to_utc(l(2004,10,31,1,0), l(2004,10,31,2,0), :first)
    assert_equal([u(2004,10,31,0,0)...u(2004,10,31,1,0)], result.utc_intervals)

    result = tz.local_interval_to_utc(l(2004,10,31,1,0), l(2004,10,31,2,0), :last)
    assert_equal([u(2004,10,31,1,0)...u(2004,10,31,2,0)], result.utc_intervals)

    result = tz.local_interval_to_utc(l(2004,10,31,1,0), l(2004,10,31,2,0))
    assert_equal([u(2004,10,31,0,0)...u(2004,10,31,2,0)], result.utc_intervals)
    assert_equal([l(2004,10,31,1,0)...l(2004,10,31,2,0)], result.repeated)
  end

  def test_half_hour_forward_adjustment
    # Clocks put forward 30 minutes from +10:30 to +11:00 at 2017-03-04
    # 15:30:00 UTC. Local times 02:00:00 to 02:29:59 on 2017-03-05 do not
    # exist.
    tz = transitions_zone(37800, [[v(2017,3,4,15,30), 39600]])
    result = tz.local_interval_to_utc(l(2017,3,5,1,30), l(2017,3,5,3,0))

    assert_equal([u(2017,3,4,15,0)...u(2017,3,4,16,0)], result.utc_intervals)
    assert_equal([l(2017,3,5,2,0)...l(2017,3,5,2,30)], result.gaps)
    assert_equal([], result.repeated)
    assert_utc_coverage(tz, result, l(2017,3,5,1,30), l(2017,3,5,3,0), true)
  end

  def test_half_hour_backward_adjustment
    # Clocks put back 30 minutes from +11:00 to +10:30 at 2017-10-01 15:30:00
    # UTC. Local times 02:00:00 to 02:29:59 on 2017-10-02 occur twice.
    tz = transitions_zone(39600, [[v(2017,10,1,15,30), 37800]])
    from = l(2017,10,2,1,30)
    to = l(2017,10,2,3,0)

    result = tz.local_interval_to_utc(from, to)
    assert_equal([u(2017,10,1,14,30)...u(2017,10,1,16,30)], result.utc_intervals)
    assert_equal([], result.gaps)
    assert_equal([l(2017,10,2,2,0)...l(2017,10,2,2,30)], result.repeated)
    assert_utc_coverage(tz, result, from, to, true)

    result = tz.local_interval_to_utc(from, to, :first)
    assert_equal([
      u(2017,10,1,14,30)...u(2017,10,1,15,30),
      u(2017,10,1,16,0)...u(2017,10,1,16,30)
    ], result.utc_intervals)
    assert_utc_coverage(tz, result, from, to, false)

    result = tz.local_interval_to_utc(from, to, :last)
    assert_equal([
      u(2017,10,1,14,30)...u(2017,10,1,15,0),
      u(2017,10,1,15,30)...u(2017,10,1,16,30)
    ], result.utc_intervals)
    assert_utc_coverage(tz, result, from, to, false)
  end
  def test_date_line_jump_forward
    # A whole day is skipped when moving from -11:00 to +13:00 at 2011-12-30
    # 00:00:00 UTC (as in Pacific/Apia at the end of 2011). Local times from
    # 2011-12-29 13:00:00 to 2011-12-30 12:59:59 do not exist.
    tz = transitions_zone(-39600, [[v(2011,12,30,0,0), 46800]])
    from = l(2011,12,29,12,0)
    to = l(2011,12,30,14,0)

    result = tz.local_interval_to_utc(from, to)
    assert_equal([u(2011,12,29,23,0)...u(2011,12,30,1,0)], result.utc_intervals)
    assert_equal([l(2011,12,29,13,0)...l(2011,12,30,13,0)], result.gaps)
    assert_equal([], result.repeated)
    assert_utc_coverage(tz, result, from, to, true)
  end

  def test_date_line_jump_backward
    # Moving from +13:00 to -11:00 at 2011-12-30 00:00:00 UTC repeats a whole
    # day. Local times from 2011-12-29 13:00:00 to 2011-12-30 12:59:59 occur
    # twice.
    tz = transitions_zone(46800, [[v(2011,12,30,0,0), -39600]])
    from = l(2011,12,29,12,0)
    to = l(2011,12,30,14,0)

    result = tz.local_interval_to_utc(from, to)
    assert_equal([u(2011,12,28,23,0)...u(2011,12,31,1,0)], result.utc_intervals)
    assert_equal([], result.gaps)
    assert_equal([l(2011,12,29,13,0)...l(2011,12,30,13,0)], result.repeated)
    assert_utc_coverage(tz, result, from, to, true)

    result = tz.local_interval_to_utc(from, to, :first)
    assert_equal([
      u(2011,12,28,23,0)...u(2011,12,30,0,0),
      u(2011,12,31,0,0)...u(2011,12,31,1,0)
    ], result.utc_intervals)
    assert_utc_coverage(tz, result, from, to, false)

    result = tz.local_interval_to_utc(from, to, :last)
    assert_equal([
      u(2011,12,28,23,0)...u(2011,12,29,0,0),
      u(2011,12,30,0,0)...u(2011,12,31,1,0)
    ], result.utc_intervals)
    assert_utc_coverage(tz, result, from, to, false)
  end

  def test_multiple_transitions_within_interval
    # Clocks put forward 1 hour at 2017-06-01 01:00:00 UTC (local 01:00 to
    # 01:59:59 does not exist) and back 1 hour at 2017-06-03 01:00:00 UTC
    # (local 01:00 to 01:59:59 occurs twice).
    tz = transitions_zone(0, [
      [v(2017,6,1,1,0), 3600],
      [v(2017,6,3,1,0), 0]
    ])
    from = l(2017,6,1,0,30)
    to = l(2017,6,3,2,30)

    result = tz.local_interval_to_utc(from, to)
    assert_equal([u(2017,6,1,0,30)...u(2017,6,3,2,30)], result.utc_intervals)
    assert_equal([l(2017,6,1,1,0)...l(2017,6,1,2,0)], result.gaps)
    assert_equal([l(2017,6,3,1,0)...l(2017,6,3,2,0)], result.repeated)
    assert_utc_coverage(tz, result, from, to, true)

    result = tz.local_interval_to_utc(from, to, :first)
    assert_equal([
      u(2017,6,1,0,30)...u(2017,6,3,1,0),
      u(2017,6,3,2,0)...u(2017,6,3,2,30)
    ], result.utc_intervals)
    assert_utc_coverage(tz, result, from, to, false)

    result = tz.local_interval_to_utc(from, to, :last)
    assert_equal([
      u(2017,6,1,0,30)...u(2017,6,3,0,0),
      u(2017,6,3,1,0)...u(2017,6,3,2,30)
    ], result.utc_intervals)
    assert_utc_coverage(tz, result, from, to, false)
  end

  def test_sub_second_precision
    tz = Timezone.get('Europe/London')
    from = l(2004,10,31,1,15,0,Rational(1,3))
    to = l(2004,10,31,2,45,0,Rational(2,3))

    result = tz.local_interval_to_utc(from, to)
    assert_equal([
      u(2004,10,31,0,15,0,Rational(1,3))...u(2004,10,31,1,0),
      u(2004,10,31,1,15,0,Rational(1,3))...u(2004,10,31,2,45,0,Rational(2,3))
    ], result.utc_intervals)
    assert_equal(Rational(1,3), result.utc_intervals[0].begin.sub_second)
    assert_equal(Rational(2,3), result.utc_intervals[1].end.sub_second)
    assert_utc_coverage(tz, result, from, to, true)

    result = tz.local_interval_to_utc(from, to, :last)
    assert_equal([u(2004,10,31,1,15,0,Rational(1,3))...u(2004,10,31,2,45,0,Rational(2,3))], result.utc_intervals)
  end

  def test_sub_second_precision_across_transition
    # An interval ending half a second after a transition local time includes
    # half a second of the new period.
    tz = Timezone.get('Europe/London')
    result = tz.local_interval_to_utc(l(2004,3,28,0,59,59,Rational(1,2)), l(2004,3,28,2,0,0,Rational(1,2)))

    assert_equal([
      u(2004,3,28,0,59,59,Rational(1,2))...u(2004,3,28,1,0,0,Rational(1,2))
    ], result.utc_intervals)
    assert_equal([l(2004,3,28,1,0)...l(2004,3,28,2,0)], result.gaps)
  end

  def test_timezone_proxy
    tz = Timezone.get_proxy('Europe/London')
    result = tz.local_interval_to_utc(l(2004,3,28,0,30), l(2004,3,28,2,30))

    assert_equal([u(2004,3,28,0,30)...u(2004,3,28,1,30)], result.utc_intervals)
    assert_equal([l(2004,3,28,1,0)...l(2004,3,28,2,0)], result.gaps)
  end

  def test_nil_from
    tz = Timezone.get('Europe/London')
    assert_raises(ArgumentError) { tz.local_interval_to_utc(nil, l(2017,1,1,1,0)) }
  end

  def test_nil_to
    tz = Timezone.get('Europe/London')
    assert_raises(ArgumentError) { tz.local_interval_to_utc(l(2017,1,1,0,0), nil) }
  end

  def test_to_equal_to_from
    tz = Timezone.get('Europe/London')
    assert_raises(ArgumentError) { tz.local_interval_to_utc(l(2017,1,1,0,0), l(2017,1,1,0,0)) }
  end

  def test_to_before_from
    tz = Timezone.get('Europe/London')
    assert_raises(ArgumentError) { tz.local_interval_to_utc(l(2017,1,1,1,0), l(2017,1,1,0,0)) }
  end

  def test_invalid_repeated
    tz = Timezone.get('Europe/London')
    assert_raises(ArgumentError) { tz.local_interval_to_utc(l(2017,1,1,0,0), l(2017,1,1,1,0), :invalid) }
  end
end
