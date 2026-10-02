# encoding: UTF-8
# frozen_string_literal: true

require_relative 'test_utils'

class TCLeapSecond < Minitest::Test
  include TZInfo::LeapSeconds

  def test_initialize_positive
    ls = LeapSecond.new(78796800, 1, 0)
    assert_equal(78796800, ls.posix_time)
    assert_equal(1, ls.correction)
    assert_equal(0, ls.previous_correction)
    assert_equal(1, ls.delta)
    assert_equal(true, ls.positive?)
    assert_equal(false, ls.negative?)
    assert_equal(78796800, ls.inserted_continuous)
    assert_nil(ls.deleted_posix_time)
  end

  def test_initialize_negative
    ls = LeapSecond.new(78796800, 0, 1)
    assert_equal(-1, ls.delta)
    assert_equal(false, ls.positive?)
    assert_equal(true, ls.negative?)
    assert_equal(78796799, ls.deleted_posix_time)
    assert_nil(ls.inserted_continuous)
  end

  def test_initialize_requires_integers
    assert_raises(ArgumentError) { LeapSecond.new(78796800.5, 1, 0) }
    assert_raises(ArgumentError) { LeapSecond.new(78796800, 1.5, 0) }
    assert_raises(ArgumentError) { LeapSecond.new(78796800, 1, 0.5) }
  end

  def test_comparison_and_equality
    ls = LeapSecond.new(78796800, 1, 0)
    assert_equal(ls, LeapSecond.new(78796800, 1, 0))
    refute_equal(ls, LeapSecond.new(78796801, 1, 0))
    refute_equal(ls, LeapSecond.new(78796800, 2, 1))
    assert_operator(ls, :<, LeapSecond.new(78796801, 2, 1))
    assert_equal(ls.hash, LeapSecond.new(78796800, 1, 0).hash)
  end
end

