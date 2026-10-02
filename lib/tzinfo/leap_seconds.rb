# encoding: UTF-8
# frozen_string_literal: true

module TZInfo
  # Support for working with leap seconds.
  #
  # This is an opt-in extension to TZInfo's core functionality. The core
  # {Time}- and {DateTime}-based interfaces continue to use POSIX semantics
  # (every day is treated as if it were exactly 86,400 seconds long and leap
  # seconds are ignored).
  #
  # {LeapSeconds::LeapSecondTable} represents a table of leap seconds as
  # found in TZif version 4 (or earlier) zoneinfo files. It converts between
  # POSIX times (UTC seconds ignoring leap seconds) and positions on a
  # continuous seconds axis that counts every elapsed second (including
  # inserted leap seconds).
  #
  # {LeapSeconds::LeapTimestamp} represents a single moment in time according
  # to a {LeapSeconds::LeapSecondTable}, distinguishing ordinary UTC seconds
  # from inserted leap seconds (for example, 23:59:60).
  #
  # Leap second data can be loaded from zoneinfo files by using
  # {DataSources::LeapAwareZoneinfoDataSource}.
  module LeapSeconds
    # The base class for exceptions raised by leap second handling code.
    class LeapSecondsError < StandardError
    end

    # Raised when a time falls outside of the known range of a
    # {LeapSecondTable} (at or after its expiration time). The correction
    # that applies beyond the expiration of a leap second table is unknown -
    # it cannot be assumed that no further leap seconds will be introduced.
    class LeapSecondTableExpired < LeapSecondsError
    end

    # Raised when a UTC second does not exist according to a
    # {LeapSecondTable}. This occurs when referencing a second that was
    # removed by a negative leap second, or when referencing 23:59:60 on a
    # day when no positive leap second was inserted.
    class UtcSecondNotFound < LeapSecondsError
    end
  end
end

require_relative 'leap_seconds/leap_second'
require_relative 'leap_seconds/leap_second_table'
require_relative 'leap_seconds/leap_timestamp'
