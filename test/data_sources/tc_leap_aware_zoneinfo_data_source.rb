# encoding: UTF-8
# frozen_string_literal: true

require_relative '../test_utils'
require 'tmpdir'
require 'fileutils'

module DataSources
  class TCLeapAwareZoneinfoDataSource < Minitest::Test
    include TZInfo
    include TZInfo::DataSources

    # A positive leap second inserted at the end of 1972-06-30 (the POSIX
    # second 78796800 is 1972-07-01 00:00:00) and a negative leap second
    # removing the last second of 1972-12-31 (the POSIX second 94694400 is
    # 1973-01-01 00:00:00). The table expires at 1973-07-01 00:00:00 POSIX.
    POSIX_LEAP = 78796800
    NEGATIVE_LEAP = 94694400
    EXPIRES_AT = 110332800

    LEAP_SECONDS = [[POSIX_LEAP, 1], [NEGATIVE_LEAP, 0]].freeze

    OFFSETS = [
      {gmtoff: -84, isdst: false, abbrev: 'LMT'},
      {gmtoff:   0, isdst: false, abbrev: 'UTC'}
    ].freeze

    TRANSITIONS = [{at: 0, offset_index: 1}].freeze

    # Writes a TZif file (versions 1 to 4).
    #
    # @param path [String] the path to write to.
    # @param version [Integer] the TZif version (1-4).
    # @param offsets [Array<Hash>] offset hashes with :gmtoff, :isdst and
    #   :abbrev keys.
    # @param transitions [Array<Hash>] transition hashes with :at and
    #   :offset_index keys.
    # @param leaps [Array<Array>] leap second records as stored in the
    #   file ([transition, correction] pairs).
    # @param tz_string [String] the POSIX-style TZ string footer.
    # @param expires_at [Integer] an optional leap second expiration time
    #   (version 4 only).
    def write_tzif(path, version, offsets, transitions, leaps, tz_string, expires_at = nil)
      abbrevs = offsets.collect {|o| o[:abbrev] }.uniq
      abbrev_data = abbrevs.collect {|a| "#{a}\0" }.join

      abbrev_offsets = {}
      offset = 0
      abbrevs.each do |a|
        abbrev_offsets[a] = offset
        offset += a.length + 1
      end

      pack32 = lambda {|v| [v < 0 ? v + 0x100000000 : v].pack('N') }
      pack64 = lambda do |v|
        v += 0x10000000000000000 if v < 0
        [v >> 32, v & 0xFFFFFFFF].pack('NN')
      end

      write_types = lambda do |file|
        offsets.each do |o|
          file.write([o[:gmtoff] < 0 ? o[:gmtoff] + 0x100000000 : o[:gmtoff], o[:isdst] ? 1 : 0, abbrev_offsets[o[:abbrev]]].pack('NCC'))
        end
      end

      magic = version == 1 ? "TZif\0" : "TZif#{version}"

      File.open(path, 'wb') do |file|
        # 32-bit section.
        file.write([magic, offsets.length, offsets.length, leaps.length,
          transitions.length, offsets.length, abbrev_data.length].pack('a5 x15 NNNNNN'))
        transitions.each {|t| file.write(pack32.call(t[:at])) }
        transitions.each {|t| file.write([t[:offset_index]].pack('C')) }
        write_types.call(file)
        file.write(abbrev_data)
        leaps.each {|t, c| file.write(pack32.call(t) + pack32.call(c)) }
        file.write("\0" * offsets.length * 2)

        if version >= 2
          # 64-bit section.
          file.write([magic, offsets.length, offsets.length, leaps.length,
            transitions.length, offsets.length, abbrev_data.length].pack('a5 x15 NNNNNN'))
          transitions.each {|t| file.write(pack64.call(t[:at])) }
          transitions.each {|t| file.write([t[:offset_index]].pack('C')) }
          write_types.call(file)
          file.write(abbrev_data)
          leaps.each {|t, c| file.write(pack64.call(t) + pack32.call(c)) }
          file.write("\0" * offsets.length * 2)
          file.write("\n#{tz_string}\n")

          if version == 4 && expires_at
            file.write(pack64.call(expires_at))
          end
        end
      end
    end

    # Creates a temporary zoneinfo directory containing a Test/Leap zone
    # with leap second data and yields the directory and zone file path.
    #
    # @param version [Integer] the TZif version to use.
    # @param expires_at [Integer] an optional leap second expiration time.
    # @param leaps [Array<Array>] the leap seconds as [posix_time,
    #   correction] pairs (converted to the on-disk representation for
    #   TZif versions prior to 4).
    def with_leap_zoneinfo_dir(version: 4, expires_at: EXPIRES_AT, leaps: LEAP_SECONDS)
      Dir.mktmpdir('tzinfo-test') do |dir|
        File.write(File.join(dir, 'iso3166.tab'), '')
        File.write(File.join(dir, 'zone1970.tab'), '')

        # In TZif versions prior to 4, leap second transition times
        # include prior leap seconds. In version 4 they are POSIX times.
        recorded_leaps = []
        previous_correction = 0
        leaps.each do |posix_time, correction|
          recorded = version == 4 ? posix_time : posix_time + previous_correction
          recorded_leaps << [recorded, correction]
          previous_correction = correction
        end

        zone_path = File.join(dir, 'Test', 'Leap')
        FileUtils.mkdir_p(File.dirname(zone_path))
        write_tzif(zone_path, version, OFFSETS, TRANSITIONS, recorded_leaps, 'UTC0', expires_at)

        yield dir, zone_path
      end
    end

    def create_data_source(dir)
      LeapAwareZoneinfoDataSource.new(dir)
    end

    def test_leap_second_table_from_tzif_v4
      with_leap_zoneinfo_dir do |dir, _|
        table = create_data_source(dir).leap_second_table
        assert_kind_of(LeapSeconds::LeapSecondTable, table)
        assert_equal(
          [LeapSeconds::LeapSecond.new(POSIX_LEAP, 1, 0), LeapSeconds::LeapSecond.new(NEGATIVE_LEAP, 0, 1)],
          table.leap_seconds)
        assert_equal(EXPIRES_AT, table.expires_at)
      end
    end

    def test_leap_second_table_from_tzif_v4_without_expiration
      with_leap_zoneinfo_dir(expires_at: nil) do |dir, _|
        table = create_data_source(dir).leap_second_table
        assert_kind_of(LeapSeconds::LeapSecondTable, table)
        assert_nil(table.expires_at)
      end
    end

    def test_leap_second_table_from_tzif_v3
      # In TZif versions prior to 4, leap second transition times include
      # prior leap seconds. The recorded times must be converted back to
      # POSIX times.
      with_leap_zoneinfo_dir(version: 3, expires_at: nil) do |dir, _|
        table = create_data_source(dir).leap_second_table
        assert_equal(
          [LeapSeconds::LeapSecond.new(POSIX_LEAP, 1, 0), LeapSeconds::LeapSecond.new(NEGATIVE_LEAP, 0, 1)],
          table.leap_seconds)
      end
    end

    def test_leap_second_table_from_tzif_v1
      with_leap_zoneinfo_dir(version: 1, expires_at: nil) do |dir, _|
        table = create_data_source(dir).leap_second_table
        assert_equal(
          [LeapSeconds::LeapSecond.new(POSIX_LEAP, 1, 0), LeapSeconds::LeapSecond.new(NEGATIVE_LEAP, 0, 1)],
          table.leap_seconds)
      end
    end

    def test_timezone_info_maintains_posix_semantics
      with_leap_zoneinfo_dir do |dir, _|
        data_source = create_data_source(dir)
        info = data_source.send(:load_timezone_info, 'Test/Leap')
        timezone = DataTimezone.new(info)

        # The LMT offset applies before the transition at 1970-01-01.
        assert_equal(-84, timezone.period_for_utc(Timestamp.utc(-1)).utc_total_offset)

        # Time and DateTime interfaces are unaffected by the leap seconds.
        [POSIX_LEAP, NEGATIVE_LEAP].each do |posix_time|
          assert_equal(0, timezone.period_for_utc(Timestamp.utc(posix_time)).utc_total_offset)

          time = Time.at(posix_time).utc
          assert_equal(posix_time, timezone.utc_to_local(time).to_i)

          datetime = DateTime.new(1972, 7, 1, 0, 0, 0) + Rational(posix_time - POSIX_LEAP, 86400)
          assert_equal(datetime, timezone.utc_to_local(datetime))
        end
      end
    end

    def test_leap_timestamp_for_utc_positive_leap_round_trip
      with_leap_zoneinfo_dir do |dir, _|
        data_source = create_data_source(dir)

        ts = data_source.leap_timestamp_for_utc(1972, 6, 30, 23, 59, 60)
        assert_equal(true, ts.leap_second?)
        assert_equal(POSIX_LEAP, ts.continuous)
        # The inserted leap second has no POSIX representation and must
        # not be folded onto a neighboring second.
        assert_nil(ts.posix)
        assert_equal([1972, 6, 30, 23, 59, 60], ts.utc)

        ordinary = data_source.leap_timestamp_for_utc(1972, 6, 30, 23, 59, 59)
        assert_equal(false, ordinary.leap_second?)
        assert_equal(POSIX_LEAP - 1, ordinary.posix)
        assert_equal(POSIX_LEAP - 1, ordinary.continuous)

        after = data_source.leap_timestamp_for_utc(1972, 7, 1, 0, 0, 0)
        assert_equal(POSIX_LEAP, after.posix)
        assert_equal(POSIX_LEAP + 1, after.continuous)
      end
    end

    def test_leap_timestamp_for_posix_and_continuous
      with_leap_zoneinfo_dir do |dir, _|
        data_source = create_data_source(dir)

        ts = data_source.leap_timestamp_for_posix(POSIX_LEAP)
        assert_equal(POSIX_LEAP + 1, ts.continuous)
        assert_equal([1972, 7, 1, 0, 0, 0], ts.utc)

        leap = data_source.leap_timestamp_for_continuous(POSIX_LEAP)
        assert_equal(true, leap.leap_second?)
        assert_equal([1972, 6, 30, 23, 59, 60], leap.utc)
      end
    end

    def test_negative_leap_second_deleted_time
      with_leap_zoneinfo_dir do |dir, _|
        data_source = create_data_source(dir)

        # The negative leap second removes 1972-12-31 23:59:59. No result
        # may be fabricated for the deleted time.
        assert_raises(LeapSeconds::UtcSecondNotFound) do
          data_source.leap_timestamp_for_utc(1972, 12, 31, 23, 59, 59)
        end

        assert_raises(LeapSeconds::UtcSecondNotFound) do
          data_source.leap_timestamp_for_posix(NEGATIVE_LEAP - 1)
        end

        # The continuous axis remains contiguous across the deletion.
        assert_equal(NEGATIVE_LEAP - 2, data_source.leap_timestamp_for_continuous(NEGATIVE_LEAP - 1).posix)
        assert_equal(NEGATIVE_LEAP, data_source.leap_timestamp_for_continuous(NEGATIVE_LEAP).posix)
      end
    end

    def test_expiration_of_leap_second_table
      with_leap_zoneinfo_dir do |dir, _|
        data_source = create_data_source(dir)

        # Times within the known range work.
        assert_equal(0, data_source.leap_second_table.correction_at(EXPIRES_AT - 1))

        # Times at and beyond the expiration of the table are explicitly
        # unknown - it cannot be assumed that there will be no further
        # leap seconds.
        assert_raises(LeapSeconds::LeapSecondTableExpired) do
          data_source.leap_second_table.correction_at(EXPIRES_AT)
        end

        assert_raises(LeapSeconds::LeapSecondTableExpired) do
          data_source.leap_timestamp_for_posix(EXPIRES_AT)
        end

        assert_raises(LeapSeconds::LeapSecondTableExpired) do
          data_source.leap_timestamp_for_utc(1973, 7, 1, 0, 0, 0)
        end

        assert_raises(LeapSeconds::LeapSecondTableExpired) do
          data_source.leap_timestamp_for_continuous(EXPIRES_AT)
        end
      end
    end

    def test_no_leap_second_data
      with_leap_zoneinfo_dir(leaps: []) do |dir, _|
        data_source = create_data_source(dir)
        assert_nil(data_source.leap_second_table)

        error = assert_raises(LeapSeconds::LeapSecondsError) do
          data_source.leap_timestamp_for_posix(0)
        end
        assert_match(/do not contain leap second data/, error.message)
      end
    end

    def test_zoneinfo_data_source_still_rejects_leap_second_data
      with_leap_zoneinfo_dir(version: 3) do |dir, _|
        data_source = ZoneinfoDataSource.new(dir)

        error = assert_raises(InvalidTimezoneIdentifier) do
          data_source.send(:load_timezone_info, 'Test/Leap')
        end
        assert_match(/contains leap second data/, error.message)
      end
    end

    def test_zoneinfo_reader_still_rejects_tzif_v4
      with_leap_zoneinfo_dir(leaps: []) do |_, zone_path|
        reader = ZoneinfoReader.new(PosixTimeZoneParser.new(StringDeduper.new), StringDeduper.new)

        error = assert_raises(InvalidZoneinfoFile) do
          reader.read(zone_path)
        end
        assert_match(/version of the zoneinfo format that is not currently supported/, error.message)
      end
    end

    def test_zoneinfo_reader_still_rejects_leap_second_data
      with_leap_zoneinfo_dir(version: 3) do |_, zone_path|
        reader = ZoneinfoReader.new(PosixTimeZoneParser.new(StringDeduper.new), StringDeduper.new)

        error = assert_raises(InvalidZoneinfoFile) do
          reader.read(zone_path)
        end
        assert_match(/contains leap second data/, error.message)
      end
    end
  end
end
