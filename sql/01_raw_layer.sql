/* ============================================================================
   01_raw_layer.sql

   Purpose     : RAW landing zone — file format, internal stage, untyped
                 tables with file lineage, and the load audit table.
   Run as      : FR_F1_ENGINEER
   Idempotent  : Yes.
   Depends on  : 00_account_setup.sql

   Design rules for this layer:
     1. Every column is VARCHAR. A malformed value must never fail a load —
        it must land, and be caught by the quality gate downstream.
     2. Every row records which file it came from and when. Without lineage
        you cannot answer "where did this bad row come from", which is the
        first question asked in every production incident.
     3. Append-only. RAW is the audit trail; correction happens in STAGING.
   ============================================================================ */

USE ROLE FR_F1_ENGINEER;
USE WAREHOUSE WH_F1_LOAD;
USE DATABASE F1_DB;
USE SCHEMA RAW;

/* ----------------------------------------------------------------------------
   1. FILE FORMAT — defined once as a named object, referenced everywhere.

   NULL_IF matters here: the Ergast/Kaggle F1 export encodes missing values as
   the literal two-character string \N, not as an empty field. Without this,
   every optional column arrives as the string '\N' and every downstream
   TRY_TO_NUMBER silently returns NULL for a different reason than intended.
   ---------------------------------------------------------------------------- */
CREATE OR REPLACE FILE FORMAT FF_F1_CSV
    TYPE                         = CSV
    FIELD_DELIMITER              = ','
    SKIP_HEADER                  = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    TRIM_SPACE                   = TRUE
    EMPTY_FIELD_AS_NULL          = TRUE
    NULL_IF                      = ('\\N', 'N', '', 'NULL', 'null')
    ENCODING                     = 'UTF8'
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
    COMMENT = 'Ergast F1 CSV export. \\N is the source null token.';

/* ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE is deliberate: races.csv gained
   practice/qualifying session columns in later releases of this dataset.
   Tolerating extra trailing columns means a source schema addition does not
   break ingestion. We select positionally and ignore the tail. */

/* ----------------------------------------------------------------------------
   2. INTERNAL STAGE
   Directory table enabled so staged files are queryable as metadata —
   useful for reconciling "what did I upload" against "what did I load".
   ---------------------------------------------------------------------------- */
CREATE STAGE IF NOT EXISTS STG_F1_FILES
    DIRECTORY = (ENABLE = TRUE)
    FILE_FORMAT = FF_F1_CSV
    COMMENT = 'Internal stage. Layout: <table_name>/[<season>/]<file>.csv';

/* ----------------------------------------------------------------------------
   3. LOAD AUDIT TABLE
   Populated from INFORMATION_SCHEMA.COPY_HISTORY after each load batch.
   ACCOUNT_USAGE.COPY_HISTORY is the alternative but carries up to 2 hours
   of latency, which is useless for verifying a load you just ran.
   ---------------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS LOAD_AUDIT (
    AUDIT_ID            NUMBER IDENTITY START 1 INCREMENT 1,
    TARGET_TABLE        VARCHAR(255)   NOT NULL,
    FILE_NAME           VARCHAR(1000)  NOT NULL,
    LAST_LOAD_TIME      TIMESTAMP_LTZ,
    ROW_COUNT           NUMBER,
    ROW_PARSED          NUMBER,
    ERROR_COUNT         NUMBER,
    FIRST_ERROR_MESSAGE VARCHAR(4000),
    LOAD_STATUS         VARCHAR(50),
    RECORDED_AT         TIMESTAMP_LTZ  DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'One row per file per COPY. Answers: what loaded, when, how cleanly.';

/* ----------------------------------------------------------------------------
   4. REJECTED ROWS
   Rows that COPY could not parse at all, captured via VALIDATE(). These never
   reach RAW, so without this table they would vanish silently.
   ---------------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS LOAD_REJECTS (
    REJECT_ID       NUMBER IDENTITY START 1 INCREMENT 1,
    TARGET_TABLE    VARCHAR(255),
    ERROR_MESSAGE   VARCHAR(4000),
    FILE_NAME       VARCHAR(1000),
    LINE_NUMBER     NUMBER,
    CHARACTER_POS   NUMBER,
    REJECTED_RECORD VARCHAR(16777216),
    RECORDED_AT     TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Unparseable source rows. Empty is the expected steady state.';

/* ----------------------------------------------------------------------------
   5. LANDING TABLES

   Naming: RAW_<source_file>. Column names mirror the source header exactly,
   including its camelCase, so a reader can diff RAW against the CSV without
   consulting a mapping document. Renaming to snake_case happens in STAGING,
   where it is a deliberate, documented transformation rather than an
   undocumented drift.

   The four DW_ columns are identical on every table. They are the lineage
   contract every RAW table must satisfy.
   ---------------------------------------------------------------------------- */

