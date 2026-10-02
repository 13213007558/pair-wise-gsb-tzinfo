# encoding: UTF-8
# frozen_string_literal: true

module TZInfo
  # Raised when a time cannot be represented on either the POSIX or
  # continuous-second timescale used by a leap-second-aware data source.
  class LeapSecondError < StandardError
  end

  # Raised when a conversion crosses the beginning or end of the known leap
  # second table, or when it refers to a UTC second removed by a negative leap
  # second.
  class LeapSecondOutOfRangeError < LeapSecondError
  end
end
