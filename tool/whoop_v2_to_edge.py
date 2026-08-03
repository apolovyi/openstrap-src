#!/usr/bin/env python3
"""Convert a WHOOP Developer API v2 archive into OpenStrap Edge CSVs."""

from __future__ import annotations

import argparse
import csv
import io
import json
import math
import os
import re
import tempfile
from collections import defaultdict
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone, tzinfo
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

COLLECTIONS = ("cycles", "recoveries", "sleeps", "workouts")
DAY_HEADERS = (
    "Local day",
    "Cycle start time",
    "Sleep onset",
    "Wake onset",
    "Recovery score %",
    "Resting heart rate (bpm)",
    "Heart rate variability (ms)",
    "Day Strain",
    "Energy burned (kJ)",
    "Respiratory rate (rpm)",
    "Blood oxygen %",
    "Skin temp (Celsius)",
    "Asleep duration (min)",
    "In bed duration (min)",
    "Light sleep duration (min)",
    "Deep (SWS) duration (min)",
    "REM duration (min)",
    "Awake duration (min)",
    "Sleep efficiency %",
    "Sleep performance %",
)
WORKOUT_HEADERS = (
    "Workout start time",
    "Workout end time",
    "Activity name",
    "Activity Strain",
    "Energy burned (kJ)",
    "Max HR (bpm)",
)

JsonObject = Mapping[str, Any]
CsvRow = dict[str, Any]


class ConversionError(ValueError):
    pass


@dataclass(frozen=True)
class ExportInventory:
    cycles: int
    recoveries: int
    sleeps: int
    workouts: int


@dataclass(frozen=True)
class ConversionSummary:
    cycles: int
    recoveries: int
    sleeps: int
    workouts: int
    edge_days: int
    day_collisions: int
    days_with_recovery: int
    days_with_sleep: int


@dataclass(frozen=True)
class DayRows:
    rows: list[CsvRow]
    collisions: int


@dataclass(frozen=True)
class ExportIndex:
    recoveries_by_cycle: dict[str, JsonObject]
    sleeps_by_id: dict[str, JsonObject]
    sleeps_by_cycle: dict[str, list[JsonObject]]


