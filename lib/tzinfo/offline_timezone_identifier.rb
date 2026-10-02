# encoding: UTF-8
# frozen_string_literal: true

module TZInfo
  # Represents an observation consisting of a UTC time, the time displayed by a
  # clock in the unknown time zone and an optional time zone abbreviation.
  #
  # The UTC offset of `local_time` is ignored. Its calendar date and time of
  # day are treated as the displayed local time.
  class TimezoneObservation
    # @return [Object] the observed UTC time (`Time`, `DateTime` or
    #   {Timestamp}).
    attr_reader :utc_time

    # @return [Object] the observed local wall-clock time (`Time`, `DateTime`
    #   or {Timestamp}). The UTC offset of the object is ignored.
    attr_reader :local_time

    # @return [String, nil] the observed abbreviation, or `nil` if no
    #   abbreviation was recorded.
    attr_reader :abbreviation

    # @return [Numeric, nil] the maximum permitted difference between the
    #   observed and calculated local times in seconds, or `nil` if the default
    #   tolerance supplied to {OfflineTimezoneIdentifier#identify} should be
    #   used.
    attr_reader :tolerance

    # Initializes a new {TimezoneObservation}.
    #
    # @param utc_time [Object] the observed UTC time.
    # @param local_time [Object] the observed local wall-clock time.
    # @param abbreviation [String, nil] the observed abbreviation, or `nil`.
    # @param tolerance [Numeric, nil] the maximum local time difference in
    #   seconds, or `nil` to use the default tolerance.
    def initialize(utc_time, local_time, abbreviation = nil, tolerance = nil)
      raise ArgumentError, 'utc_time must be specified' unless utc_time
      raise ArgumentError, 'local_time must be specified' unless local_time

      if abbreviation
        unless abbreviation.respond_to?(:to_str) && abbreviation.to_str.kind_of?(String)
          raise ArgumentError, 'abbreviation must be a String or nil'
        end

        abbreviation = abbreviation.to_str
      end

      if tolerance
        raise ArgumentError, 'tolerance must be a Numeric' unless tolerance.kind_of?(Numeric)
        tolerance = Rational(tolerance)
        raise ArgumentError, 'tolerance must be greater than or equal to 0' if tolerance < 0
      end

      @utc_time = utc_time
      @local_time = local_time
      @abbreviation = abbreviation && abbreviation.freeze
      @tolerance = tolerance
      freeze
    end
  end

  # A group of time zones that cannot be distinguished from each other using
  # the supplied observations.
  class TimezoneCandidateGroup
    # @return [Array<Timezone>] the candidate time zones supplied by the
    #   caller, sorted by identifier.
    attr_reader :timezones

    # @return [Array<Timezone>] the unique canonical time zones represented by
    #   the candidates, sorted by identifier.
    attr_reader :canonical_timezones

    # @return [Hash{String => String}] a map from each supplied identifier to
    #   its canonical identifier. Identity mappings are included for canonical
    #   zones.
    attr_reader :canonical_identifiers_by_identifier

    # @return [Array<Integer, nil>] the observed UTC offsets in seconds used by
    #   the candidates for each observation. Entries are `nil` when that
    #   observation allowed time tolerance, preventing different offsets from
    #   being distinguished.
    attr_reader :observed_utc_offsets

    # @return [Integer] the number of observed abbreviations matched by members
    #   of the group. Abbreviations are only counted when they are present in
    #   the observations.
    attr_reader :abbreviation_match_count

    # @private
    def initialize(timezones, canonical_timezones, mapping, offsets, abbreviation_match_count)
      @timezones = timezones.freeze
      @canonical_timezones = canonical_timezones.freeze
      @canonical_identifiers_by_identifier = mapping.freeze
      @observed_utc_offsets = offsets.freeze
      @abbreviation_match_count = abbreviation_match_count
      freeze
    end

    # @return [Array<String>] the identifiers of the candidate time zones.
    def identifiers
      timezones.collect(&:identifier)
    end

    # @return [Array<String>] the identifiers of the unique canonical time
    #   zones.
    def canonical_identifiers
      canonical_timezones.collect(&:identifier)
    end

    # @return [Hash{String => String}] the subset of
    #   {#canonical_identifiers_by_identifier} containing aliases only.
    def aliases
      canonical_identifiers_by_identifier.reject {|identifier, canonical_identifier| identifier == canonical_identifier }
    end
  end

  # The result of an offline time zone identification.
  class TimezoneIdentificationResult
    # @return [Array<TimezoneObservation>] the observations supplied to the
    #   identifier.
    attr_reader :observations

    # @return [Array<TimezoneCandidateGroup>] the matching candidate groups.
    attr_reader :candidate_groups

    # @return [Array<Integer>] the indices of a minimal subset of observations
    #   that no allowed time zone matches. Empty when candidates exist.
    attr_reader :incompatible_observation_indices

    # @private
    def initialize(observations, candidate_groups, incompatible_observation_indices)
      @observations = observations.freeze
      @candidate_groups = candidate_groups.freeze
      @incompatible_observation_indices = incompatible_observation_indices.freeze
      freeze
    end

    # @return [Boolean] `true` if at least one candidate was found, otherwise
    #   `false`.
    def candidates?
      !candidate_groups.empty?
    end

    alias found? candidates?

    # @return [Array<TimezoneObservation>] a minimal subset of observations that
    #   cannot all be satisfied by one allowed time zone. Empty when candidates
    #   exist.
    def incompatible_observations
      incompatible_observation_indices.collect {|index| observations[index] }
    end
  end

  # Identifies candidate time zones from historical UTC and local wall-clock
  # observations without consulting a global or implicit data source.
  #
  # The allowed time zones are supplied as already-loaded {Timezone} objects.
  # Each observation is checked against the period that was in effect at the
  # observed UTC instant, so historical offsets and abbreviations are used.
  class OfflineTimezoneIdentifier
    # Indicates that observed abbreviations should be ignored for matching,
    # but matching abbreviations should be counted when ordering candidates.
    HINT = :hint

    # Indicates that observed abbreviations are mandatory. Observations without
    # an abbreviation do not constrain the result.
    STRICT = :strict

    # Initializes a new {OfflineTimezoneIdentifier}.
    #
    # @param allowed_timezones [Enumerable<Timezone>] the time zones permitted
    #   in the result.
    # @raise [ArgumentError] if `allowed_timezones` is empty or contains an
    #   object that does not behave as a {Timezone}.
    def initialize(allowed_timezones)
      raise ArgumentError, 'allowed_timezones must respond to each' unless allowed_timezones.respond_to?(:each)

      zones_by_identifier = {}
      allowed_timezones.each do |timezone|
        validate_timezone(timezone)
        zones_by_identifier[timezone.identifier] = timezone
      end

      @timezones = zones_by_identifier.values.sort_by(&:identifier).freeze
      raise ArgumentError, 'allowed_timezones must not be empty' if @timezones.empty?
    end

    # @return [Array<String>] the identifiers of the allowed time zones.
    def allowed_identifiers
      @timezones.collect(&:identifier)
    end

    # Identifies the allowed time zones that match all observations.
    #
    # @param observations [Enumerable<TimezoneObservation>] the observations
    #   that a candidate must match.
    # @param abbreviation_mode [Symbol] either {HINT} or {STRICT}.
    # @param tolerance [Numeric] the default number of seconds by which a local
    #   time may differ. It is used for observations that do not specify their
    #   own tolerance.
    # @return [TimezoneIdentificationResult] the matching groups or, when none
    #   match, a minimal incompatible subset of observations.
    def identify(observations, abbreviation_mode = HINT, tolerance = 0)
      unless abbreviation_mode == HINT || abbreviation_mode == STRICT
        raise ArgumentError, 'abbreviation_mode must be :hint or :strict'
      end

      raise ArgumentError, 'tolerance must be a Numeric' unless tolerance.kind_of?(Numeric)
      tolerance = Rational(tolerance)
      raise ArgumentError, 'tolerance must be greater than or equal to 0' if tolerance < 0
      raise ArgumentError, 'observations must respond to each' unless observations.respond_to?(:each)

      observations = observations.to_a
      raise ArgumentError, 'observations must not be empty' if observations.empty?
      observations.each_with_index do |observation, index|
        unless observation.kind_of?(TimezoneObservation)
          raise ArgumentError, "observation at index #{index} must be a TZInfo::TimezoneObservation"
        end
      end

      matches = @timezones.collect do |timezone|
        match_timezone(timezone, observations, abbreviation_mode, tolerance)
      end
      matches.compact!

      if matches.empty?
        incompatible = find_incompatible_observation_indices(observations, abbreviation_mode, tolerance)
        return TimezoneIdentificationResult.new(observations, [], incompatible)
      end

      groups = build_groups(matches)
      TimezoneIdentificationResult.new(observations, groups, [])
    end

    private

    def validate_timezone(timezone)
      unless timezone.kind_of?(Timezone)
        raise ArgumentError, 'allowed time zone must be a TZInfo::Timezone'
      end

      identifier = timezone.identifier
      unless identifier.kind_of?(String) && !identifier.empty?
        raise ArgumentError, 'allowed time zone identifier must be a non-empty String'
      end

      canonical_identifier = timezone.canonical_zone.identifier
      unless canonical_identifier.kind_of?(String) && !canonical_identifier.empty?
        raise ArgumentError, 'canonical time zone identifier must be a non-empty String'
      end
    end

    def match_timezone(timezone, observations, abbreviation_mode, default_tolerance)
      offsets = []
      group_key = []
      abbreviation_matches = 0

      observations.each do |observation|
        utc_timestamp = Timestamp.for(observation.utc_time, :treat_as_utc)
        period = timezone.period_for_utc(utc_timestamp)
        expected_local = Timestamp.for(observation.local_time, :ignore)
        actual_local_value = utc_timestamp.value + period.observed_utc_offset
        difference = (actual_local_value + utc_timestamp.sub_second) -
          (expected_local.value + expected_local.sub_second)
        observation_tolerance = observation.tolerance || default_tolerance

        return nil if difference.abs > observation_tolerance
        return nil if abbreviation_mode == STRICT && observation.abbreviation &&
          period.abbreviation != observation.abbreviation

        if observation.abbreviation && period.abbreviation == observation.abbreviation
          abbreviation_matches += 1
        end

        if observation_tolerance == 0
          offsets << period.observed_utc_offset
          group_key << period.observed_utc_offset
        else
          offsets << nil
        end
      end

      {
        :timezone => timezone,
        :offsets => offsets,
        :group_key => group_key,
        :abbreviation_matches => abbreviation_matches
      }
    end

    def find_incompatible_observation_indices(observations, abbreviation_mode, default_tolerance)
      remaining = (0...observations.length).to_a

      observations.each_index do |index|
        next unless remaining.include?(index)
        next if remaining.length <= 1

        trial = remaining - [index]
        no_match = @timezones.none? do |timezone|
          trial.all? do |observation_index|
            match_timezone(timezone, [observations[observation_index]], abbreviation_mode, default_tolerance)
          end
        end

        remaining = trial if no_match
      end

      remaining
    end

    def build_groups(matches)
      groups = {}

      matches.each do |match|
        timezone = match[:timezone]
        canonical_timezone = timezone.canonical_zone
        key = match[:group_key]
        group = groups[key] ||= {
          :timezones => [],
          :canonical_timezones => {},
          :mapping => {},
          :observed_utc_offsets => match[:offsets],
          :abbreviation_matches => 0
        }

        group[:timezones] << timezone
        group[:canonical_timezones][canonical_timezone.identifier] = canonical_timezone
        group[:mapping][timezone.identifier] = canonical_timezone.identifier
        group[:abbreviation_matches] = [group[:abbreviation_matches], match[:abbreviation_matches]].max
      end

      groups.collect do |offsets, group|
        timezones = group[:timezones].sort_by(&:identifier)
        canonical_timezones = group[:canonical_timezones].values.sort_by(&:identifier)
        mapping = Hash[group[:mapping].sort]

        TimezoneCandidateGroup.new(
          timezones,
          canonical_timezones,
          mapping,
          group[:observed_utc_offsets],
          group[:abbreviation_matches]
        )
      end.sort do |first, second|
        order = second.abbreviation_match_count <=> first.abbreviation_match_count
        order = first.canonical_identifiers.first <=> second.canonical_identifiers.first if order == 0
        order = first.identifiers.first <=> second.identifiers.first if order == 0
        order
      end
    end
  end
end
