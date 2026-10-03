# encoding: UTF-8
# frozen_string_literal: true

require_relative 'test_utils'

class TCDataSourceComparer < Minitest::Test
  include TZInfo

  # A DataSource that serves a fixed set of TimezoneInfo instances, used to
  # simulate two different releases of time zone data.
  class FixtureDataSource < DataSource
    def initialize(infos)
      super()
      @infos = infos
    end

    def to_s
      'Fixture DataSource'
    end

    protected

   def load_timezone_info(identifier)
     info = identifier && @infos[identifier]
      raise TZInfo::InvalidTimezoneIdentifier, "Invalid identifier: #{identifier.nil? ? 'nil' : identifier}" unless info
     info
   end

    def data_timezone_identifiers
      identifiers_of_kind(DataSources::DataTimezoneInfo)
    end

    def linked_timezone_identifiers
      identifiers_of_kind(DataSources::LinkedTimezoneInfo)
    end

    private

    def identifiers_of_kind(kind)
      @infos.values.select {|info| info.kind_of?(kind) }.map {|info| info.identifier }.sort.freeze
    end
  end

  FROM = Time.utc(2026, 1, 1)
  TO = Time.utc(2027, 1, 1)

  def setup
    est = tz_offset(-18000, 0, 'EST')
    edt = tz_offset(-18000, 3600, 'EDT')
    xst = tz_offset(-18000, 0, 'XST')
    xdt = tz_offset(-18000, 3600, 'XDT')
    fixed = tz_offset(3600, 0, 'FIX')

    old_spring = transition(edt, est, 2026, 3, 8, 7)
    old_fall = transition(est, edt, 2026, 11, 1, 6)
    new_spring = transition(edt, est, 2026, 3, 15, 7)
    new_fall = transition(est, edt, 2026, 11, 8, 6)

    @old_source = FixtureDataSource.new(
      'Test/MovedDates' => transitions_info('Test/MovedDates', [old_spring, old_fall]),
      'Test/RenamedAbbreviation' => transitions_info('Test/RenamedAbbreviation', [old_spring, old_fall]),
      'Test/Fixed' => DataSources::ConstantOffsetDataTimezoneInfo.new('Test/Fixed', fixed),
      'Test/Alias' => DataSources::LinkedTimezoneInfo.new('Test/Alias', 'Test/MovedDates'),
      'Test/Split' => transitions_info('Test/Split', [old_spring]),
      'Test/Circular' => DataSources::LinkedTimezoneInfo.new('Test/Circular', 'Test/Circular')
    )

    @new_source = FixtureDataSource.new(
      'Test/MovedDates' => transitions_info('Test/MovedDates', [new_spring, new_fall]),
      'Test/RenamedAbbreviation' => transitions_info('Test/RenamedAbbreviation', [
        transition(xdt, xst, 2026, 3, 8, 7),
        transition(xst, xdt, 2026, 11, 1, 6)
      ]),
      'Test/Fixed' => DataSources::ConstantOffsetDataTimezoneInfo.new('Test/Fixed', fixed),
      'Test/Alias' => transitions_info('Test/Alias', [old_spring, old_fall]),
      'Test/Split' => transitions_info('Test/Split', [
        transition(xdt, est, 2026, 3, 15, 7),
        transition(edt, xdt, 2026, 3, 22, 7)
      ])
    )

    @comparer = DataSourceComparer.new(@old_source, @new_source)
  end

  def tz_offset(base_utc_offset, std_offset, abbreviation)
    TimezoneOffset.new(base_utc_offset, std_offset, abbreviation)
  end

  def transition(offset, previous_offset, year, month, day, hour)
    TimezoneTransition.new(offset, previous_offset, Time.utc(year, month, day, hour).to_i)
  end

  def transitions_info(identifier, transitions)
    DataSources::TransitionsDataTimezoneInfo.new(identifier, transitions)
  end

  def utc_ts(year, month, day, hour = 0, min = 0)
    Timestamp.utc(Time.utc(year, month, day, hour, min).to_i)
  end

 def local_ts(year, month, day, hour = 0, min = 0)
    Timestamp.for(Timestamp.utc(Time.utc(year, month, day, hour, min).to_i), :ignore)
 end

  def test_initialization_requires_data_sources
    assert_raises(ArgumentError) { DataSourceComparer.new(:invalid, @new_source) }
    assert_raises(ArgumentError) { DataSourceComparer.new(@old_source, :invalid) }
  end

  def test_compare_requires_arguments
    assert_raises(ArgumentError) { @comparer.compare(nil, FROM, TO) }
    assert_raises(ArgumentError) { @comparer.compare('Test/Fixed', nil, TO) }
    assert_raises(ArgumentError) { @comparer.compare('Test/Fixed', FROM, nil) }
    assert_raises(ArgumentError) { @comparer.compare('Test/Fixed', TO, FROM) }
    assert_raises(ArgumentError) { @comparer.compare('Test/Fixed', FROM, FROM) }
  end

  def test_compare_with_invalid_identifier
    assert_raises(InvalidTimezoneIdentifier) { @comparer.compare('Test/Unknown', FROM, TO) }
  end

  def test_compare_with_circular_link
    assert_raises(InvalidTimezoneIdentifier) { @comparer.compare('Test/Circular', FROM, TO) }
  end

  def test_moved_transition_dates_utc_differences
    comparison = @comparer.compare('Test/MovedDates', FROM, TO)

    assert_equal('Test/MovedDates', comparison.identifier)
    assert_equal(utc_ts(2026, 1, 1), comparison.from)
    assert_equal(utc_ts(2027, 1, 1), comparison.to)
    refute(comparison.identical?)
    refute(comparison.renamed?)
    refute(comparison.rename_only?)

    differences = comparison.utc_differences
    assert_equal(2, differences.length)

    spring = differences[0]
    assert_equal(utc_ts(2026, 3, 8, 7), spring.starts_at)
    assert_equal(utc_ts(2026, 3, 15, 7), spring.ends_at)
   assert(spring.offset_changed?)
   assert(spring.dst_changed?)
    assert(spring.abbreviation_changed?)
    assert_equal(1, spring.segments.length)

    segment = spring.segments[0]
    assert_equal(spring.starts_at, segment.starts_at)
    assert_equal(spring.ends_at, segment.ends_at)
    assert_equal(-14400, segment.first_period.observed_utc_offset)
    assert(segment.first_period.dst?)
    assert_equal('EDT', segment.first_period.abbreviation)
    assert_equal(-18000, segment.second_period.observed_utc_offset)
    refute(segment.second_period.dst?)
    assert_equal('EST', segment.second_period.abbreviation)

    fall = differences[1]
    assert_equal(utc_ts(2026, 11, 1, 6), fall.starts_at)
    assert_equal(utc_ts(2026, 11, 8, 6), fall.ends_at)
   assert(fall.offset_changed?)
   assert(fall.dst_changed?)
    assert(fall.abbreviation_changed?)
    assert_equal(-18000, fall.segments[0].first_period.observed_utc_offset)
    assert_equal(-14400, fall.segments[0].second_period.observed_utc_offset)
  end

  def test_moved_transition_dates_local_time_changes
    comparison = @comparer.compare('Test/MovedDates', FROM, TO)

    changes = comparison.local_time_changes
    assert_equal(4, changes.length)

    added = changes[0]
    assert_equal(local_ts(2026, 3, 8, 2), added.local_starts_at)
    assert_equal(local_ts(2026, 3, 8, 3), added.local_ends_at)
    assert_equal(0, added.first_multiplicity)
    assert_equal(1, added.second_multiplicity)
    assert_equal(:added, added.kind)
    assert(added.added?)
    refute(added.removed?)
    refute(added.multiplicity_changed?)

    removed = changes[1]
    assert_equal(local_ts(2026, 3, 15, 2), removed.local_starts_at)
    assert_equal(local_ts(2026, 3, 15, 3), removed.local_ends_at)
    assert_equal(1, removed.first_multiplicity)
    assert_equal(0, removed.second_multiplicity)
    assert_equal(:removed, removed.kind)
    assert(removed.removed?)

    first_overlap = changes[2]
    assert_equal(local_ts(2026, 11, 1, 1), first_overlap.local_starts_at)
    assert_equal(local_ts(2026, 11, 1, 2), first_overlap.local_ends_at)
    assert_equal(2, first_overlap.first_multiplicity)
    assert_equal(1, first_overlap.second_multiplicity)
    assert_equal(:multiplicity_changed, first_overlap.kind)
    assert(first_overlap.multiplicity_changed?)

    second_overlap = changes[3]
    assert_equal(local_ts(2026, 11, 8, 1), second_overlap.local_starts_at)
    assert_equal(local_ts(2026, 11, 8, 2), second_overlap.local_ends_at)
    assert_equal(1, second_overlap.first_multiplicity)
    assert_equal(2, second_overlap.second_multiplicity)
    assert_equal(:multiplicity_changed, second_overlap.kind)
  end

  def test_continuous_change_is_coalesced_into_a_single_difference
    comparison = @comparer.compare('Test/Split', Time.utc(2026, 1, 1), Time.utc(2026, 6, 1))

    differences = comparison.utc_differences
    assert_equal(1, differences.length)

    difference = differences[0]
    assert_equal(utc_ts(2026, 3, 8, 7), difference.starts_at)
    assert_equal(utc_ts(2026, 3, 22, 7), difference.ends_at)
    assert(difference.offset_changed?)
    assert(difference.dst_changed?)
    assert(difference.abbreviation_changed?)

    segments = difference.segments
    assert_equal(2, segments.length)
    assert_equal(utc_ts(2026, 3, 8, 7), segments[0].starts_at)
    assert_equal(utc_ts(2026, 3, 15, 7), segments[0].ends_at)
    assert_equal('EDT', segments[0].first_period.abbreviation)
    assert_equal('EST', segments[0].second_period.abbreviation)
    assert_equal(utc_ts(2026, 3, 15, 7), segments[1].starts_at)
    assert_equal(utc_ts(2026, 3, 22, 7), segments[1].ends_at)
    assert_equal('EDT', segments[1].first_period.abbreviation)
    assert_equal('XDT', segments[1].second_period.abbreviation)

    changes = comparison.local_time_changes
    assert_equal(2, changes.length)
    assert(changes[0].added?)
    assert_equal(local_ts(2026, 3, 8, 2), changes[0].local_starts_at)
    assert(changes[1].removed?)
    assert_equal(local_ts(2026, 3, 15, 2), changes[1].local_starts_at)
  end

  def test_abbreviation_only_change
    comparison = @comparer.compare('Test/RenamedAbbreviation', FROM, TO)

    refute(comparison.identical?)
    refute(comparison.renamed?)
    refute(comparison.rename_only?)
    assert_empty(comparison.local_time_changes)

    differences = comparison.utc_differences
    assert_equal(1, differences.length)

    difference = differences[0]
    assert_equal(utc_ts(2026, 1, 1), difference.starts_at)
    assert_equal(utc_ts(2027, 1, 1), difference.ends_at)
    refute(difference.offset_changed?)
    refute(difference.dst_changed?)
    assert(difference.abbreviation_changed?)
    assert_equal(3, difference.segments.length)
    assert_equal('EST', difference.segments[0].first_period.abbreviation)
    assert_equal('XST', difference.segments[0].second_period.abbreviation)
  end

  def test_fixed_offset_zone_is_identical
    comparison = @comparer.compare('Test/Fixed', FROM, TO)

    assert(comparison.identical?)
    refute(comparison.renamed?)
    refute(comparison.rename_only?)
    assert_empty(comparison.utc_differences)
    assert_empty(comparison.local_time_changes)
  end

  def test_compare_accepts_timestamps
    comparison = @comparer.compare('Test/Fixed', utc_ts(2026, 1, 1), utc_ts(2027, 1, 1))

    assert(comparison.identical?)
    assert_equal(utc_ts(2026, 1, 1), comparison.from)
    assert_equal(utc_ts(2027, 1, 1), comparison.to)
  end

  def test_alias_rename_with_identical_behavior
    comparison = @comparer.compare('Test/Alias', FROM, TO)

    assert(comparison.renamed?)
    assert_equal('Test/MovedDates', comparison.first_canonical_identifier)
    assert_equal('Test/Alias', comparison.second_canonical_identifier)
    assert(comparison.identical?)
    assert(comparison.rename_only?)
    assert_empty(comparison.utc_differences)
    assert_empty(comparison.local_time_changes)
  end

  def test_boundaries_can_be_verified_against_both_sources
    comparison = @comparer.compare('Test/MovedDates', FROM, TO)

    comparison.utc_differences.each do |difference|
      first_period = comparison.first_timezone.period_for_utc(difference.starts_at)
      second_period = comparison.second_timezone.period_for_utc(difference.starts_at)
      refute_equal(
        [first_period.observed_utc_offset, first_period.dst?, first_period.abbreviation],
        [second_period.observed_utc_offset, second_period.dst?, second_period.abbreviation])

      # Each difference ends where the two sources observe the same offset
      # again.
      first_period = comparison.first_timezone.period_for_utc(difference.ends_at)
      second_period = comparison.second_timezone.period_for_utc(difference.ends_at)
      assert_equal(
        [first_period.observed_utc_offset, first_period.dst?, first_period.abbreviation],
        [second_period.observed_utc_offset, second_period.dst?, second_period.abbreviation])
    end

    comparison.local_time_changes.each do |change|
      assert_equal(change.first_multiplicity,
        comparison.first_timezone.periods_for_local(change.local_starts_at).length)
      assert_equal(change.second_multiplicity,
        comparison.second_timezone.periods_for_local(change.local_starts_at).length)
    end
  end

  def test_compare_does_not_change_global_data_source_or_existing_timezones
    global_before = DataSource.get

    timezone = @old_source.get_timezone_info('Test/MovedDates').create_timezone
    period_before = timezone.period_for_utc(Time.utc(2026, 3, 10))

    @comparer.compare('Test/MovedDates', FROM, TO)

    assert_same(global_before, DataSource.get)

    period_after = timezone.period_for_utc(Time.utc(2026, 3, 10))
    assert_equal(period_before.observed_utc_offset, period_after.observed_utc_offset)
    assert_equal(period_before.abbreviation, period_after.abbreviation)
    assert_equal(-14400, period_after.observed_utc_offset)
  end
end