class TCLeapSecondTable < Minitest::Test
  include TZInfo::LeapSeconds

  # A table with a positive leap second at 1972-07-01 00:00:00 POSIX
  # (78796800), a negative leap second at 1973-01-01 00:00:00 POSIX
  # (94694400) and an expiration at 1973-07-01 00:00:00 POSIX (110332800).
  POSITIVE_LEAP = 78796800
  NEGATIVE_LEAP = 94694400
  EXPIRES_AT = 110332800

  def create_table(expires_at = EXPIRES_AT)
    LeapSecondTable.new([[POSITIVE_LEAP, 1], [NEGATIVE_LEAP, 0]], expires_at)
  end

  def test_initialize_and_leap_seconds
    table = create_table
    assert_equal(2, table.leap_seconds.length)
    assert_equal(EXPIRES_AT, table.expires_at)
    assert_equal(false, table.empty?)

    positive, negative = table.leap_seconds
    assert_equal(POSITIVE_LEAP, positive.posix_time)
    assert_equal(1, positive.correction)
    assert_equal(0, positive.previous_correction)
    assert_equal(NEGATIVE_LEAP, negative.posix_time)
    assert_equal(0, negative.correction)
    assert_equal(1, negative.previous_correction)
  end

  def test_initialize_without_expiration
    table = create_table(nil)
    assert_nil(table.expires_at)
  end

  def test_initialize_empty
    table = LeapSecondTable.new
    assert_equal(true, table.empty?)
    assert_equal([], table.leap_seconds)
    assert_equal(0, table.correction_at(0))
  end

  def test_initialize_from_leap_second_instances
    table = LeapSecondTable.new([LeapSecond.new(POSITIVE_LEAP, 1, 0)])
    assert_equal([LeapSecond.new(POSITIVE_LEAP, 1, 0)], table.leap_seconds)
  end

  def test_initialize_requires_ordered_entries
    error = assert_raises(ArgumentError) do
      LeapSecondTable.new([[NEGATIVE_LEAP, 1], [POSITIVE_LEAP, 2]])
    end
    assert_match(/\bordered\b/, error.message)
  end

  def test_initialize_requires_single_second_deltas
    error = assert_raises(ArgumentError) do
      LeapSecondTable.new([[POSITIVE_LEAP, 1], [NEGATIVE_LEAP, 3]])
    end
    assert_match(/differ/, error.message)
  end

  def test_initialize_requires_integer_expires_at
    assert_raises(ArgumentError) { LeapSecondTable.new([], 1.5) }
  end

  def test_correction_at
    table = create_table
    assert_equal(0, table.correction_at(0))
    assert_equal(0, table.correction_at(POSITIVE_LEAP - 1))
    assert_equal(1, table.correction_at(POSITIVE_LEAP))
    assert_equal(1, table.correction_at(NEGATIVE_LEAP - 2))
    assert_equal(0, table.correction_at(NEGATIVE_LEAP))
    assert_equal(0, table.correction_at(EXPIRES_AT - 1))
  end

  def test_correction_at_expired
    table = create_table
    assert_raises(LeapSecondTableExpired) { table.correction_at(EXPIRES_AT) }
    assert_raises(LeapSecondTableExpired) { table.correction_at(EXPIRES_AT + 1) }
  end

  def test_correction_at_without_expiration
    table = create_table(nil)
    assert_equal(0, table.correction_at(EXPIRES_AT + 1000000))
  end

  def test_leap_second_at
    table = create_table
    assert_equal(LeapSecond.new(POSITIVE_LEAP, 1, 0), table.leap_second_at(POSITIVE_LEAP))
    assert_nil(table.leap_second_at(POSITIVE_LEAP - 1))
  end

  def test_to_continuous_positive_leap
    table = create_table
    # Seconds before the leap are unaffected.
    assert_equal(POSITIVE_LEAP - 1, table.to_continuous(POSITIVE_LEAP - 1))
    # The inserted second occupies the continuous position POSIX_LEAP + 0,
    # so the POSIX second at POSITIVE_LEAP maps one position later.
    assert_equal(POSITIVE_LEAP + 1, table.to_continuous(POSITIVE_LEAP))
    assert_equal(POSITIVE_LEAP + 2, table.to_continuous(POSITIVE_LEAP + 1))
  end

  def test_to_continuous_negative_leap
    table = create_table
    # The second before the deleted second maps normally.
    assert_equal(NEGATIVE_LEAP - 1, table.to_continuous(NEGATIVE_LEAP - 2))
    # The deleted second (NEGATIVE_LEAP - 1) has no continuous position.
    error = assert_raises(UtcSecondNotFound) do
      table.to_continuous(NEGATIVE_LEAP - 1)
    end
    assert_match(/negative leap second/, error.message)
    # The correction is removed again from NEGATIVE_LEAP onwards.
    assert_equal(NEGATIVE_LEAP, table.to_continuous(NEGATIVE_LEAP))
  end

  def test_to_continuous_expired
    table = create_table
    assert_raises(LeapSecondTableExpired) { table.to_continuous(EXPIRES_AT) }
  end

  def test_posix_for_continuous
    table = create_table
    assert_equal(POSITIVE_LEAP - 1, table.posix_for_continuous(POSITIVE_LEAP - 1))
    # The continuous position of the inserted leap second has no POSIX
    # representation.
    assert_nil(table.posix_for_continuous(POSITIVE_LEAP))
    assert_equal(POSITIVE_LEAP, table.posix_for_continuous(POSITIVE_LEAP + 1))
    assert_equal(NEGATIVE_LEAP - 2, table.posix_for_continuous(NEGATIVE_LEAP - 1))
    # The negative leap second removes a POSIX second; the continuous axis
    # remains contiguous.
    assert_equal(NEGATIVE_LEAP, table.posix_for_continuous(NEGATIVE_LEAP))
  end

  def test_posix_for_continuous_expired
    table = create_table
    assert_raises(LeapSecondTableExpired) { table.posix_for_continuous(EXPIRES_AT) }
  end

  def test_leap_second_for_continuous
    table = create_table
    assert_equal(LeapSecond.new(POSITIVE_LEAP, 1, 0), table.leap_second_for_continuous(POSITIVE_LEAP))
    assert_nil(table.leap_second_for_continuous(POSITIVE_LEAP - 1))
    assert_nil(table.leap_second_for_continuous(POSITIVE_LEAP + 1))
  end

  def test_equality
    assert_equal(create_table, create_table)
    refute_equal(create_table, create_table(nil))
    refute_equal(create_table, LeapSecondTable.new([[POSITIVE_LEAP, 1]], EXPIRES_AT))
    assert_equal(create_table.hash, create_table.hash)
  end
end
