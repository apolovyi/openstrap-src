import copy
import csv
import io
import json
import tempfile
import unittest
from pathlib import Path
from zoneinfo import ZoneInfo

from tool.whoop_v2_to_edge import (
    ConversionError,
    DAY_HEADERS,
    WORKOUT_HEADERS,
    build_day_row,
    build_day_rows,
    build_workout_rows,
    convert_export,
    index_export,
    render_csv,
    select_primary_sleep,
    validate_export,
)


def fixture():
    return {
        "cycles": [
            {
                "id": 1,
                "start": "2024-01-02T00:00:00Z",
                "score": {"strain": 8.5, "kilojoule": 4184},
            }
        ],
        "recoveries": [
            {
                "cycle_id": 1,
                "sleep_id": 10,
                "score": {
                    "recovery_score": 72,
                    "resting_heart_rate": 51,
                    "hrv_rmssd_milli": 55.5,
                    "spo2_percentage": 97.5,
                    "skin_temp_celsius": 33.2,
                },
            }
        ],
        "sleeps": [
            {
                "id": 10,
                "cycle_id": 1,
                "start": "2024-01-02T01:00:00Z",
                "end": "2024-01-02T08:00:00Z",
                "nap": False,
                "score": {
                    "respiratory_rate": 14.2,
                    "sleep_efficiency_percentage": 91,
                    "sleep_performance_percentage": 88,
                    "stage_summary": {
                        "total_in_bed_time_milli": 4_200_000,
                        "total_light_sleep_time_milli": 600_000,
                        "total_slow_wave_sleep_time_milli": 1_200_000,
                        "total_rem_sleep_time_milli": 1_800_000,
                        "total_awake_time_milli": 600_000,
                    },
                },
            }
        ],
        "workouts": [
            {
                "id": 20,
                "start": "2024-01-02T12:00:00Z",
                "end": "2024-01-02T13:00:00Z",
                "sport_name": "Run, fast",
                "score": {"strain": 10.5, "kilojoule": 900, "max_heart_rate": 180},
            }
        ],
    }


class ValidationTests(unittest.TestCase):
    def test_complete_fixture_inventory(self):
        inventory = validate_export(fixture())
        self.assertEqual(
            (inventory.cycles, inventory.recoveries, inventory.sleeps, inventory.workouts),
            (1, 1, 1, 1),
        )

    def test_missing_collection_is_rejected(self):
        data = fixture()
        del data["sleeps"]
        with self.assertRaisesRegex(ConversionError, "sleeps must be a list"):
            validate_export(data)

    def test_duplicate_ids_are_rejected(self):
        data = fixture()
        data["cycles"].append(copy.deepcopy(data["cycles"][0]))
        with self.assertRaisesRegex(ConversionError, "duplicate cycles.id"):
            validate_export(data)

    def test_orphan_recovery_sleep_and_sleep_link_are_rejected(self):
        data = fixture()
        data["recoveries"][0]["cycle_id"] = 999
        with self.assertRaisesRegex(ConversionError, "missing cycle 999"):
            validate_export(data)

        data = fixture()
        data["sleeps"][0]["cycle_id"] = 999
        with self.assertRaisesRegex(ConversionError, "missing cycle 999"):
            validate_export(data)

        data = fixture()
        data["recoveries"][0]["sleep_id"] = 999
        with self.assertRaisesRegex(ConversionError, "missing sleep 999"):
            validate_export(data)

    def test_naive_timestamps_are_rejected(self):
        data = fixture()
        data["cycles"][0]["start"] = "2024-01-02T00:00:00"
        with self.assertRaisesRegex(ConversionError, "timezone offset"):
            validate_export(data)


class SleepSelectionTests(unittest.TestCase):
    def test_recovery_link_wins_over_longer_sleep(self):
        data = fixture()
        longer = copy.deepcopy(data["sleeps"][0])
        longer["id"] = 11
        longer["start"] = "2024-01-02T09:00:00Z"
        longer["end"] = "2024-01-02T18:00:00Z"
        longer["score"]["stage_summary"]["total_in_bed_time_milli"] = 9_000_000
        data["sleeps"].append(longer)
        validate_export(data)
        selected = select_primary_sleep(
            data["cycles"][0], data["recoveries"][0], index_export(data)
        )
        self.assertEqual(selected["id"], 10)

    def test_fallback_ignores_naps_and_picks_longest_main_sleep(self):
        data = fixture()
        data["recoveries"] = []
        shorter = data["sleeps"][0]
        longer = copy.deepcopy(shorter)
        longer["id"] = 11
        longer["score"]["stage_summary"]["total_in_bed_time_milli"] = 8_000_000
        nap = copy.deepcopy(longer)
        nap["id"] = 12
        nap["nap"] = True
        nap["score"]["stage_summary"]["total_in_bed_time_milli"] = 12_000_000
        data["sleeps"].extend([longer, nap])
        validate_export(data)
        selected = select_primary_sleep(data["cycles"][0], None, index_export(data))
        self.assertEqual(selected["id"], 11)

    def test_nap_only_cycle_has_no_primary_daily_sleep(self):
        data = fixture()
        data["recoveries"] = []
        data["sleeps"][0]["nap"] = True
        validate_export(data)
        selected = select_primary_sleep(data["cycles"][0], None, index_export(data))
        self.assertIsNone(selected)


