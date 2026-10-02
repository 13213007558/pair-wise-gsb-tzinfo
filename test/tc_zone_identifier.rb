# encoding: UTF-8
# frozen_string_literal: true

require_relative 'test_utils'

class TCZoneIdentifier < Minitest::Test
  include TZInfo

  Observation = ZoneIdentifier::Observation

  def setup
    @identifier = ZoneIdentifier.new
    @paris = Timezone.get('Europe/Paris')
    @brussels = Timezone.get('Europe/Brussels')
    @prague = Timezone.get('Europe/Prague')
    @london = Timezone.get('Europe/London')
    @new_york = Timezone.get('America/New_York')
    @utc = Timezone.get('Etc/UTC')
  end

  def linked_zone(identifier, link_to_identifier)
    LinkedTimezone.new(DataSources::LinkedTimezoneInfo.new(identifier, link_to_identifier))
  end

  # Europe/Paris, Europe/Brussels and Europe/Prague all observe CET/CEST
  # with the same offsets in 2004. A single observation from that period
  # cannot identify a unique zone.
  def test_single_observation_returns_indistinguishable_group
    result = @identifier.identify(
      [{utc: Time.utc(2004, 7, 1, 12), local: Time.utc(2004, 7, 1, 14)}],
      [@paris, @brussels, @prague, @london, @new_york])

    assert(result.matches?)
    refute(result.unique?)
    assert_nil(result.conflicting_observations)
    assert_equal(1, result.groups.length)

    group = result.groups.first
    assert_equal(%w(Europe/Brussels Europe/Paris Europe/Prague), group.identifiers)
    assert_equal(%w(Europe/Brussels Europe/Paris Europe/Prague), group.canonical_identifiers)
    assert_equal([[7200, 'CEST']], group.signature)
    assert_equal({}, group.aliases)
  end

  # Europe/Paris and Europe/Brussels share the same summer and winter
  # offsets today, but followed different rules in 1976 (France observed
  # DST, Belgium did not). Checking the 1976 observation against current
  # offsets would wrongly keep Brussels.
  def test_historical_rules_checked_for_each_observation
    modern = {utc: Time.utc(2004, 7, 1, 12), local: Time.utc(2004, 7, 1, 14)}
    historical = {utc: Time.utc(1976, 7, 1, 12), local: Time.utc(1976, 7, 1, 14)}

    result = @identifier.identify([modern], [@paris, @brussels])
    assert_equal(%w(Europe/Brussels Europe/Paris), result.identifiers)

    result = @identifier.identify([historical], [@paris, @brussels])
    assert(result.unique?)
    assert_equal(%w(Europe/Paris), result.identifiers)

    result = @identifier.identify([modern, historical], [@paris, @brussels])
    assert_equal(%w(Europe/Paris), result.identifiers)
  end

  def test_observation_object_form
    observation = Observation.new(Time.utc(2004, 7, 1, 12), Time.utc(2004, 7, 1, 14), 'CEST')
    result = @identifier.identify([observation], [@paris], abbreviation: :strict)
    assert_equal(%w(Europe/Paris), result.identifiers)
  end

  def test_datetime_and_timestamp_values
    utc = DateTime.new(2004, 7, 1, 12, 0, 0)
    local = DateTime.new(2004, 7, 1, 14, 0, 0)
    result = @identifier.identify([{utc: utc, local: local}], [@paris])
    assert_equal(%w(Europe/Paris), result.identifiers)

    utc = Timestamp.create(2004, 7, 1, 12, 0, 0, 0, :utc)
    local = Timestamp.create(2004, 7, 1, 14, 0, 0)
    result = @identifier.identify([{utc: utc, local: local}], [@paris])
    assert_equal(%w(Europe/Paris), result.identifiers)
  end

  def test_local_time_uses_wall_clock_components
    # The offset attached to the local time value is ignored; only the
    # displayed components are used.
    local = Time.new(2004, 7, 1, 14, 0, 0, '-05:00')
    result = @identifier.identify([{utc: Time.utc(2004, 7, 1, 12), local: local}], [@paris])
    assert_equal(%w(Europe/Paris), result.identifiers)
  end

  def test_tolerance
    observation = {utc: Time.utc(2004, 1, 15, 12, 0, 0), local: Time.utc(2004, 1, 15, 13, 0, 30)}

    result = @identifier.identify([observation], [@paris], tolerance: 29)
    refute(result.matches?)

    result = @identifier.identify([observation], [@paris], tolerance: 30)
    assert_equal(%w(Europe/Paris), result.identifiers)
  end

  def test_per_observation_tolerance_overrides_default
    observations = [
      {utc: Time.utc(2004, 1, 15, 12), local: Time.utc(2004, 1, 15, 13, 0, 30), tolerance: 30},
      {utc: Time.utc(2004, 7, 15, 12), local: Time.utc(2004, 7, 15, 14)}
    ]

    result = @identifier.identify(observations, [@paris], tolerance: 0)
    assert_equal(%w(Europe/Paris), result.identifiers)

    observations[0] = observations[0].merge(tolerance: 29)
    result = @identifier.identify(observations, [@paris], tolerance: 0)
    refute(result.matches?)
  end

  def test_sub_second_tolerance
    observation = {
      utc: Time.utc(2004, 1, 15, 12, 0, 0),
      local: Time.utc(2004, 1, 15, 13, 0, 0) + Rational(1, 2)
    }

    result = @identifier.identify([observation], [@paris], tolerance: Rational(2, 5))
    refute(result.matches?)

    result = @identifier.identify([observation], [@paris], tolerance: Rational(1, 2))
    assert_equal(%w(Europe/Paris), result.identifiers)
  end

  def test_abbreviation_hint_does_not_eliminate
    # London is BST in July, not GMT. As a hint, the mismatch is reported
    # but does not eliminate the candidate.
    observation = {utc: Time.utc(2004, 7, 1, 12), local: Time.utc(2004, 7, 1, 13), abbreviation: 'GMT'}

    result = @identifier.identify([observation], [@london])
    assert_equal(%w(Europe/London), result.identifiers)
    refute(result.groups.first.abbreviation_matched?)
  end

  def test_abbreviation_hint_orders_matching_groups_first
    # Europe/London (GMT) and Etc/UTC (UTC) both observe UTC+0 in January.
    observation = {utc: Time.utc(2004, 1, 15, 12), local: Time.utc(2004, 1, 15, 12), abbreviation: 'GMT'}

    result = @identifier.identify([observation], [@utc, @london])
    assert_equal(2, result.groups.length)
    assert_equal(%w(Europe/London), result.groups[0].identifiers)
    assert(result.groups[0].abbreviation_matched?)
    assert_equal(%w(Etc/UTC), result.groups[1].identifiers)
    refute(result.groups[1].abbreviation_matched?)
  end

  def test_abbreviation_strict_eliminates_mismatches
    observation = {utc: Time.utc(2004, 7, 1, 12), local: Time.utc(2004, 7, 1, 13), abbreviation: 'GMT'}

    result = @identifier.identify([observation], [@london], abbreviation: :strict)
    refute(result.matches?)
    refute_nil(result.conflicting_observations)

    result = @identifier.identify([observation.merge(abbreviation: 'BST')], [@london], abbreviation: :strict)
    assert_equal(%w(Europe/London), result.identifiers)
  end

  def test_abbreviation_strict_ignores_missing_abbreviations
    observation = {utc: Time.utc(2004, 7, 1, 12), local: Time.utc(2004, 7, 1, 13)}
    result = @identifier.identify([observation], [@london], abbreviation: :strict)
    assert_equal(%w(Europe/London), result.identifiers)
  end

  def test_abbreviation_ignore
    observation = {utc: Time.utc(2004, 1, 15, 12), local: Time.utc(2004, 1, 15, 12), abbreviation: 'GMT'}

    result = @identifier.identify([observation], [@utc, @london], abbreviation: :ignore)
    assert_equal(1, result.groups.length)
    assert_equal(%w(Etc/UTC Europe/London), result.groups.first.identifiers)
  end

  def test_aliases_mapped_to_canonical_zone
    jersey = linked_zone('Europe/Jersey', 'Europe/London')
    observation = {utc: Time.utc(2004, 1, 15, 12), local: Time.utc(2004, 1, 15, 12)}

    result = @identifier.identify([observation], [@london, jersey])
    assert_equal(1, result.groups.length)

    group = result.groups.first
    assert_equal(%w(Europe/Jersey Europe/London), group.identifiers)
    assert_equal(%w(Europe/London), group.canonical_identifiers)
    assert_equal({'Europe/Jersey' => 'Europe/London'}, group.aliases)
    assert(result.unique?)
  end

  def test_conflicting_observations_reported_when_no_match
    paris_only = {utc: Time.utc(1976, 7, 1, 12), local: Time.utc(1976, 7, 1, 14)}
    brussels_only = {utc: Time.utc(1976, 7, 1, 12), local: Time.utc(1976, 7, 1, 13)}
    both = {utc: Time.utc(2004, 7, 1, 12), local: Time.utc(2004, 7, 1, 14)}

    result = @identifier.identify([paris_only, brussels_only, both], [@paris, @brussels])
    refute(result.matches?)
    assert_equal([], result.groups)

    conflicts = result.conflicting_observations
    assert_equal(2, conflicts.length)
    assert_equal(paris_only[:utc], conflicts[0].utc)
    assert_equal(brussels_only[:utc], conflicts[1].utc)

    # The reported set is minimal: each observation on its own is
    # satisfiable by one of the candidates.
    conflicts.each do |observation|
      assert(@identifier.identify([observation], [@paris, @brussels]).matches?)
    end
  end

  def test_conflicting_observations_with_strict_abbreviation
    observation = {utc: Time.utc(2004, 7, 1, 12), local: Time.utc(2004, 7, 1, 13), abbreviation: 'GMT'}
    result = @identifier.identify([observation], [@london], abbreviation: :strict)
    assert_equal(1, result.conflicting_observations.length)
  end

  def test_result_helpers
    jersey = linked_zone('Europe/Jersey', 'Europe/London')
    observation = {utc: Time.utc(2004, 1, 15, 12), local: Time.utc(2004, 1, 15, 12)}

    result = @identifier.identify([observation], [@london, jersey, @paris])
    # Paris observes CET (UTC+1) in January and does not match.
    assert_equal(%w(Europe/Jersey Europe/London), result.identifiers.sort)
    assert_equal(%w(Europe/London), result.canonical_identifiers)
    assert_equal(1, result.groups.length)
    assert_equal(result.groups, result.to_a)
  end

  def test_duplicate_candidates_are_deduplicated
    observation = {utc: Time.utc(2004, 1, 15, 12), local: Time.utc(2004, 1, 15, 13)}
    result = @identifier.identify([observation], [@paris, @paris])
    assert_equal(%w(Europe/Paris), result.identifiers)
  end

  def test_invalid_arguments
    observation = {utc: Time.utc(2004, 1, 15, 12), local: Time.utc(2004, 1, 15, 13)}

    assert_raises(ArgumentError) { @identifier.identify([], [@paris]) }
    assert_raises(ArgumentError) { @identifier.identify([observation], []) }
    assert_raises(ArgumentError) { @identifier.identify([observation], [@paris], abbreviation: :invalid) }
    assert_raises(ArgumentError) { @identifier.identify([observation], [@paris], tolerance: -1) }
    assert_raises(ArgumentError) { @identifier.identify([observation], [@paris], unknown: true) }
    assert_raises(ArgumentError) { @identifier.identify([{utc: Time.utc(2004, 1, 15, 12)}], [@paris]) }
    assert_raises(ArgumentError) { @identifier.identify([observation.merge(extra: 1)], [@paris]) }
    assert_raises(ArgumentError) { Observation.new(nil, nil) }
    assert_raises(ArgumentError) { Observation.new(Time.utc(2004, 1, 15, 12), Time.utc(2004, 1, 15, 13), nil, -1) }
  end
end
