# encoding: UTF-8
# frozen_string_literal: true

require_relative 'test_utils'

class TCDataSourceComparator < Minitest::Test
  include TZInfo

  class ArtificialDataSource < DataSource
    include TZInfo

    def initialize(data_infos, links = {})
      super()
      @data_infos = data_infos
      @links = links
    end

    def data_timezone_identifiers
      @data_infos.keys.sort.freeze
    end

    def linked_timezone_identifiers
      @links.keys.sort.freeze
    end

    protected

    def load_timezone_info(identifier)
      info = @data_infos[identifier]
      return info if info

      target = @links[identifier]
      return DataSources::LinkedTimezoneInfo.new(identifier, target) if target

      raise InvalidTimezoneIdentifier, "Invalid identifier: " + identifier
    end
  end

  def setup
    est = offset(-18000, 0, "EST")
    edt = offset(-18000, 3600, "EDT")
    xst = offset(-18000, 0, "XST")
    xdt = offset(-18000, 3600, "XDT")

    # The old source springs forward on 2025-03-09 and falls back on
    # 2025-11-02. The new source moves both transition dates.
    old_zone = DataSources::TransitionsDataTimezoneInfo.new("Test/Zone", [
      transition(edt, est, 2025, 3, 9, 7),
      transition(est, edt, 2025, 11, 2, 6)
    ])

    new_zone = DataSources::TransitionsDataTimezoneInfo.new("Test/Zone", [
      transition(edt, est, 2025, 3, 2, 7),
      transition(est, edt, 2025, 10, 26, 6)
    ])

    # Both sources transition at the same instants for Test/Abbr. Only the
    # abbreviations differ.
    old_abbr = DataSources::TransitionsDataTimezoneInfo.new("Test/Abbr", [
      transition(edt, est, 2025, 3, 9, 7),
      transition(est, edt, 2025, 11, 2, 6)
    ])

    new_abbr = DataSources::TransitionsDataTimezoneInfo.new("Test/Abbr", [
      transition(xdt, xst, 2025, 3, 9, 7),
      transition(xst, xdt, 2025, 11, 2, 6)
    ])

    # A zone in the new source with a different name but behaviour identical
    # to the old Test/Zone. Test/Alias links to Test/Zone in the old source
    # and to Test/Renamed in the new source.
    renamed_zone = DataSources::TransitionsDataTimezoneInfo.new("Test/Renamed", [
      transition(edt, est, 2025, 3, 9, 7),
      transition(est, edt, 2025, 11, 2, 6)
    ])

    fixed = offset(3600, 0, "FIX")
    old_fixed = DataSources::ConstantOffsetDataTimezoneInfo.new("Test/Fixed", fixed)
    new_fixed = DataSources::ConstantOffsetDataTimezoneInfo.new("Test/Fixed", fixed)

    @old_source = ArtificialDataSource.new(
      {"Test/Zone" => old_zone, "Test/Abbr" => old_abbr, "Test/Fixed" => old_fixed},
      {"Test/Alias" => "Test/Zone"})

    @new_source = ArtificialDataSource.new(
      {"Test/Zone" => new_zone, "Test/Abbr" => new_abbr, "Test/Fixed" => new_fixed, "Test/Renamed" => renamed_zone},
      {"Test/Alias" => "Test/Renamed"})

    @comparator = DataSourceComparator.new(@old_source, @new_source)
  end

  def offset(base_utc_offset, std_offset, abbreviation)
    TimezoneOffset.new(base_utc_offset, std_offset, abbreviation)
  end

  def transition(to_offset, previous_offset, year, month, day, hour)
    TimezoneTransition.new(to_offset, previous_offset, Time.utc(year, month, day, hour).to_i)
  end

  def local_timestamp(year, month, day, hour)
    Timestamp.new(Time.utc(year, month, day, hour).to_i)
  end

  def assert_periods_equivalent(old_period, new_period)
    assert_equal(old_period.observed_utc_offset, new_period.observed_utc_offset)
    assert_equal(old_period.dst?, new_period.dst?)
    assert_equal(old_period.abbreviation, new_period.abbreviation)
  end

  def refute_periods_equivalent(old_period, new_period)
    refute(
      old_period.observed_utc_offset == new_period.observed_utc_offset &&
      old_period.dst? == new_period.dst? &&
      old_period.abbreviation == new_period.abbreviation)
  end

  def test_compare_returns_minimal_intervals_for_transition_date_changes
    comparison = @comparator.compare("Test/Zone", Time.utc(2025, 1, 1), Time.utc(2026, 1, 1))

    assert_equal("Test/Zone", comparison.identifier)
    assert(comparison.clock_changes?)
    refute(comparison.link_difference?)
    refute(comparison.identical?)

    intervals = comparison.intervals
    assert_equal(2, intervals.length)

    first = intervals[0]
    assert_equal(Timestamp.utc(Time.utc(2025, 3, 2, 7).to_i), first.starts_at)
    assert_equal(Timestamp.utc(Time.utc(2025, 3, 9, 7).to_i), first.ends_at)
    assert_equal([:offset, :dst, :abbreviation], first.differences)
    assert(first.offset_difference?)
    assert(first.dst_difference?)
    assert(first.abbreviation_difference?)

    second = intervals[1]
    assert_equal(Timestamp.utc(Time.utc(2025, 10, 26, 6).to_i), second.starts_at)
    assert_equal(Timestamp.utc(Time.utc(2025, 11, 2, 6).to_i), second.ends_at)
    assert_equal([:offset, :dst, :abbreviation], second.differences)

    segment = first.segments.first
    assert_equal("EST", segment.old_period.abbreviation)
    assert_equal("EDT", segment.new_period.abbreviation)
    assert(segment.different?)
    assert(segment.offset_difference?)
    assert(segment.dst_difference?)
    assert(segment.abbreviation_difference?)
  end

  def test_compare_merges_contiguous_abbreviation_differences
    comparison = @comparator.compare("Test/Abbr", Time.utc(2025, 1, 1), Time.utc(2026, 1, 1))

    intervals = comparison.intervals
    assert_equal(1, intervals.length)

    interval = intervals.first
    assert_equal(Timestamp.utc(Time.utc(2025, 1, 1).to_i), interval.starts_at)
    assert_equal(Timestamp.utc(Time.utc(2026, 1, 1).to_i), interval.ends_at)
    assert_equal([:abbreviation], interval.differences)

    # The transitions within the window split the difference into atomic
    # segments, but they are reported as a single continuous interval.
    assert_equal(3, interval.segments.length)
    assert(interval.segments.all? {|s| s.differences == [:abbreviation] })

    assert_equal([], comparison.local_time_changes)
  end

  def test_compare_reports_added_removed_and_multiplicity_changed_local_times
    comparison = @comparator.compare("Test/Zone", Time.utc(2025, 1, 1), Time.utc(2026, 1, 1))

    changes = comparison.local_time_changes
    assert_equal(4, changes.length)

    # The new source skips 2025-03-02 02:00 to 03:00, which exists in the
    # old source.
    removed = changes[0]
    assert_equal(:removed, removed.kind)
    assert(removed.removed?)
    assert_equal(local_timestamp(2025, 3, 2, 2), removed.local_starts_at)
    assert_equal(local_timestamp(2025, 3, 2, 3), removed.local_ends_at)
    assert_equal(1, removed.old_count)
    assert_equal(0, removed.new_count)

    # The old source skips 2025-03-09 02:00 to 03:00, which exists in the
    # new source.
    added = changes[1]
    assert_equal(:added, added.kind)
    assert(added.added?)
    assert_equal(local_timestamp(2025, 3, 9, 2), added.local_starts_at)
    assert_equal(local_timestamp(2025, 3, 9, 3), added.local_ends_at)
    assert_equal(0, added.old_count)
    assert_equal(1, added.new_count)

    # 2025-10-26 01:00 to 02:00 is ambiguous in the new source only.
    first_change = changes[2]
    assert_equal(:multiplicity_changed, first_change.kind)
    assert(first_change.multiplicity_changed?)
    assert_equal(local_timestamp(2025, 10, 26, 1), first_change.local_starts_at)
    assert_equal(local_timestamp(2025, 10, 26, 2), first_change.local_ends_at)
    assert_equal(1, first_change.old_count)
    assert_equal(2, first_change.new_count)

    # 2025-11-02 01:00 to 02:00 is ambiguous in the old source only.
    second_change = changes[3]
    assert_equal(:multiplicity_changed, second_change.kind)
    assert_equal(local_timestamp(2025, 11, 2, 1), second_change.local_starts_at)
    assert_equal(local_timestamp(2025, 11, 2, 2), second_change.local_ends_at)
    assert_equal(2, second_change.old_count)
    assert_equal(1, second_change.new_count)
  end

  def test_compare_fixed_offset_zone_is_identical
    comparison = @comparator.compare("Test/Fixed", Time.utc(2025, 1, 1), Time.utc(2026, 1, 1))

    assert(comparison.identical?)
    refute(comparison.clock_changes?)
    refute(comparison.link_difference?)
    assert_equal([], comparison.intervals)
    assert_equal([], comparison.local_time_changes)
    assert_equal(1, comparison.segments.length)
    refute(comparison.segments.first.different?)
  end

  def test_compare_distinguishes_link_rename_from_clock_changes
    comparison = @comparator.compare("Test/Alias", Time.utc(2025, 1, 1), Time.utc(2026, 1, 1))

    refute(comparison.clock_changes?)
    assert(comparison.link_difference?)
    assert(comparison.link_only_change?)
    refute(comparison.identical?)
    assert(comparison.old_linked?)
    assert(comparison.new_linked?)
    assert_equal("Test/Zone", comparison.old_canonical_identifier)
    assert_equal("Test/Renamed", comparison.new_canonical_identifier)
    assert_equal([], comparison.intervals)
    assert_equal([], comparison.local_time_changes)
  end

  def test_interval_boundaries_can_be_verified_against_both_sources
    comparison = @comparator.compare("Test/Zone", Time.utc(2025, 1, 1), Time.utc(2026, 1, 1))
    old_timezone = @old_source.get_timezone_info("Test/Zone").create_timezone
    new_timezone = @new_source.get_timezone_info("Test/Zone").create_timezone

    comparison.intervals.each do |interval|
      # Immediately before the interval the sources agree.
      before_start = Timestamp.utc(interval.starts_at.value - 1)
      assert_periods_equivalent(old_timezone.period_for(before_start), new_timezone.period_for(before_start))

      # At the start of the interval the sources differ.
      refute_periods_equivalent(old_timezone.period_for(interval.starts_at), new_timezone.period_for(interval.starts_at))

      # Immediately before the end of the interval the sources differ.
      before_end = Timestamp.utc(interval.ends_at.value - 1)
      refute_periods_equivalent(old_timezone.period_for(before_end), new_timezone.period_for(before_end))

      # At the end of the interval the sources agree.
      assert_periods_equivalent(old_timezone.period_for(interval.ends_at), new_timezone.period_for(interval.ends_at))
    end
  end

  def test_local_time_change_boundaries_can_be_verified_against_both_sources
    comparison = @comparator.compare("Test/Zone", Time.utc(2025, 1, 1), Time.utc(2026, 1, 1))
    old_timezone = @old_source.get_timezone_info("Test/Zone").create_timezone
    new_timezone = @new_source.get_timezone_info("Test/Zone").create_timezone

    comparison.local_time_changes.each do |change|
      local = Timestamp.new(change.local_starts_at.value)
      assert_equal(change.old_count, old_timezone.periods_for_local(local).length)
      assert_equal(change.new_count, new_timezone.periods_for_local(local).length)
    end
  end

  def test_compare_does_not_change_global_data_source_or_existing_timezones
    global_source = DataSource.get
    timezone = Timezone.get("Europe/London")
    time = Time.utc(2025, 6, 1)
    period_before = timezone.period_for_utc(time)

    comparison = @comparator.compare("Test/Zone", Time.utc(2025, 1, 1), Time.utc(2026, 1, 1))
    assert(comparison.clock_changes?)

    assert_same(global_source, DataSource.get)

    period_after = timezone.period_for_utc(time)
    assert_equal(period_before.observed_utc_offset, period_after.observed_utc_offset)
    assert_equal(period_before.dst?, period_after.dst?)
    assert_equal(period_before.abbreviation, period_after.abbreviation)
  end

  def test_compare_accepts_timestamp_window
    comparison = @comparator.compare("Test/Zone",
      Timestamp.utc(Time.utc(2025, 1, 1).to_i),
      Timestamp.utc(Time.utc(2026, 1, 1).to_i))

    assert_equal(2, comparison.intervals.length)
    assert_equal(Timestamp.utc(Time.utc(2025, 1, 1).to_i), comparison.from)
    assert_equal(Timestamp.utc(Time.utc(2026, 1, 1).to_i), comparison.to)
  end

  def test_compare_restricts_results_to_the_window
    comparison = @comparator.compare("Test/Zone", Time.utc(2025, 6, 1), Time.utc(2025, 9, 1))

    assert(comparison.identical?)
    assert_equal([], comparison.intervals)
    assert_equal([], comparison.local_time_changes)
  end

  def test_compare_requires_to_after_from
    error = assert_raises(ArgumentError) do
      @comparator.compare("Test/Zone", Time.utc(2026, 1, 1), Time.utc(2025, 1, 1))
    end
    assert_equal("to must be greater than from", error.message)
  end

  def test_compare_requires_window_bounds_with_offsets
    error = assert_raises(ArgumentError) do
      @comparator.compare("Test/Zone", Timestamp.new(0), Time.utc(2026, 1, 1))
    end
    assert_equal("from must have a specified utc_offset", error.message)

    error = assert_raises(ArgumentError) do
      @comparator.compare("Test/Zone", Time.utc(2025, 1, 1), nil)
    end
    assert_equal("to must be specified", error.message)
  end

  def test_compare_requires_valid_identifier_in_both_sources
    assert_raises(InvalidTimezoneIdentifier) do
      @comparator.compare("Test/Unknown", Time.utc(2025, 1, 1), Time.utc(2026, 1, 1))
    end
  end

  def test_initialize_requires_data_sources
    error = assert_raises(ArgumentError) { DataSourceComparator.new(:ruby, @new_source) }
    assert_equal("old_source must be a DataSource", error.message)

    error = assert_raises(ArgumentError) { DataSourceComparator.new(@old_source, nil) }
    assert_equal("new_source must be a DataSource", error.message)
  end
end
