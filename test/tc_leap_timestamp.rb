# encoding: UTF-8
# frozen_string_literal: true

require_relative 'test_utils'

class TCLeapTimestamp < Minitest::Test
  include TZInfo::LeapSeconds

  # A table with a positive leap second inserted at the end of
  # 1972-06-30 (the POSIX second 78796800 is 1972-07-01 00:00:00) and a
  # negative leap second removing the last second of 1972-12-31 (the
  # POSIX second 94694400 is 1973-01-01 00:00:00).
  POSITIVE_LEAP = 78796800
  NEGATIVE_LEAP = 94694400
  EXPIRES_AT = 110332800

  def setup
    @table = LeapSecondTable.new([[POSITIVE_LEAP, 1], [NEGATIVE_LEAP, 0]], EXPIRES_AT)
  end

  def test_for_posix_ordinary_second
    ts = LeapTimestamp.for_posix(@table, POSITIVE_LEAP - 1)
    assert_equal(POSITIVE_LEAP - 1, ts.continuous)
    assert_equal(POSITIVE_LEAP - 1, ts.posix)
    assert_equal(false, ts.leap_second?)
    assert_equal([1972, 6, 30, 23, 59, 59], ts.utc)
    assert_equal('1972-06-30T23:59:59Z', ts.to_s)
  end

  def test_for_posix_after_positive_leap
    ts = LeapTimestamp.for_posix(@table, POSITIVE_LEAP)
    assert_equal(POSITIVE_LEAP + 1, ts.continuous)
    assert_equal(POSITIVE_LEAP, ts.posix)
    assert_equal(false, ts.leap_second?)
    assert_equal([1972, 7, 1, 0, 0, 0], ts.utc)
  end

  def test_for_posix_deleted_second
    assert_raises(UtcSecondNotFound) do
      LeapTimestamp.for_posix(@table, NEGATIVE_LEAP - 1)
    end
  end

  def test_for_posix_expired
    assert_raises(LeapSecondTableExpired) do
      LeapTimestamp.for_posix(@table, EXPIRES_AT)
    end
  end

  def test_for_continuous_inserted_leap_second
    ts = LeapTimestamp.for_continuous(@table, POSITIVE_LEAP)
    assert_equal(POSITIVE_LEAP, ts.continuous)
    assert_equal(true, ts.leap_second?)
    # An inserted leap second has no POSIX representation and must not be
    # folded onto a neighboring second.
    assert_nil(ts.posix)
    assert_equal([1972, 6, 30, 23, 59, 60], ts.utc)
    assert_equal('1972-06-30T23:59:60Z', ts.to_s)
  end

  def test_for_continuous_expired
    assert_raises(LeapSecondTableExpired) do
      LeapTimestamp.for_continuous(@table, EXPIRES_AT)
    end
  end

  def test_for_utc_ordinary_second
    ts = LeapTimestamp.for_utc(@table, 1972, 7, 1, 0, 0, 0)
    assert_equal(POSITIVE_LEAP, ts.posix)
    assert_equal(POSITIVE_LEAP + 1, ts.continuous)
    assert_equal([1972, 7, 1, 0, 0, 0], ts.utc)
  end

  def test_for_utc_inserted_leap_second
    ts = LeapTimestamp.for_utc(@table, 1972, 6, 30, 23, 59, 60)
    assert_equal(true, ts.leap_second?)
    assert_equal(POSITIVE_LEAP, ts.continuous)
    assert_nil(ts.posix)
  end

  def test_for_utc_inserted_leap_second_round_trip
    # 23:59:60 must round-trip and not be folded onto 23:59:59 or
    # 00:00:00.
    ts = LeapTimestamp.for_utc(@table, 1972, 6, 30, 23, 59, 60)
    assert_equal([1972, 6, 30, 23, 59, 60], ts.utc)
    assert_equal(ts, LeapTimestamp.for_continuous(@table, ts.continuous))
  end

  def test_for_utc_second_60_without_leap_second
    assert_raises(UtcSecondNotFound) do
      LeapTimestamp.for_utc(@table, 1972, 6, 29, 23, 59, 60)
    end
  end

  def test_for_utc_second_60_not_at_end_of_day
    assert_raises(RangeError) do
      LeapTimestamp.for_utc(@table, 1972, 6, 30, 12, 0, 60)
    end
  end

  def test_for_utc_deleted_second
    # The negative leap second removes 1972-12-31 23:59:59.
    assert_raises(UtcSecondNotFound) do
      LeapTimestamp.for_utc(@table, 1972, 12, 31, 23, 59, 59)
    end

    # The surrounding seconds continue to exist.
    assert_equal([1972, 12, 31, 23, 59, 58], LeapTimestamp.for_utc(@table, 1972, 12, 31, 23, 59, 58).utc)
    assert_equal([1973, 1, 1, 0, 0, 0], LeapTimestamp.for_utc(@table, 1973, 1, 1, 0, 0, 0).utc)
  end

  def test_for_utc_expired
    assert_raises(LeapSecondTableExpired) do
      LeapTimestamp.for_utc(@table, 1973, 7, 1, 0, 0, 0)
    end
  end

  def test_for_utc_validation
    assert_raises(ArgumentError) { LeapTimestamp.for_utc(@table, 1972.5, 1, 1, 0, 0, 0) }
    assert_raises(RangeError) { LeapTimestamp.for_utc(@table, 1972, 13, 1, 0, 0, 0) }
    assert_raises(RangeError) { LeapTimestamp.for_utc(@table, 1972, 2, 30, 0, 0, 0) }
    assert_raises(RangeError) { LeapTimestamp.for_utc(@table, 1972, 1, 1, 24, 0, 0) }
    assert_raises(RangeError) { LeapTimestamp.for_utc(@table, 1972, 1, 1, 0, 60, 0) }
    assert_raises(RangeError) { LeapTimestamp.for_utc(@table, 1972, 1, 1, 0, 0, 61) }
  end

  def test_comparison
    ts1 = LeapTimestamp.for_posix(@table, POSITIVE_LEAP - 1)
    ts2 = LeapTimestamp.for_continuous(@table, POSITIVE_LEAP)
    ts3 = LeapTimestamp.for_posix(@table, POSITIVE_LEAP)

    assert_operator(ts1, :<, ts2)
    assert_operator(ts2, :<, ts3)
    assert_equal(ts1, LeapTimestamp.for_posix(@table, POSITIVE_LEAP - 1))
    refute_equal(ts1, ts2)
    assert_equal(ts1.hash, LeapTimestamp.for_posix(@table, POSITIVE_LEAP - 1).hash)

    other_table = LeapSecondTable.new([[POSITIVE_LEAP, 1]])
    assert_nil(ts1 <=> LeapTimestamp.for_posix(other_table, POSITIVE_LEAP - 1))
  end

  def test_utc_round_trip_for_all_representations
    [
      [1972, 6, 30, 23, 59, 59],
      [1972, 6, 30, 23, 59, 60],
      [1972, 7, 1, 0, 0, 0],
      [1972, 12, 31, 23, 59, 58],
      [1973, 1, 1, 0, 0, 0]
    ].each do |fields|
      ts = LeapTimestamp.for_utc(@table, *fields)
      assert_equal(fields, ts.utc)
      assert_equal(ts, LeapTimestamp.for_continuous(@table, ts.continuous))
    end
  end
end
