"""Partition the Formula 1 source CSVs into a stage-ready directory layout.

Dimensions are copied through unchanged. Fact files are split by season, which
is what allows COPY INTO to load one season at a time and makes the pipeline's
incremental behaviour demonstrable rather than asserted.

Output layout, mirrored exactly by the internal stage:

    staged/
      circuits/circuits.csv
      constructors/constructors.csv
      drivers/drivers.csv
      status/status.csv
      races/season=2023/races_2023.csv
      results/season=2023/results_2023.csv
      pit_stops/season=2023/pit_stops_2023.csv

Usage:
    python scripts/prepare_data.py --source data/raw --target data/staged
    python scripts/prepare_data.py --source data/raw --target data/staged \\
        --min-season 2010
"""

from __future__ import annotations

import argparse
import logging
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path

import pandas as pd

LOGGER = logging.getLogger("prepare_data")

# The column every fact file joins to in order to learn its season.
RACE_KEY = "raceId"
SEASON_KEY = "year"


@dataclass(frozen=True)
class SourceFile:
    """One input CSV and how it should be laid out on the stage.

    partition_by_season distinguishes the two behaviours this script supports.
    Adding a new source file means adding an entry here, not editing any
    function below.
    """

    name: str
    partition_by_season: bool


SOURCE_FILES: tuple[SourceFile, ...] = (
    SourceFile("circuits", partition_by_season=False),
    SourceFile("constructors", partition_by_season=False),
    SourceFile("drivers", partition_by_season=False),
    SourceFile("status", partition_by_season=False),
    SourceFile("races", partition_by_season=True),
    SourceFile("results", partition_by_season=True),
    SourceFile("pit_stops", partition_by_season=True),
)


class PreparationError(RuntimeError):
    """Raised when the source directory cannot produce a valid staged output."""


def read_source(source_dir: Path, name: str) -> pd.DataFrame:
    """Read one source CSV, preserving every value as text.

    dtype=str is deliberate. Letting pandas infer types here would coerce the
    source's ``\\N`` null token, reformat identifiers, and turn ``01`` into
    ``1`` — corrupting data before Snowflake ever sees it. Typing is Snowflake's
    job, done once, in the STAGING layer.
    """
    path = source_dir / f"{name}.csv"
    if not path.is_file():
        raise PreparationError(f"Missing required source file: {path}")

    frame = pd.read_csv(path, dtype=str, keep_default_na=False, na_filter=False)
    LOGGER.info("Read %-14s %7d rows, %2d columns", name, len(frame), frame.shape[1])
    return frame


def build_season_lookup(races: pd.DataFrame) -> pd.Series:
    """Map raceId to season year.

    results.csv and pit_stops.csv carry no season column, so the partition key
    has to come from races.csv. This is the one genuine join performed outside
    Snowflake, and it exists only to decide file placement.
    """
    if RACE_KEY not in races.columns or SEASON_KEY not in races.columns:
        raise PreparationError(
            f"races.csv must contain '{RACE_KEY}' and '{SEASON_KEY}' columns; "
            f"found {list(races.columns)[:10]}"
        )
    return races.set_index(RACE_KEY)[SEASON_KEY]


def write_whole_file(frame: pd.DataFrame, target_dir: Path, name: str) -> int:
    """Write a dimension file to ``<target>/<name>/<name>.csv``."""
    destination = target_dir / name
    destination.mkdir(parents=True, exist_ok=True)
    frame.to_csv(destination / f"{name}.csv", index=False)
    return 1


def write_partitioned(
    frame: pd.DataFrame,
    target_dir: Path,
    name: str,
    seasons: pd.Series,
    min_season: int | None,
    max_season: int | None,
) -> int:
    """Split a fact file into one CSV per season and write each to its own path.

    Rows whose raceId is absent from races.csv are dropped and counted. They
    cannot be assigned a partition, and silently scattering them into an
    arbitrary season would be worse than losing them loudly.
    """
    if SEASON_KEY in frame.columns:
        season_of_row = frame[SEASON_KEY]
    else:
        season_of_row = frame[RACE_KEY].map(seasons)

    unmapped = int(season_of_row.isna().sum())
    if unmapped:
        LOGGER.warning("%s: dropping %d rows with no matching race", name, unmapped)

    working = frame.loc[season_of_row.notna()].copy()
    working["_season"] = season_of_row.loc[season_of_row.notna()].astype(int)

    # The season window is what makes an incremental arrival simulable: stage
    # history first with --max-season, then stage the remainder with
    # --min-season and let the file-arrival trigger do the rest.
    before = len(working)
    if min_season is not None:
        working = working.loc[working["_season"] >= min_season]
    if max_season is not None:
        working = working.loc[working["_season"] <= max_season]
    if min_season is not None or max_season is not None:
        LOGGER.info(
            "%s: kept %d of %d rows in season window [%s, %s]",
            name, len(working), before,
            min_season if min_season is not None else "-inf",
            max_season if max_season is not None else "+inf",
        )

    files_written = 0
    for season, group in working.groupby("_season", sort=True):
        destination = target_dir / name / f"season={season}"
        destination.mkdir(parents=True, exist_ok=True)
        group.drop(columns="_season").to_csv(
            destination / f"{name}_{season}.csv", index=False
        )
        files_written += 1

    LOGGER.info("%-14s wrote %3d season files", name, files_written)
    return files_written


def prepare(
    source_dir: Path,
    target_dir: Path,
    min_season: int | None,
    max_season: int | None,
) -> int:
    """Produce the staged directory tree. Returns the number of files written."""
    if not source_dir.is_dir():
        raise PreparationError(f"Source directory does not exist: {source_dir}")

    if target_dir.exists():
        LOGGER.info("Clearing previous output at %s", target_dir)
        shutil.rmtree(target_dir)
    target_dir.mkdir(parents=True)

    races = read_source(source_dir, "races")
    seasons = build_season_lookup(races)

    total_files = 0
    for source in SOURCE_FILES:
        frame = races if source.name == "races" else read_source(source_dir, source.name)

        if source.partition_by_season:
            total_files += write_partitioned(
                frame, target_dir, source.name, seasons, min_season, max_season
            )
        else:
            total_files += write_whole_file(frame, target_dir, source.name)

    return total_files


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Partition F1 source CSVs into a stage-ready layout.",
    )
    parser.add_argument(
        "--source", type=Path, default=Path("data/raw"),
        help="Directory holding the unzipped Kaggle CSVs (default: data/raw)",
    )
    parser.add_argument(
        "--target", type=Path, default=Path("data/staged"),
        help="Directory to write the partitioned output (default: data/staged)",
    )
    parser.add_argument(
        "--min-season", type=int, default=None,
        help="Drop seasons before this year. Useful for a smaller first load.",
    )
    parser.add_argument(
        "--max-season", type=int, default=None,
        help="Drop seasons after this year. Pair with --min-season to stage "
             "history first, then simulate a later arrival.",
    )
    parser.add_argument(
        "--verbose", action="store_true", help="Enable debug logging.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    logging.basicConfig(
        level=logging.DEBUG if arguments.verbose else logging.INFO,
        format="%(levelname)-8s %(message)s",
    )

    try:
        written = prepare(
            arguments.source, arguments.target,
            arguments.min_season, arguments.max_season,
        )
    except PreparationError as error:
        LOGGER.error("%s", error)
        return 1

    LOGGER.info("Done. %d files written to %s", written, arguments.target)
    return 0


if __name__ == "__main__":
    sys.exit(main())
