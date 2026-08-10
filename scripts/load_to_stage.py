"""Upload prepared CSVs to the Snowflake internal stage.

PUT is not available in Snowsight worksheets, so file upload needs a client.
Doing it in a script rather than through the UI means the load is repeatable,
reviewable, and produces a log of exactly what was sent.

Credentials come from environment variables only. See .env.example.

Usage:
    python scripts/load_to_stage.py --source data/staged
    python scripts/load_to_stage.py --source data/staged --dry-run
    python scripts/load_to_stage.py --source data/staged --only results,races
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from dataclasses import dataclass
from pathlib import Path

import snowflake.connector

LOGGER = logging.getLogger("load_to_stage")

STAGE_NAME = "F1_DB.RAW.STG_F1_FILES"

REQUIRED_ENVIRONMENT = ("SNOWFLAKE_ACCOUNT", "SNOWFLAKE_USER")


@dataclass(frozen=True)
class SnowflakeConfig:
    """Connection settings, read once from the environment.

    Held as a value object so every function that needs connection details
    takes them as an argument rather than reaching for os.environ itself.
    """

    account: str
    user: str
    password: str | None
    authenticator: str
    role: str
    warehouse: str
    database: str
    schema: str

    @classmethod
    def from_environment(cls) -> "SnowflakeConfig":
        missing = [name for name in REQUIRED_ENVIRONMENT if not os.environ.get(name)]
        if missing:
            raise SystemExit(
                "Missing environment variables: "
                + ", ".join(missing)
                + "\nCopy .env.example to .env and populate it."
            )

        # externalbrowser avoids putting a password in the environment at all,
        # which is the right default for an interactive developer machine.
        authenticator = os.environ.get("SNOWFLAKE_AUTHENTICATOR", "externalbrowser")
        password = os.environ.get("SNOWFLAKE_PASSWORD")

        if authenticator == "snowflake" and not password:
            raise SystemExit(
                "SNOWFLAKE_AUTHENTICATOR=snowflake requires SNOWFLAKE_PASSWORD."
            )

        return cls(
            account=os.environ["SNOWFLAKE_ACCOUNT"],
            user=os.environ["SNOWFLAKE_USER"],
            password=password,
            authenticator=authenticator,
            role=os.environ.get("SNOWFLAKE_ROLE", "FR_F1_ENGINEER"),
            warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE", "WH_F1_LOAD"),
            database=os.environ.get("SNOWFLAKE_DATABASE", "F1_DB"),
            schema=os.environ.get("SNOWFLAKE_SCHEMA", "RAW"),
        )

    def as_connect_kwargs(self) -> dict[str, str]:
        kwargs = {
            "account": self.account,
            "user": self.user,
            "authenticator": self.authenticator,
            "role": self.role,
            "warehouse": self.warehouse,
            "database": self.database,
            "schema": self.schema,
        }
        if self.password:
            kwargs["password"] = self.password
        return kwargs


@dataclass(frozen=True)
class Upload:
    """One local file and the stage path it belongs at."""

    local_path: Path
    stage_path: str

    def to_put_statement(self) -> str:
        # AUTO_COMPRESS gzips in transit; COPY decompresses transparently.
        # OVERWRITE keeps re-runs idempotent at the stage level — COPY's own
        # load metadata still prevents the data being ingested twice.
        return (
            f"PUT 'file://{self.local_path.as_posix()}' "
            f"'@{STAGE_NAME}/{self.stage_path}' "
            "AUTO_COMPRESS = TRUE OVERWRITE = TRUE PARALLEL = 4"
        )


def discover_uploads(source_dir: Path, only: set[str] | None) -> list[Upload]:
    """Walk the prepared directory and derive each file's stage path.

    The stage mirrors the local tree exactly, so the COPY statements in
    02_copy_into_raw.sql can address a whole table by prefix without knowing
    how many season files exist.
    """
    if not source_dir.is_dir():
        raise SystemExit(f"Source directory does not exist: {source_dir}")

    uploads: list[Upload] = []
    for path in sorted(source_dir.rglob("*.csv")):
        relative = path.relative_to(source_dir)
        table_name = relative.parts[0]

        if only and table_name not in only:
            continue

        # Stage path is the parent directory; PUT appends the filename.
        uploads.append(Upload(local_path=path.resolve(), stage_path=relative.parent.as_posix()))

    if not uploads:
        raise SystemExit(f"No CSV files found under {source_dir}. Run prepare_data.py first.")

    return uploads


def upload_all(config: SnowflakeConfig, uploads: list[Upload]) -> int:
    """Execute every PUT. Returns the count of files uploaded."""
    uploaded = 0
    with snowflake.connector.connect(**config.as_connect_kwargs()) as connection:
        with connection.cursor() as cursor:
            for index, upload in enumerate(uploads, start=1):
                cursor.execute(upload.to_put_statement())
                result = cursor.fetchone()
                # PUT returns: source, target, source_size, target_size,
                # source_compression, target_compression, status, message
                status = result[6] if result and len(result) > 6 else "UNKNOWN"
                LOGGER.info(
                    "[%3d/%3d] %-45s %s",
                    index, len(uploads), upload.stage_path + "/" + upload.local_path.name, status,
                )
                if status in {"UPLOADED", "SKIPPED"}:
                    uploaded += 1
                else:
                    LOGGER.error("Unexpected PUT status for %s: %s", upload.local_path, result)

            # An internal stage's directory table does not notice new files on
            # its own. Refreshing here means the uploader announces its own
            # arrival, which is what lets the stage stream fire the task graph
            # without anything having to poll for it.
            LOGGER.info("Refreshing directory table on @%s", STAGE_NAME)
            cursor.execute(f"ALTER STAGE {STAGE_NAME} REFRESH")

    return uploaded


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="PUT prepared CSVs to the Snowflake internal stage.",
    )
    parser.add_argument(
        "--source", type=Path, default=Path("data/staged"),
        help="Directory produced by prepare_data.py (default: data/staged)",
    )
    parser.add_argument(
        "--only", type=str, default=None,
        help="Comma-separated table names to upload, e.g. 'results,races'.",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Print the PUT statements without connecting to Snowflake.",
    )
    parser.add_argument("--verbose", action="store_true", help="Enable debug logging.")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    logging.basicConfig(
        level=logging.DEBUG if arguments.verbose else logging.INFO,
        format="%(levelname)-8s %(message)s",
    )

    only = set(arguments.only.split(",")) if arguments.only else None
    uploads = discover_uploads(arguments.source, only)
    LOGGER.info("Found %d files to upload to @%s", len(uploads), STAGE_NAME)

    # Dry run returns before reading credentials — that is the point of it.
    if arguments.dry_run:
        for upload in uploads:
            LOGGER.info("[dry-run] %s", upload.to_put_statement())
        return 0

    uploaded = upload_all(SnowflakeConfig.from_environment(), uploads)
    LOGGER.info("Uploaded %d of %d files.", uploaded, len(uploads))
    LOGGER.info("Next: run sql/02_copy_into_raw.sql in Snowsight.")
    return 0 if uploaded == len(uploads) else 1


if __name__ == "__main__":
    sys.exit(main())