def load_export(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise ConversionError(f"cannot read {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise ConversionError(f"invalid JSON in {path}: {error}") from error
    validate_export(data)
    return data


def _records(data: JsonObject, name: str) -> list[JsonObject]:
    rows = data.get(name)
    if not isinstance(rows, list):
        raise ConversionError(f"{name} must be a list")
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise ConversionError(f"{name}[{index}] must be an object")
    return rows


def _unique_ids(rows: Sequence[JsonObject], key: str, name: str) -> set[str]:
    found: set[str] = set()
    for index, row in enumerate(rows):
        value = row.get(key)
        if value in (None, ""):
            raise ConversionError(f"{name}[{index}].{key} is required")
        normalized = str(value)
        if normalized in found:
            raise ConversionError(f"duplicate {name}.{key}: {normalized}")
        found.add(normalized)
    return found


def parse_timestamp(value: Any, field: str) -> datetime:
    if not isinstance(value, str) or not value.strip():
        raise ConversionError(f"{field} must be a non-empty timestamp")
    text = value.strip()
    if text.endswith("Z"):
        text = f"{text[:-1]}+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as error:
        raise ConversionError(f"{field} is not ISO-8601: {value}") from error
    if parsed.tzinfo is None:
        raise ConversionError(f"{field} must include a timezone offset")
    return parsed


def validate_export(data: Any) -> ExportInventory:
    if not isinstance(data, dict):
        raise ConversionError("export root must be an object")
    rows = {name: _records(data, name) for name in COLLECTIONS}
    cycle_ids = _unique_ids(rows["cycles"], "id", "cycles")
    recovery_cycle_ids = _unique_ids(
        rows["recoveries"], "cycle_id", "recoveries"
    )
    sleep_ids = _unique_ids(rows["sleeps"], "id", "sleeps")
    _unique_ids(rows["workouts"], "id", "workouts")

    for index, cycle in enumerate(rows["cycles"]):
        parse_timestamp(cycle.get("start"), f"cycles[{index}].start")
    for index, sleep in enumerate(rows["sleeps"]):
        cycle_id = str(sleep.get("cycle_id"))
        if cycle_id not in cycle_ids:
            raise ConversionError(
                f"sleeps[{index}].cycle_id references missing cycle {cycle_id}"
            )
        parse_timestamp(sleep.get("start"), f"sleeps[{index}].start")
        parse_timestamp(sleep.get("end"), f"sleeps[{index}].end")
    for index, recovery in enumerate(rows["recoveries"]):
        cycle_id = str(recovery.get("cycle_id"))
        if cycle_id not in cycle_ids:
            raise ConversionError(
                f"recoveries[{index}].cycle_id references missing cycle {cycle_id}"
            )
        sleep_id = recovery.get("sleep_id")
        if sleep_id is not None and str(sleep_id) not in sleep_ids:
            raise ConversionError(
                f"recoveries[{index}].sleep_id references missing sleep {sleep_id}"
            )
    for index, workout in enumerate(rows["workouts"]):
        parse_timestamp(workout.get("start"), f"workouts[{index}].start")

    return ExportInventory(
        cycles=len(cycle_ids),
        recoveries=len(recovery_cycle_ids),
        sleeps=len(sleep_ids),
        workouts=len(rows["workouts"]),
    )


def index_export(data: JsonObject) -> ExportIndex:
    recoveries = {
        str(row["cycle_id"]): row for row in _records(data, "recoveries")
    }
    sleeps_by_id = {str(row["id"]): row for row in _records(data, "sleeps")}
    sleeps_by_cycle: dict[str, list[JsonObject]] = defaultdict(list)
    for sleep in _records(data, "sleeps"):
        sleeps_by_cycle[str(sleep["cycle_id"])].append(sleep)
    return ExportIndex(recoveries, sleeps_by_id, dict(sleeps_by_cycle))


def _number(value: Any, field: str) -> int | float | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ConversionError(f"{field} must be numeric or null")
    if not math.isfinite(value):
        raise ConversionError(f"{field} must be finite")
    return value


def _nonnegative_number(value: Any, field: str) -> int | float | None:
    number = _number(value, field)
    if number is not None and number < 0:
        raise ConversionError(f"{field} must not be negative")
    return number


def _score(row: JsonObject | None, field: str) -> JsonObject:
    if row is None or row.get("score") is None:
        return {}
    score = row["score"]
    if not isinstance(score, dict):
        raise ConversionError(f"{field}.score must be an object or null")
    return score


def _in_bed_milli(sleep: JsonObject) -> int | float:
    stages = _score(sleep, "sleep").get("stage_summary") or {}
    if not isinstance(stages, dict):
        raise ConversionError("sleep.score.stage_summary must be an object or null")
    return _nonnegative_number(
        stages.get("total_in_bed_time_milli"),
        "sleep.score.stage_summary.total_in_bed_time_milli",
    ) or 0


def select_primary_sleep(
    cycle: JsonObject, recovery: JsonObject | None, index: ExportIndex
) -> JsonObject | None:
    sleep_id = recovery.get("sleep_id") if recovery else None
    if sleep_id is not None:
        return index.sleeps_by_id[str(sleep_id)]
    candidates = [
        sleep
        for sleep in index.sleeps_by_cycle.get(str(cycle["id"]), [])
        if not sleep.get("nap")
    ]
    return max(
        candidates,
        key=lambda sleep: (
            _in_bed_milli(sleep),
            str(sleep.get("start") or ""),
            str(sleep["id"]),
        ),
        default=None,
    )


def _minutes(value: Any, field: str) -> float | None:
    number = _nonnegative_number(value, field)
    return None if number is None else number / 60000


def _stage_minutes(stages: JsonObject, key: str) -> float | None:
    return _minutes(stages.get(key), f"sleep.score.stage_summary.{key}")


def build_day_row(
    cycle: JsonObject, recovery: JsonObject | None, sleep: JsonObject | None
) -> CsvRow:
    cycle_score = _score(cycle, "cycle")
    recovery_score = _score(recovery, "recovery")
    sleep_score = _score(sleep, "sleep")
    stages = sleep_score.get("stage_summary") or {}
    if not isinstance(stages, dict):
        raise ConversionError("sleep.score.stage_summary must be an object or null")

    stage_keys = (
        "total_light_sleep_time_milli",
        "total_slow_wave_sleep_time_milli",
        "total_rem_sleep_time_milli",
    )
    stage_values = [
        _nonnegative_number(stages.get(key), f"sleep.score.stage_summary.{key}")
        for key in stage_keys
    ]
    asleep = (
        sum(stage_values) / 60000
        if all(value is not None for value in stage_values)
        else None
    )

    return {
        "Cycle start time": cycle.get("start"),
        "Sleep onset": sleep.get("start") if sleep else None,
        "Wake onset": sleep.get("end") if sleep else None,
        "Recovery score %": _number(
            recovery_score.get("recovery_score"), "recovery.score.recovery_score"
        ),
        "Resting heart rate (bpm)": _number(
            recovery_score.get("resting_heart_rate"),
            "recovery.score.resting_heart_rate",
        ),
        "Heart rate variability (ms)": _number(
            recovery_score.get("hrv_rmssd_milli"),
            "recovery.score.hrv_rmssd_milli",
        ),
        "Day Strain": _number(cycle_score.get("strain"), "cycle.score.strain"),
        "Energy burned (kJ)": _number(
            cycle_score.get("kilojoule"), "cycle.score.kilojoule"
        ),
        "Respiratory rate (rpm)": _number(
            sleep_score.get("respiratory_rate"), "sleep.score.respiratory_rate"
        ),
        "Blood oxygen %": _number(
            recovery_score.get("spo2_percentage"),
            "recovery.score.spo2_percentage",
        ),
        "Skin temp (Celsius)": _number(
            recovery_score.get("skin_temp_celsius"),
            "recovery.score.skin_temp_celsius",
        ),
        "Asleep duration (min)": asleep,
        "In bed duration (min)": _stage_minutes(
            stages, "total_in_bed_time_milli"
        ),
        "Light sleep duration (min)": _stage_minutes(
            stages, "total_light_sleep_time_milli"
        ),
        "Deep (SWS) duration (min)": _stage_minutes(
            stages, "total_slow_wave_sleep_time_milli"
        ),
        "REM duration (min)": _stage_minutes(
            stages, "total_rem_sleep_time_milli"
        ),
        "Awake duration (min)": _stage_minutes(
            stages, "total_awake_time_milli"
        ),
        "Sleep efficiency %": _number(
            sleep_score.get("sleep_efficiency_percentage"),
            "sleep.score.sleep_efficiency_percentage",
        ),
        "Sleep performance %": _number(
            sleep_score.get("sleep_performance_percentage"),
            "sleep.score.sleep_performance_percentage",
        ),
    }


def parse_timezone_offset(value: Any, field: str) -> tzinfo:
    if value == "Z":
        return timezone.utc
    if not isinstance(value, str):
        raise ConversionError(f"{field} must be Z or an offset in +hh:mm form")
    match = re.fullmatch(r"([+-])(\d{2}):(\d{2})", value)
    if match is None:
        raise ConversionError(f"{field} must be Z or an offset in +hh:mm form")
    hours, minutes = int(match[2]), int(match[3])
    if hours > 23 or minutes > 59:
        raise ConversionError(f"{field} is outside the valid UTC offset range")
    total_minutes = hours * 60 + minutes
    if match[1] == "-":
        total_minutes = -total_minutes
    return timezone(timedelta(minutes=total_minutes))


def local_day(
    cycle: JsonObject,
    sleep: JsonObject | None,
    row: JsonObject,
    fallback_timezone: tzinfo,
) -> str:
    anchor = row.get("Wake onset") or row.get("Sleep onset") or row.get(
        "Cycle start time"
    )
    offset = (sleep or {}).get("timezone_offset") or cycle.get("timezone_offset")
    source_timezone = (
        parse_timezone_offset(offset, "WHOOP timezone_offset")
        if offset not in (None, "")
        else fallback_timezone
    )
    return (
        parse_timestamp(anchor, "day anchor")
        .astimezone(source_timezone)
        .date()
        .isoformat()
    )


def day_rank(row: JsonObject, cycle_id: Any) -> tuple[Any, ...]:
    completeness = sum(value not in (None, "") for value in row.values())
    return (
        row.get("Recovery score %") not in (None, ""),
        row.get("Sleep onset") not in (None, ""),
        completeness,
        row.get("Asleep duration (min)") or 0,
        row.get("Wake onset") or row.get("Cycle start time") or "",
        str(cycle_id),
    )


def build_day_rows(data: JsonObject, target_timezone: tzinfo) -> DayRows:
    index = index_export(data)
    selected: dict[str, tuple[tuple[Any, ...], CsvRow]] = {}
    collisions = 0
    for cycle in sorted(_records(data, "cycles"), key=lambda row: row["start"]):
        recovery = index.recoveries_by_cycle.get(str(cycle["id"]))
        sleep = select_primary_sleep(cycle, recovery, index)
        row = build_day_row(cycle, recovery, sleep)
        day = local_day(cycle, sleep, row, target_timezone)
        row["Local day"] = day
        ranked = (day_rank(row, cycle["id"]), row)
        previous = selected.get(day)
        if previous is not None:
            collisions += 1
        if previous is None or ranked[0] > previous[0]:
            selected[day] = ranked
    return DayRows([selected[day][1] for day in sorted(selected)], collisions)


def build_workout_rows(data: JsonObject) -> list[CsvRow]:
    rows = []
    for workout in sorted(_records(data, "workouts"), key=lambda row: row["start"]):
        score = _score(workout, "workout")
        rows.append(
            {
                "Workout start time": workout.get("start"),
                "Workout end time": workout.get("end"),
                "Activity name": workout.get("sport_name"),
                "Activity Strain": _number(
                    score.get("strain"), "workout.score.strain"
                ),
                "Energy burned (kJ)": _number(
                    score.get("kilojoule"), "workout.score.kilojoule"
                ),
                "Max HR (bpm)": _number(
                    score.get("max_heart_rate"), "workout.score.max_heart_rate"
                ),
            }
        )
    return rows


def render_csv(headers: Sequence[str], rows: Iterable[JsonObject]) -> str:
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=headers, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    return output.getvalue()


def _atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        newline="",
        dir=path.parent,
        prefix=f".{path.name}.",
        delete=False,
    ) as file:
        temp_path = Path(file.name)
        file.write(content)
    try:
        os.chmod(temp_path, 0o600)
        temp_path.replace(path)
        os.chmod(path, 0o600)
    except BaseException:
        temp_path.unlink(missing_ok=True)
        raise


def convert_export(
    input_path: Path, output_dir: Path, target_timezone: tzinfo
) -> ConversionSummary:
    data = load_export(input_path)
    inventory = validate_export(data)
    day_rows = build_day_rows(data, target_timezone)
    workout_rows = build_workout_rows(data)
    day_csv = render_csv(DAY_HEADERS, day_rows.rows)
    workout_csv = render_csv(WORKOUT_HEADERS, workout_rows)
    output_exists = output_dir.exists()
    output_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not output_exists:
        os.chmod(output_dir, 0o700)
    _atomic_write(output_dir / "physiological_cycles.csv", day_csv)
    _atomic_write(output_dir / "workouts.csv", workout_csv)
    return ConversionSummary(
        **asdict(inventory),
        edge_days=len(day_rows.rows),
        day_collisions=day_rows.collisions,
        days_with_recovery=sum(
            row["Recovery score %"] is not None for row in day_rows.rows
        ),
        days_with_sleep=sum(row["Sleep onset"] is not None for row in day_rows.rows),
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="WHOOP v2 raw JSON archive")
    parser.add_argument(
        "--output-dir", type=Path, required=True, help="private output directory"
    )
    parser.add_argument(
        "--timezone",
        required=True,
        help="IANA fallback timezone for records missing WHOOP timezone_offset",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        timezone = ZoneInfo(args.timezone)
        summary = convert_export(args.input, args.output_dir, timezone)
    except (ConversionError, ZoneInfoNotFoundError) as error:
        raise SystemExit(f"error: {error}") from error
    print(json.dumps(asdict(summary), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
