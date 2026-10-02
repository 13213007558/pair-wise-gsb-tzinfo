# encoding: UTF-8
# frozen_string_literal: true

require_relative 'test_utils'

class TCOfflineTimezoneIdentifier < Minitest::Test
  include TZInfo

  def setup
    @timezones = ['Europe/Andorra', 'Europe/Brussels', 'Europe/Paris', 'Europe/Prague'].collect do |identifier|
      Timezone.get(identifier)
    end

    @paris_alias = LinkedTimezone.new(DataSources::LinkedTimezoneInfo.new('Test/Paris_Alias', 'Europe/Paris'))
  end

  def test_uses_historical_rules_to_distinguish_currently_similar_zones
    result = identify([observation(Time.utc(1946, 7, 1, 12), Time.utc(1946, 7, 1, 13))])

    assert_equal([['Europe/Paris']], result.candidate_groups.collect(&:canonical_identifiers))
    assert_equal([3600], result.candidate_groups.first.observed_utc_offsets)
  end

  def test_modern_winter_observation_remains_non_unique
    result = identify([observation(Time.utc(2024, 1, 1, 12), Time.utc(2024, 1, 1, 13))])

    assert_equal(1, result.candidate_groups.length)
    assert_equal(
      ['Europe/Andorra', 'Europe/Brussels', 'Europe/Paris', 'Europe/Prague'],
      result.candidate_groups.first.canonical_identifiers
    )
  end

  def test_modern_summer_and_winter_observations_remain_non_unique
    result = identify([
      observation(Time.utc(2024, 1, 1, 12), Time.utc(2024, 1, 1, 13)),
      observation(Time.utc(2024, 7, 1, 12), Time.utc(2024, 7, 1, 14))
    ])

    assert_equal(1, result.candidate_groups.length)
    assert_equal(
      ['Europe/Andorra', 'Europe/Brussels', 'Europe/Paris', 'Europe/Prague'],
      result.candidate_groups.first.canonical_identifiers
    )
    assert_equal([3600, 7200], result.candidate_groups.first.observed_utc_offsets)
  end

  def test_keeps_alias_to_canonical_identifier_mapping
    result = OfflineTimezoneIdentifier.new(@timezones + [@paris_alias]).identify([
      observation(Time.utc(2024, 1, 1, 12), Time.utc(2024, 1, 1, 13)),
      observation(Time.utc(2024, 7, 1, 12), Time.utc(2024, 7, 1, 14))
    ])

    group = result.candidate_groups.first
    assert_includes(group.identifiers, 'Test/Paris_Alias')
    assert_includes(group.canonical_identifiers, 'Europe/Paris')
    assert_equal('Europe/Paris', group.canonical_identifiers_by_identifier['Test/Paris_Alias'])
    assert_equal({ 'Test/Paris_Alias' => 'Europe/Paris' }, group.aliases)
  end

  def test_second_tolerance_matches_one_second_difference
    result = identify(
      [observation(Time.utc(2024, 1, 1, 12), Time.utc(2024, 1, 1, 13, 0, 1))],
      OfflineTimezoneIdentifier::HINT,
      1
    )

    assert_equal(
      [['Europe/Andorra', 'Europe/Brussels', 'Europe/Paris', 'Europe/Prague']],
      result.candidate_groups.collect(&:canonical_identifiers)
    )
  end

  def test_per_observation_tolerance_overrides_default
    result = identify(
      [observation(Time.utc(2024, 1, 1, 12), Time.utc(2024, 1, 1, 13, 0, 1), nil, 1)],
      OfflineTimezoneIdentifier::HINT,
      0
    )

    assert_equal(
      [['Europe/Andorra', 'Europe/Brussels', 'Europe/Paris', 'Europe/Prague']],
      result.candidate_groups.collect(&:canonical_identifiers)
    )
  end

  def test_tolerance_groups_otherwise_distinguishable_offsets
    result = identify(
      [observation(Time.utc(1946, 7, 1, 12), Time.utc(1946, 7, 1, 12, 59, 59))],
      OfflineTimezoneIdentifier::HINT,
      3600
    )

    assert_equal(
      [['Europe/Andorra', 'Europe/Paris']],
      result.candidate_groups.collect(&:canonical_identifiers)
    )
    assert_equal([nil], result.candidate_groups.first.observed_utc_offsets)
  end

  def test_abbreviation_hint_orders_matching_group_first_without_filtering
    result = identify([observation(
      Time.utc(1945, 9, 1, 12),
      Time.utc(1945, 9, 1, 14),
      'WEMT'
    )])

    assert_equal(
      [['Europe/Brussels', 'Europe/Paris', 'Europe/Prague']],
      result.candidate_groups.collect(&:canonical_identifiers)
    )
    assert_equal(1, result.candidate_groups.first.abbreviation_match_count)
  end

  def test_strict_abbreviation_excludes_non_matching_candidates
    result = identify(
      [observation(Time.utc(1945, 9, 1, 12), Time.utc(1945, 9, 1, 14), 'WEMT')],
      OfflineTimezoneIdentifier::STRICT
    )

    assert_equal([['Europe/Paris']], result.candidate_groups.collect(&:canonical_identifiers))
  end

  def test_ignores_offset_attached_to_local_time
    local_time = Time.new(1946, 7, 1, 13, 0, 0, -14400)
    result = identify([observation(Time.utc(1946, 7, 1, 12), local_time)])

    assert_equal([['Europe/Paris']], result.candidate_groups.collect(&:canonical_identifiers))
  end

  def test_returns_minimal_incompatible_observation_set
    observations = [
      observation(Time.utc(1946, 7, 1, 12), Time.utc(1946, 7, 1, 13)),
      observation(Time.utc(1946, 7, 1, 12), Time.utc(1946, 7, 1, 14)),
      observation(Time.utc(2024, 1, 1, 12), Time.utc(2024, 1, 1, 13))
    ]
    result = identify(observations)

    refute(result.found?)
    assert_equal([0, 1], result.incompatible_observation_indices)
    assert_equal([observations[0], observations[1]], result.incompatible_observations)
  end

  def test_returns_single_observation_when_it_has_no_candidates
    observations = [
      observation(Time.utc(1946, 7, 1, 12), Time.utc(1946, 7, 1, 12, 30))
    ]
    result = identify(observations)

    refute(result.found?)
    assert_equal([0], result.incompatible_observation_indices)
    assert_equal(observations, result.incompatible_observations)
  end

  def test_rejects_invalid_abbreviation_mode
    error = assert_raises(ArgumentError) do
      identify([observation(Time.utc(2024, 1, 1), Time.utc(2024, 1, 1, 1))], :unknown)
    end

    assert_equal('abbreviation_mode must be :hint or :strict', error.message)
  end

  def test_rejects_empty_allowed_timezones
    error = assert_raises(ArgumentError) { OfflineTimezoneIdentifier.new([]) }
    assert_equal('allowed_timezones must not be empty', error.message)
  end

  def test_rejects_non_timezone_candidate
    error = assert_raises(ArgumentError) { OfflineTimezoneIdentifier.new([Object.new]) }
    assert_equal('allowed time zone must be a TZInfo::Timezone', error.message)
  end

  def test_rejects_non_observation
    error = assert_raises(ArgumentError) { identify([{}]) }
    assert_equal('observation at index 0 must be a TZInfo::TimezoneObservation', error.message)
  end

  private

  def identify(observations, abbreviation_mode = OfflineTimezoneIdentifier::HINT, tolerance = 0)
    OfflineTimezoneIdentifier.new(@timezones).identify(observations, abbreviation_mode, tolerance)
  end

  def observation(utc_time, local_time, abbreviation = nil, tolerance = nil)
    TimezoneObservation.new(utc_time, local_time, abbreviation, tolerance)
  end
end
