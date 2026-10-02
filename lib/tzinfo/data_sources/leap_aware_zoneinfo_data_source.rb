# encoding: UTF-8
# frozen_string_literal: true

module TZInfo
  module DataSources
    # A {ZoneinfoDataSource} variant that additionally exposes TZif v2, v3 and
    # v4 leap second tables. Ordinary {Timezone}, `Time` and `DateTime` queries
    # still use POSIX semantics; callers must request a {LeapSecondTable} or
    # {LeapTimestamp} explicitly to use leap-aware representations.
    class LeapAwareZoneinfoDataSource < ZoneinfoDataSource
      # Initializes a new leap-aware zoneinfo data source.
      #
      # @param args [Array<Object>] arguments accepted by
      #   {ZoneinfoDataSource#initialize}.
      def initialize(*args)
        super
        @leap_second_tables = Concurrent::Map.new
      end

      # Loads the leap second table for a time zone file.
      #
      # @param identifier [String] a time zone identifier.
      # @return [LeapSecondTable] the parsed leap second table.
      # @raise [InvalidTimezoneIdentifier] if the identifier is invalid or the
      #   referenced file does not contain a leap second table.
      def get_leap_second_table(identifier)
        valid_identifier = validate_leap_second_identifier(identifier)

        @leap_second_tables[valid_identifier] ||= begin
          path = File.join(@zoneinfo_dir, valid_identifier)
          @zoneinfo_reader.read_leap_seconds(path)
        rescue Errno::EACCES, InvalidZoneinfoFile => e
          raise InvalidTimezoneIdentifier, "#{e.message.encode(Encoding::UTF_8)} (loading #{valid_identifier})"
        rescue Errno::EISDIR, Errno::ENAMETOOLONG, Errno::ENOENT, Errno::ENOTDIR
          raise InvalidTimezoneIdentifier, "Invalid identifier: #{valid_identifier}"
        end
      end

      # Loads a leap-aware UTC timestamp from calendar fields.
      #
      # @param identifier [String] a time zone identifier whose TZif file
      #   contains a leap second table.
      # @param year [Integer] the year.
      # @param month [Integer] the month.
      # @param day [Integer] the day.
      # @param hour [Integer] the hour.
      # @param minute [Integer] the minute.
      # @param second [Integer] the second (0-60).
      # @return [LeapTimestamp] the leap-aware timestamp.
      def leap_timestamp(identifier, year, month = 1, day = 1, hour = 0, minute = 0, second = 0)
        LeapTimestamp.utc(get_leap_second_table(identifier), year, month, day, hour, minute, second)
      end

      # @return [String] a description of the data source.
      def to_s
        "Leap-Aware Zoneinfo DataSource: #{@zoneinfo_dir}"
      end

      # @return [String] the internal object state.
      def inspect
        "#<#{self.class}: #{@zoneinfo_dir}>"
      end

      private

      def validate_leap_second_identifier(identifier)
        raise InvalidTimezoneIdentifier, "Invalid identifier: #{identifier.nil? ? 'nil' : identifier}" unless identifier.kind_of?(String)

        valid_identifier = begin
          identifier.encode(Encoding::UTF_8)
        rescue EncodingError
          nil
        end

        components = valid_identifier && valid_identifier.split('/'.freeze, -1)
        valid = components && !components.empty? && components.all? do |component|
          component =~ /\A[A-Za-z0-9._+-]+\z/ && component != '.' && component != '..'
        end

        raise InvalidTimezoneIdentifier, "Invalid identifier: #{identifier}" unless valid
        valid_identifier
      end
    end
  end
end