-- Dimensions -----------------------------------------------------------------

CREATE TABLE IF NOT EXISTS RAW_CIRCUITS (
    circuitId       VARCHAR, circuitRef    VARCHAR, name        VARCHAR,
    location        VARCHAR, country       VARCHAR, lat         VARCHAR,
    lng             VARCHAR, alt           VARCHAR, url         VARCHAR,
    DW_FILE_NAME          VARCHAR(1000),
    DW_FILE_ROW_NUMBER    NUMBER,
    DW_FILE_LAST_MODIFIED TIMESTAMP_NTZ,
    DW_LOADED_AT          TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS RAW_CONSTRUCTORS (
    constructorId   VARCHAR, constructorRef VARCHAR, name       VARCHAR,
    nationality     VARCHAR, url            VARCHAR,
    DW_FILE_NAME          VARCHAR(1000),
    DW_FILE_ROW_NUMBER    NUMBER,
    DW_FILE_LAST_MODIFIED TIMESTAMP_NTZ,
    DW_LOADED_AT          TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS RAW_DRIVERS (
    driverId        VARCHAR, driverRef     VARCHAR, number      VARCHAR,
    code            VARCHAR, forename      VARCHAR, surname     VARCHAR,
    dob             VARCHAR, nationality   VARCHAR, url         VARCHAR,
    DW_FILE_NAME          VARCHAR(1000),
    DW_FILE_ROW_NUMBER    NUMBER,
    DW_FILE_LAST_MODIFIED TIMESTAMP_NTZ,
    DW_LOADED_AT          TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS RAW_STATUS (
    statusId        VARCHAR, status        VARCHAR,
    DW_FILE_NAME          VARCHAR(1000),
    DW_FILE_ROW_NUMBER    NUMBER,
    DW_FILE_LAST_MODIFIED TIMESTAMP_NTZ,
    DW_LOADED_AT          TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS RAW_RACES (
    raceId          VARCHAR, year          VARCHAR, round       VARCHAR,
    circuitId       VARCHAR, name          VARCHAR, date        VARCHAR,
    time            VARCHAR, url           VARCHAR,
    DW_FILE_NAME          VARCHAR(1000),
    DW_FILE_ROW_NUMBER    NUMBER,
    DW_FILE_LAST_MODIFIED TIMESTAMP_NTZ,
    DW_LOADED_AT          TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Facts ----------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS RAW_RESULTS (
    resultId        VARCHAR, raceId        VARCHAR, driverId    VARCHAR,
    constructorId   VARCHAR, number        VARCHAR, grid        VARCHAR,
    position        VARCHAR, positionText  VARCHAR, positionOrder VARCHAR,
    points          VARCHAR, laps          VARCHAR, time        VARCHAR,
    milliseconds    VARCHAR, fastestLap    VARCHAR, rank        VARCHAR,
    fastestLapTime  VARCHAR, fastestLapSpeed VARCHAR, statusId  VARCHAR,
    DW_FILE_NAME          VARCHAR(1000),
    DW_FILE_ROW_NUMBER    NUMBER,
    DW_FILE_LAST_MODIFIED TIMESTAMP_NTZ,
    DW_LOADED_AT          TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS RAW_PIT_STOPS (
    raceId          VARCHAR, driverId      VARCHAR, stop        VARCHAR,
    lap             VARCHAR, time          VARCHAR, duration    VARCHAR,
    milliseconds    VARCHAR,
    DW_FILE_NAME          VARCHAR(1000),
    DW_FILE_ROW_NUMBER    NUMBER,
    DW_FILE_LAST_MODIFIED TIMESTAMP_NTZ,
    DW_LOADED_AT          TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

/* ----------------------------------------------------------------------------
   VERIFICATION
   ---------------------------------------------------------------------------- */
SHOW TABLES IN SCHEMA F1_DB.RAW;
LIST @STG_F1_FILES;
