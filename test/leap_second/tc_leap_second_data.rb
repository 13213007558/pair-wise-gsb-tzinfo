# encoding: UTF-8
# frozen_string_literal: true

require_relative '../test_utils'
require 'tempfile'

module LeapSecond
  class TCLeapSecondData < Minitest::Test
    include TZInfo
    include TZInfo::DataSources

    POSITIVE_P59 = Time.gm(2000, 1, 31, 23, 59, 59).to_i
    POSITIVE_LEAP = POSITIVE_P59 + 1
    POSITIVE_EXPIRY = POSITIVE_P59 + 3

    NEGATIVE_P58 = Time.gm(2000, 1, 31, 23, 59, 58).to_i
    NEGATIVE_REMOVED = NEGATIVE_P58 + 1
    NEGATIVE_P00 = NEGATIVE_REMOVED + 1
    NEGATIVE_EXPIRY = NEGATIVE_P00 + 1

    def write_tzif4(path, leaps)
      File.open(path, 'wb') do |file|
        first_header = ['TZif4', 0, 0, 0, 0, 1, 4].pack('a5 x15 NNNNNN')
        file.write(first_header)
        file.write([0, 0, 0].pack('NCC'))
        file.write("UTC\0")

        second_header = ['TZif4', 0, 0, leaps.length, 0, 1, 4].pack('a5 x15 NNNNNN')
        file.write(second_header)
        file.write([0, 0, 0].pack('NCC'))
        file.write('UTC' + "\0")

        leaps.each do |at, correction|
          unsigned = at < 0 ? at + 0x10000000000000000 : at
          file.write([unsigned >> 32, unsigned & 0xFFFFFFFF, correction].pack('NNN'))
        end

        file.write("\nUTC0\n")
      end
    end

    def with_tzif4(leaps)
      Tempfile.open('tzinfo-leap-v4') do |file|
        file.close
        write_tzif4(file.path, leaps)
        yield file.path
      end
    end

    def reader
      ZoneinfoReader.new(PosixTimeZoneParser.new(StringDeduper.new), StringDeduper.new)
    end

    def test_leap_aware_data_source_is_opted_in_separately
      directory = File.join(TESTS_DIR, 'zoneinfo')
      data_source = LeapAwareZoneinfoDataSource.new(directory)

      table = data_source.get_leap_second_table(File.join('right', 'Europe', 'London'))
      timestamp = data_source.leap_timestamp(File.join('right', 'Europe', 'London'), 2016, 12, 31, 23, 59, 60)

      assert_equal(27, table.leap_seconds.length)
      assert_equal(:leap_second, timestamp.kind)
      assert_equal('2016-12-31 23:59:60 UTC', timestamp.to_s)
      assert_equal(1483228827, table.valid_until)
      assert_raises(LeapSecondOutOfRangeError) { data_source.leap_timestamp(File.join('right', 'Europe', 'London'), 2017, 1, 1, 0, 0, 28) }
      assert_same(table, data_source.get_leap_second_table(File.join('right', 'Europe', 'London')))
    end

    def test_standard_time_remains_posix_and_cannot_represent_60
      time = Time.utc(2016, 12, 31, 23, 59, 60)

      assert_equal(0, time.sec)
      assert_equal(Time.utc(2017, 1, 1), time)
      assert_equal(1483228800, time.to_i)
    end

    def test_positive_leap_second_round_trip
      with_tzif4([[POSITIVE_LEAP, 1], [POSITIVE_EXPIRY, 1]]) do |path|
        table = reader.read_leap_seconds(path)

        leap = table.leap_seconds.first
        assert(leap.positive?)
        assert_equal(1, leap.delta)
        assert_equal(POSITIVE_LEAP, table.expiration.at - 2)

        before = LeapTimestamp.from_posix(table, POSITIVE_P59 - 1)
        inserted = LeapTimestamp.utc(table, 2000, 1, 31, 23, 59, 60)
        after = LeapTimestamp.utc(table, 2000, 2, 1, 0, 0, 0)

        assert_equal(:utc_second, before.kind)
        assert_equal(:leap_second, inserted.kind)
        assert_equal(:utc_second, after.kind)

        assert_equal(POSITIVE_LEAP, inserted.continuous_second)
        assert_equal(POSITIVE_P59, inserted.posix_second)
        assert_equal(60, inserted.second)
        assert_equal('2000-01-31 23:59:60 UTC', inserted.to_s)
        assert_equal(POSITIVE_P59 - 1, LeapTimestamp.from_posix(table, POSITIVE_P59 - 1).continuous_second)
        regular = LeapTimestamp.new(table, table.posix_to_continuous(POSITIVE_P59, 59))
        assert_equal(POSITIVE_P59, regular.continuous_second)
        assert_equal(:utc_second, regular.kind)
        assert_raises(LeapSecondOutOfRangeError) { LeapTimestamp.from_posix(table, POSITIVE_P59) }
        assert_equal(POSITIVE_P59 + 2, after.continuous_second)

        error = assert_raises(LeapSecondOutOfRangeError) { inserted.to_time }
        assert_match(/collapsing/, error.message)
      end
    end

    def test_negative_leap_second_does_not_invent_removed_second
      with_tzif4([[NEGATIVE_REMOVED, -1], [NEGATIVE_EXPIRY, -1]]) do |path|
        table = reader.read_leap_seconds(path)
        leap = table.leap_seconds.first

        assert(leap.negative?)
        assert_equal(-1, leap.delta)

        before = LeapTimestamp.utc(table, 2000, 1, 31, 23, 59, 58)
        midnight = LeapTimestamp.utc(table, 2000, 2, 1, 0, 0, 0)
        after = LeapTimestamp.utc(table, 2000, 2, 1, 0, 0, 1)

        assert_equal(NEGATIVE_P58, before.continuous_second)
        assert_equal(NEGATIVE_REMOVED, midnight.continuous_second)
        assert_equal(NEGATIVE_P00, after.continuous_second)
        assert_equal(58, before.second)
        assert_equal(0, midnight.second)
        assert_equal(1, after.second)
        assert_equal(NEGATIVE_P00, midnight.posix_second)

        error = assert_raises(LeapSecondOutOfRangeError) do
          LeapTimestamp.utc(table, 2000, 1, 31, 23, 59, 59)
        end
        assert_match(/removed by a negative leap second/, error.message)
        assert_raises(LeapSecondOutOfRangeError) { LeapTimestamp.from_posix(table, NEGATIVE_REMOVED) }
      end
    end

    def test_table_expiration_is_a_hard_boundary
      with_tzif4([[POSITIVE_LEAP, 1], [POSITIVE_EXPIRY, 1]]) do |path|
        table = reader.read_leap_seconds(path)

        assert_equal(0, table.valid_from)
        assert_equal(POSITIVE_EXPIRY, table.valid_until)
        assert_equal(POSITIVE_P59 + 1, table.last_posix_second)
        assert(table.valid_continuous_second?(POSITIVE_EXPIRY - 1))
        refute(table.valid_continuous_second?(POSITIVE_EXPIRY))
        assert_raises(LeapSecondOutOfRangeError) { LeapTimestamp.new(table, POSITIVE_EXPIRY) }
        assert_raises(LeapSecondOutOfRangeError) { LeapTimestamp.from_posix(table, POSITIVE_P59 + 2) }
      end
    end

    def test_truncated_table_start_and_expiration
      leaps = [[1005, 5], [1105, 6], [1108, 6]]

      with_tzif4(leaps) do |path|
        table = reader.read_leap_seconds(path)

        assert_equal(1005, table.valid_from)
        assert_equal(1108, table.valid_until)
        assert_equal(1, table.leap_seconds.length)
        assert_equal(6, table.leap_seconds.first.correction)
        assert_equal(1000, LeapTimestamp.new(table, 1005).posix_second)
        fields = Timestamp.send(:civil_fields_for_value, 1100)
        timestamp = LeapTimestamp.utc(table, fields[:year], fields[:month], fields[:day], fields[:hour], fields[:minute], fields[:second])
        assert_equal(1100, timestamp.posix_second)
        assert_equal(1106, timestamp.continuous_second)
        assert_raises(LeapSecondOutOfRangeError) { LeapTimestamp.new(table, 1004) }
        assert_raises(LeapSecondOutOfRangeError) { LeapTimestamp.new(table, 1108) }
      end
    end

    def test_tables_without_expiration_do_not_predict_the_future
      with_tzif4([[POSITIVE_LEAP, 1]]) do |path|
        table = reader.read_leap_seconds(path)

        assert_equal(POSITIVE_LEAP + 1, table.valid_until)
        assert_raises(LeapSecondOutOfRangeError) { LeapTimestamp.new(table, POSITIVE_LEAP + 1) }
      end
    end

    def test_ordinary_reader_still_rejects_leap_seconds
      with_tzif4([[POSITIVE_LEAP, 1], [POSITIVE_EXPIRY, 1]]) do |path|
        error = assert_raises(InvalidZoneinfoFile) { reader.read(path) }
        assert_match(/contains leap second data/, error.message)
      end
    end

    def test_version4_boundaries_are_not_accepted_in_version2_files
      Tempfile.open('tzinfo-leap-v2') do |file|
        file.close
        leaps = [[POSITIVE_LEAP, 1], [POSITIVE_EXPIRY, 1]]
        write_tzif4(file.path, leaps)
        data = File.binread(file.path).gsub('TZif4', 'TZif2')
        File.binwrite(file.path, data)

        error = assert_raises(InvalidZoneinfoFile) { reader.read_leap_seconds(file.path) }
        assert_match(/expiration records are only supported in TZif version 4/, error.message)
      end
    end

    def test_invalid_correction_jump_is_rejected
      with_tzif4([[100, 1], [200, 3]]) do |path|
        error = assert_raises(InvalidZoneinfoFile) { reader.read_leap_seconds(path) }
        assert_match(/corrections must change by exactly 1/, error.message)
      end
    end
  end
end
