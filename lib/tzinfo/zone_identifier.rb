# encoding: UTF-8
# frozen_string_literal: true

require 'set'

module TZInfo
  # Identifies the time zones that are consistent with a set of logged
  # observations, without making any assumptions about the location the
  # observations were recorded in.
  #
  # Each {Observation} pairs a UTC time with the local time (and optionally
  # the abbreviation) that was displayed at that instant. {ZoneIdentifier}
  # checks every observation against the historical rules of each candidate
  # {Timezone} (as they were at the time of the observation, not the rules
  # currently in force) and returns all the candidates that are consistent
  # with every observation.
  #
  # Candidates that cannot be distinguished by the observations (for example,
  # aliases of the same zone, or zones that happen to share the same offsets
  # over the observed period) are returned together as a {CandidateGroup}.
  # {ZoneIdentifier} never picks a single zone on behalf of the caller.
  #
  # All data is supplied by the caller: observations are passed as
  # {Observation} instances (or Hashes) and the allowed set of zones is passed
  # as {Timezone} instances (obtained from any {DataSource}). No data source
  # is accessed implicitly.
  class ZoneIdentifier
    # A single observed pairing of a UTC time with the local time that was
    # displayed at that instant.
    class Observation
      # @return [Object] the UTC time of the observation as a `Time`,
      #   `DateTime` or {Timestamp}.
      attr_reader :utc

      # @return [Object] the local time that was displayed, as a `Time`,
      #   `DateTime` or {Timestamp}. Only the wall-clock components are used;
      #   any UTC offset attached to the value is ignored.
      attr_reader :local

      # @return [String] the optional abbreviation that was displayed (for
      #   example 'BST'), or `nil` if not recorded.
      attr_reader :abbreviation

      # @return [Numeric] the maximum allowed difference in seconds between
      #   the observed local time and the local time derived from a
      #   candidate's UTC offset, or `nil` to use the default passed to
      #   {ZoneIdentifier#identify}.
      attr_reader :tolerance

      # @param utc [Object] the UTC time of the observation (`Time`,
      #   `DateTime` or {Timestamp}).
      # @param local [Object] the displayed local (wall-clock) time (`Time`,
      #   `DateTime` or {Timestamp}).
      # @param abbreviation [String] the optional displayed abbreviation.
      # @param tolerance [Numeric] an optional per-observation seconds
      #   tolerance overriding the default passed to
      #   {ZoneIdentifier#identify}.
      # @raise [ArgumentError] if `utc` or `local` is `nil`.
      def initialize(utc, local, abbreviation = nil, tolerance = nil)
        raise ArgumentError, 'utc must be specified' unless utc
        raise ArgumentError, 'local must be specified' unless local
        raise ArgumentError, 'tolerance must be >= 0' if tolerance && tolerance < 0
        @utc = utc
        @local = local
        @abbreviation = abbreviation
        @tolerance = tolerance
        freeze
      end

      # @return [Numeric] the observed offset from UTC in seconds (the
      #   difference between the local wall-clock time and the UTC time).
      def observed_offset
        self.class.wall_value(local) - self.class.utc_value(utc)
      end

      class << self
        # @private
        # Converts a UTC time-like value to seconds since the epoch.
        def utc_value(time)
          timestamp = time.kind_of?(Timestamp) ? time : Timestamp.for(time)
          timestamp.value + timestamp.sub_second
        end

        # @private
        # Converts a local time-like value to a wall-clock value in seconds
        # (the displayed components interpreted as though they were UTC).
        def wall_value(time)
          case time
            when Timestamp
              time.value + time.sub_second
            when Time, DateTime
              fraction = time.respond_to?(:subsec) ? time.subsec : time.sec_fraction
              Time.utc(time.year, time.month, time.day, time.hour, time.min, time.sec).to_i + fraction
            else
              raise ArgumentError, "#{time.class} values are not supported"
          end
        end
      end
    end

    # A group of candidate {Timezone} instances that are consistent with
    # every observation and cannot be distinguished from each other by those
    # observations.
    class CandidateGroup
      # @return [Array<Timezone>] the {Timezone} instances in the group.
      attr_reader :zones

      # @return [Array<Array>] the observed behavior of the group: one
      #   `[utc_total_offset, abbreviation]` pair per observation.
      attr_reader :signature

      # @return [Boolean] whether the abbreviation of every observation that
      #   recorded one matches the group's abbreviation at that observation.
      attr_reader :abbreviation_matched
      alias abbreviation_matched? abbreviation_matched

      # @private
      def initialize(zones, signature, abbreviation_matched)
        @zones = zones.freeze
        @signature = signature.freeze
        @abbreviation_matched = abbreviation_matched
        @identifiers = zones.map {|z| z.identifier }.sort.freeze
        @canonical_identifiers = zones.map {|z| z.canonical_zone.identifier }.uniq.sort.freeze
        @aliases = zones.each_with_object({}) do |zone, result|
          canonical = zone.canonical_zone.identifier
          result[zone.identifier] = canonical if zone.identifier != canonical
        end.freeze
        freeze
      end

      # @return [Array<String>] the identifiers of all the zones in the
      #   group, including aliases, sorted alphabetically.
      attr_reader :identifiers

      # @return [Array<String>] the canonical identifiers of the zones in the
      #   group, sorted alphabetically.
      attr_reader :canonical_identifiers

      # @return [Hash{String => String}] a mapping of alias identifier to
      #   canonical identifier for each zone in the group that is an alias
      #   (link) of another zone.
      attr_reader :aliases
    end

    # The result of {ZoneIdentifier#identify}.
    class Result
      include Enumerable

      # @return [Array<CandidateGroup>] the groups of indistinguishable
      #   candidates that are consistent with every observation. When
      #   abbreviations are used as a hint, groups consistent with the
      #   observed abbreviations are listed first.
      attr_reader :groups

      # @return [Array<Observation>] when no candidate is consistent with
      #   every observation, a minimal set of observations that cannot be
      #   satisfied simultaneously by any single candidate; `nil` otherwise.
      attr_reader :conflicting_observations

      # @private
      def initialize(groups, conflicting_observations)
        @groups = groups.freeze
        @conflicting_observations = conflicting_observations && conflicting_observations.freeze
        freeze
      end

      # @yield [group] each {CandidateGroup} in turn.
      def each(&block)
        groups.each(&block)
      end

      # @return [Boolean] whether at least one candidate is consistent with
      #   every observation.
      def matches?
        !groups.empty?
      end

      # @return [Boolean] whether the observations identify exactly one
      #   canonical zone.
      def unique?
        groups.length == 1 && groups.first.canonical_identifiers.length == 1
      end

      # @return [Array<String>] the identifiers of all matching candidates,
      #   including aliases.
      def identifiers
        groups.flat_map {|g| g.identifiers }
      end

      # @return [Array<String>] the canonical identifiers of all matching
      #   candidates.
      def canonical_identifiers
        groups.flat_map {|g| g.canonical_identifiers }.uniq
      end
    end

    # Identifies the candidates that are consistent with every observation.
    #
    # @param observations [Array<Observation, Hash>] the observations to
    #   match. Hashes are converted to {Observation} instances using the
    #   keys `:utc`, `:local`, `:abbreviation` and `:tolerance`.
    # @param candidates [Array<Timezone>] the allowed set of {Timezone}
    #   instances, obtained by the caller from any {DataSource}.
    # @param options [Hash] zero or more of the following keys:
    #   `:tolerance` — the default maximum allowed difference in seconds
    #   between an observed local time and the local time derived from a
    #   candidate's UTC offset (defaults to 0, can be overridden per
    #   observation); `:abbreviation` — how recorded abbreviations are
    #   used: `:hint` (the default) keeps all offset-consistent candidates
    #   but orders groups that also match the observed abbreviations first,
    #   `:strict` requires the abbreviation to match whenever an
    #   observation records one, and `:ignore` disregards abbreviations
    #   entirely.
    # @return [Result] the matching groups, or, when there are none, a result
    #   whose {Result#conflicting_observations} identifies a set of mutually
    #   incompatible observations.
    # @raise [ArgumentError] if `observations` or `candidates` is empty, an
    #   unknown option is given, or `:abbreviation` is not `:hint`,
    #   `:strict` or `:ignore`.
    def identify(observations, candidates, options = {})
      unknown_options = options.keys - [:tolerance, :abbreviation]
      raise ArgumentError, "unknown options: #{unknown_options.join(', ')}" unless unknown_options.empty?

      tolerance = options.fetch(:tolerance, 0)
      abbreviation = options.fetch(:abbreviation, :hint)

      unless [:hint, :strict, :ignore].include?(abbreviation)
        raise ArgumentError, 'abbreviation must be :hint, :strict or :ignore'
      end
      raise ArgumentError, 'tolerance must be >= 0' if tolerance < 0

      obs = observations.map {|o| normalize_observation(o) }
      raise ArgumentError, 'at least one observation is required' if obs.empty?

      zones = candidates.to_a.uniq {|z| z.identifier }
      raise ArgumentError, 'at least one candidate is required' if zones.empty?

      include_abbreviation = abbreviation != :ignore

      # The behavior of each candidate at each observation, determined from
      # the zone's historical rules in force at that time.
      entries = zones.map do |zone|
        signature = obs.map do |observation|
          period = zone.period_for_utc(observation.utc)
          [period.utc_total_offset, period.abbreviation]
        end
        [zone, signature]
      end

      matching = entries.select do |_zone, signature|
        obs.each_with_index.all? do |observation, index|
          offset, abbr = signature[index]
          limit = observation.tolerance || tolerance
          (observation.observed_offset - offset).abs <= limit &&
            (abbreviation != :strict || observation.abbreviation.nil? ||
              abbr == observation.abbreviation)
        end
      end

      groups = matching.group_by {|_zone, signature| include_abbreviation ? signature : signature.map(&:first) }.map do |_key, grouped|
        signature = grouped.first[1]
        abbreviation_matched = obs.each_with_index.all? do |observation, index|
          observation.abbreviation.nil? || signature[index][1] == observation.abbreviation
        end
        CandidateGroup.new(grouped.map(&:first), signature, abbreviation_matched)
      end

      groups.sort_by!.with_index {|group, index| [group.abbreviation_matched? ? 0 : 1, index] }

      conflicts = groups.empty? ? find_conflicting_observations(obs, entries, tolerance, abbreviation) : nil
      Result.new(groups, conflicts)
    end

    private

    def normalize_observation(observation)
      case observation
        when Observation
          observation
        when Hash
          unknown = observation.keys - [:utc, :local, :abbreviation, :tolerance]
          raise ArgumentError, "unknown observation keys: #{unknown.join(', ')}" unless unknown.empty?
          Observation.new(observation[:utc], observation[:local],
            observation[:abbreviation], observation[:tolerance])
        else
          raise ArgumentError, "#{observation.class} observations are not supported"
      end
    end

    # Returns a minimal subset of the observations that no single candidate
    # can satisfy simultaneously.
    def find_conflicting_observations(obs, entries, tolerance, abbreviation)
      # The set of candidates (by index into entries) consistent with each
      # individual observation.
      satisfiers = obs.each_with_index.map do |observation, obs_index|
        limit = observation.tolerance || tolerance
        entries.each_with_index.select do |(_zone, signature), _entry_index|
          offset, abbr = signature[obs_index]
          (observation.observed_offset - offset).abs <= limit &&
            (abbreviation != :strict || observation.abbreviation.nil? ||
              abbr == observation.abbreviation)
        end.map(&:last).to_set
      end

      # Greedily drop observations while the remaining set is still
      # unsatisfiable, leaving an irreducible incompatible subset.
      remaining = (0...obs.length).to_a
      remaining.each do |index|
        next unless remaining.include?(index)
        candidate = remaining - [index]
        next if candidate.empty?
        remaining = candidate if unsatisfiable?(satisfiers, candidate)
      end
      remaining.map {|index| obs[index] }
    end

    def unsatisfiable?(satisfiers, indices)
      indices.map {|i| satisfiers[i] }.reduce(:&).empty?
    end
  end
end