class ProjectionTests(unittest.TestCase):
    def test_units_and_sleep_stage_sum_are_preserved(self):
        data = fixture()
        row = build_day_row(
            data["cycles"][0], data["recoveries"][0], data["sleeps"][0]
        )
        self.assertEqual(row["Heart rate variability (ms)"], 55.5)
        self.assertEqual(row["Energy burned (kJ)"], 4184)
        self.assertEqual(row["Asleep duration (min)"], 60)
        self.assertEqual(row["In bed duration (min)"], 70)
        self.assertEqual(row["Sleep efficiency %"], 91)
        self.assertEqual(row["Sleep performance %"], 88)

    def test_partial_stage_data_does_not_fabricate_total_sleep(self):
        data = fixture()
        del data["sleeps"][0]["score"]["stage_summary"][
            "total_rem_sleep_time_milli"
        ]
        row = build_day_row(
            data["cycles"][0], data["recoveries"][0], data["sleeps"][0]
        )
        self.assertIsNone(row["Asleep duration (min)"])
        self.assertEqual(row["Light sleep duration (min)"], 10)

    def test_nonfinite_metrics_and_negative_durations_are_rejected(self):
        data = fixture()
        data["cycles"][0]["score"]["strain"] = float("inf")
        with self.assertRaisesRegex(ConversionError, "must be finite"):
            build_day_row(
                data["cycles"][0], data["recoveries"][0], data["sleeps"][0]
            )

        data = fixture()
        data["sleeps"][0]["score"]["stage_summary"][
            "total_light_sleep_time_milli"
        ] = -1
        with self.assertRaisesRegex(ConversionError, "must not be negative"):
            build_day_row(
                data["cycles"][0], data["recoveries"][0], data["sleeps"][0]
            )

    def test_unscored_records_and_missing_sport_remain_blank(self):
        data = fixture()
        data["workouts"][0]["score"] = None
        data["workouts"][0]["sport_name"] = None
        row = build_workout_rows(data)[0]
        self.assertIsNone(row["Activity name"])
        self.assertIsNone(row["Activity Strain"])
        self.assertIsNone(row["Energy burned (kJ)"])
        self.assertIsNone(row["Max HR (bpm)"])

    def test_csv_writer_quotes_activity_names(self):
        content = render_csv(WORKOUT_HEADERS, build_workout_rows(fixture()))
        parsed = list(csv.DictReader(io.StringIO(content)))
        self.assertEqual(parsed[0]["Activity name"], "Run, fast")
        self.assertIn('"Run, fast"', content)


class DayResolutionTests(unittest.TestCase):
    def test_more_complete_cycle_wins_same_local_day(self):
        data = fixture()
        incomplete = {
            "id": 2,
            "start": "2024-01-02T10:00:00Z",
            "score": None,
        }
        data["cycles"].append(incomplete)
        result = build_day_rows(data, ZoneInfo("Europe/Zurich"))
        self.assertEqual(len(result.rows), 1)
        self.assertEqual(result.collisions, 1)
        self.assertEqual(result.rows[0]["Recovery score %"], 72)

    def test_timezone_is_explicit_and_changes_day_resolution(self):
        data = {
            "cycles": [
                {"id": 1, "start": "2024-01-02T00:30:00Z", "score": None},
                {"id": 2, "start": "2024-01-02T10:00:00Z", "score": None},
            ],
            "recoveries": [],
            "sleeps": [],
            "workouts": [],
        }
        validate_export(data)
        zurich = build_day_rows(data, ZoneInfo("Europe/Zurich"))
        los_angeles = build_day_rows(data, ZoneInfo("America/Los_Angeles"))
        self.assertEqual((len(zurich.rows), zurich.collisions), (1, 1))
        self.assertEqual((len(los_angeles.rows), los_angeles.collisions), (2, 0))


class EndToEndTests(unittest.TestCase):
    def test_conversion_writes_complete_edge_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "whoop-v2-raw.json"
            output = root / "out"
            source.write_text(json.dumps(fixture()), encoding="utf-8")
            summary = convert_export(source, output, ZoneInfo("Europe/Zurich"))

            self.assertEqual(summary.edge_days, 1)
            self.assertEqual(summary.workouts, 1)
            self.assertEqual(summary.day_collisions, 0)
            with (output / "physiological_cycles.csv").open(newline="") as file:
                days = list(csv.DictReader(file))
            with (output / "workouts.csv").open(newline="") as file:
                workouts = list(csv.DictReader(file))
            self.assertEqual(len(days), 1)
            self.assertEqual(len(workouts), 1)
            self.assertEqual(tuple(days[0]), DAY_HEADERS)
            self.assertEqual(tuple(workouts[0]), WORKOUT_HEADERS)
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            self.assertEqual(
                (output / "physiological_cycles.csv").stat().st_mode & 0o777,
                0o600,
            )
            self.assertEqual(
                (output / "workouts.csv").stat().st_mode & 0o777,
                0o600,
            )

    def test_invalid_input_does_not_replace_existing_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "invalid.json"
            output = root / "out"
            output.mkdir()
            day_path = output / "physiological_cycles.csv"
            workout_path = output / "workouts.csv"
            day_path.write_text("existing-day", encoding="utf-8")
            workout_path.write_text("existing-workout", encoding="utf-8")
            invalid = fixture()
            del invalid["sleeps"]
            source.write_text(json.dumps(invalid), encoding="utf-8")

            with self.assertRaises(ConversionError):
                convert_export(source, output, ZoneInfo("Europe/Zurich"))

            self.assertEqual(day_path.read_text(encoding="utf-8"), "existing-day")
            self.assertEqual(
                workout_path.read_text(encoding="utf-8"), "existing-workout"
            )


if __name__ == "__main__":
    unittest.main()
