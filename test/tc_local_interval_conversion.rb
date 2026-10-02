# encoding: UTF-8
# frozen_string_literal: true

require_relative 'test_utils'

class TCLocalIntervalConversion < Minitest::Test
  include TZInfo

  def test_attributes
    utc_intervals = [Timestamp.utc(1000)...Timestamp.utc(2000)]
    gaps = [Timestamp.new(3000)...Timestamp.new(4000)]
    repeated = [Timestamp.new(5000)...Timestamp.new(6000)]

    conversion = LocalIntervalConversion.new(utc_intervals, gaps, repeated)

    assert_equal(utc_intervals, conversion.utc_intervals)
    assert_equal(gaps, conversion.gaps)
    assert_equal(repeated, conversion.repeated)
    assert(conversion.frozen?)
    assert(conversion.utc_intervals.frozen?)
    assert(conversion.gaps.frozen?)
    assert(conversion.repeated.frozen?)
  end

  def test_nil_parameters
    interval = Timestamp.utc(1000)...Timestamp.utc(2000)

    assert_raises(ArgumentError) { LocalIntervalConversion.new(nil, [], []) }
    assert_raises(ArgumentError) { LocalIntervalConversion.new([interval], nil, []) }
    assert_raises(ArgumentError) { LocalIntervalConversion.new([interval], [], nil) }
  end

  def test_equality
    utc_intervals = [Timestamp.utc(1000)...Timestamp.utc(2000)]
    gaps = [Timestamp.new(3000)...Timestamp.new(4000)]
    repeated = [Timestamp.new(5000)...Timestamp.new(6000)]

    c1 = LocalIntervalConversion.new(utc_intervals, gaps, repeated)
    c2 = LocalIntervalConversion.new(utc_intervals.dup, gaps.dup, repeated.dup)
    c3 = LocalIntervalConversion.new([], gaps, repeated)
    c4 = LocalIntervalConversion.new(utc_intervals, [], repeated)
    c5 = LocalIntervalConversion.new(utc_intervals, gaps, [])

    assert_equal(c1, c2)
    assert(c1.eql?(c2))
    assert_equal(c1.hash, c2.hash)

    [c3, c4, c5].each do |other|
      refute_equal(c1, other)
      refute(c1.eql?(other))
    end

    refute_equal(c1, nil)
    refute_equal(c1, 'string')
  end
end
