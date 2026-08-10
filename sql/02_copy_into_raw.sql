/* ============================================================================
   02_copy_into_raw.sql

   Purpose     : Load staged CSV files into RAW, capture rejects, record audit.
   Run as      : FR_F1_ENGINEER
   Idempotent  : Yes — and not by truncating. See note below.
   Depends on  : 01_raw_layer.sql, and files present in @STG_F1_FILES
                 (see scripts/load_to_stage.py)

   -- Why this is incremental for free --------------------------------------
   COPY INTO maintains per-table load metadata recording every file it has
   already ingested. Re-running an identical COPY loads nothing. Dropping the
   2024 season files into the stage and re-running loads only those files.

   This is the correct primitive for append-only file ingestion and it is the
   reason no explicit watermark table exists here. The caveat that matters:
   load metadata expires after 64 days, after which a re-run would reload old
   files. At that horizon you move to Snowpipe, whose metadata does not expire
   in the same way, or you drive loads from an explicit manifest.

   FORCE = TRUE overrides the metadata and reloads everything. It is never set
   below, intentionally.
   ============================================================================ */

USE ROLE FR_F1_ENGINEER;
USE WAREHOUSE WH_F1_LOAD;
USE DATABASE F1_DB;
USE SCHEMA RAW;

/* ----------------------------------------------------------------------------
   0. Confirm what is staged before loading anything.
   ---------------------------------------------------------------------------- */
LIST @STG_F1_FILES;

/* ----------------------------------------------------------------------------
   1. DIMENSION LOADS

   Each COPY uses a transformation SELECT rather than a bare column list.
   That is what makes METADATA$ pseudocolumns available — the price is that
   columns are positional ($1, $2, ...) rather than header-matched.

   The trade-off, stated plainly: MATCH_BY_COLUMN_NAME would survive a source
   column reorder, but cannot be combined with a transformation, so it would
   cost us file lineage. Lineage is worth more than reorder tolerance for a
   static published dataset. DW_LOADED_AT is populated by its column DEFAULT,
   since CURRENT_TIMESTAMP() is not permitted inside a COPY transformation.
   ---------------------------------------------------------------------------- */

COPY INTO RAW_CIRCUITS (
    circuitId, circuitRef, name, location, country, lat, lng, alt, url,
    DW_FILE_NAME, DW_FILE_ROW_NUMBER, DW_FILE_LAST_MODIFIED
)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9,
           METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_LAST_MODIFIED
    FROM @STG_F1_FILES/circuits/
)
FILE_FORMAT = (FORMAT_NAME = FF_F1_CSV)
ON_ERROR = CONTINUE;

INSERT INTO LOAD_REJECTS (TARGET_TABLE, ERROR_MESSAGE, FILE_NAME, LINE_NUMBER, CHARACTER_POS, REJECTED_RECORD)
SELECT 'RAW_CIRCUITS', ERROR, FILE, LINE, CHARACTER, REJECTED_RECORD
FROM TABLE(VALIDATE(RAW_CIRCUITS, JOB_ID => '_last'));


COPY INTO RAW_CONSTRUCTORS (
    constructorId, constructorRef, name, nationality, url,
    DW_FILE_NAME, DW_FILE_ROW_NUMBER, DW_FILE_LAST_MODIFIED
)
FROM (
    SELECT $1, $2, $3, $4, $5,
           METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_LAST_MODIFIED
    FROM @STG_F1_FILES/constructors/
)
FILE_FORMAT = (FORMAT_NAME = FF_F1_CSV)
ON_ERROR = CONTINUE;

INSERT INTO LOAD_REJECTS (TARGET_TABLE, ERROR_MESSAGE, FILE_NAME, LINE_NUMBER, CHARACTER_POS, REJECTED_RECORD)
SELECT 'RAW_CONSTRUCTORS', ERROR, FILE, LINE, CHARACTER, REJECTED_RECORD
FROM TABLE(VALIDATE(RAW_CONSTRUCTORS, JOB_ID => '_last'));


COPY INTO RAW_DRIVERS (
    driverId, driverRef, number, code, forename, surname, dob, nationality, url,
    DW_FILE_NAME, DW_FILE_ROW_NUMBER, DW_FILE_LAST_MODIFIED
)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9,
           METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_LAST_MODIFIED
    FROM @STG_F1_FILES/drivers/
)
FILE_FORMAT = (FORMAT_NAME = FF_F1_CSV)
ON_ERROR = CONTINUE;

INSERT INTO LOAD_REJECTS (TARGET_TABLE, ERROR_MESSAGE, FILE_NAME, LINE_NUMBER, CHARACTER_POS, REJECTED_RECORD)
SELECT 'RAW_DRIVERS', ERROR, FILE, LINE, CHARACTER, REJECTED_RECORD
FROM TABLE(VALIDATE(RAW_DRIVERS, JOB_ID => '_last'));


COPY INTO RAW_STATUS (
    statusId, status,
    DW_FILE_NAME, DW_FILE_ROW_NUMBER, DW_FILE_LAST_MODIFIED
)
FROM (
    SELECT $1, $2,
           METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_LAST_MODIFIED
    FROM @STG_F1_FILES/status/
)
FILE_FORMAT = (FORMAT_NAME = FF_F1_CSV)
ON_ERROR = CONTINUE;

INSERT INTO LOAD_REJECTS (TARGET_TABLE, ERROR_MESSAGE, FILE_NAME, LINE_NUMBER, CHARACTER_POS, REJECTED_RECORD)
SELECT 'RAW_STATUS', ERROR, FILE, LINE, CHARACTER, REJECTED_RECORD
FROM TABLE(VALIDATE(RAW_STATUS, JOB_ID => '_last'));


/* ----------------------------------------------------------------------------
   2. SEASON-PARTITIONED LOADS

   races, results and pit_stops are staged one file per season:
       @STG_F1_FILES/races/season=2023/races_2023.csv

   Pointing COPY at the parent prefix picks up every season directory, and on
   re-run picks up only seasons added since. Partitioning by an event-time key
   is what makes the incremental claim demonstrable rather than theoretical —
   see scripts/prepare_data.py, which derives season from races.csv.

   Only the first 8 positional columns of races are taken. Later releases of
   this dataset append practice and qualifying session columns; ignoring the
   tail means a source schema addition is a no-op rather than an incident.

   Each PATTERN ends in ([.]gz)? because load_to_stage.py uploads with
   AUTO_COMPRESS = TRUE, so the staged filename is results_2023.csv.gz. COPY
   decompresses transparently, but PATTERN matches the stored name, not the
   logical one. A pattern anchored to plain .csv silently matches zero files
   and reports a successful load of nothing.
   ---------------------------------------------------------------------------- */

COPY INTO RAW_RACES (
    raceId, year, round, circuitId, name, date, time, url,
    DW_FILE_NAME, DW_FILE_ROW_NUMBER, DW_FILE_LAST_MODIFIED
)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, $8,
           METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_LAST_MODIFIED
    FROM @STG_F1_FILES/races/
)
FILE_FORMAT = (FORMAT_NAME = FF_F1_CSV)
PATTERN = '.*races_[0-9]{4}[.]csv([.]gz)?'
ON_ERROR = CONTINUE;

INSERT INTO LOAD_REJECTS (TARGET_TABLE, ERROR_MESSAGE, FILE_NAME, LINE_NUMBER, CHARACTER_POS, REJECTED_RECORD)
SELECT 'RAW_RACES', ERROR, FILE, LINE, CHARACTER, REJECTED_RECORD
FROM TABLE(VALIDATE(RAW_RACES, JOB_ID => '_last'));


COPY INTO RAW_RESULTS (
    resultId, raceId, driverId, constructorId, number, grid, position,
    positionText, positionOrder, points, laps, time, milliseconds,
    fastestLap, rank, fastestLapTime, fastestLapSpeed, statusId,
    DW_FILE_NAME, DW_FILE_ROW_NUMBER, DW_FILE_LAST_MODIFIED
)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
           $11, $12, $13, $14, $15, $16, $17, $18,
           METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_LAST_MODIFIED
    FROM @STG_F1_FILES/results/
)
FILE_FORMAT = (FORMAT_NAME = FF_F1_CSV)
PATTERN = '.*results_[0-9]{4}[.]csv([.]gz)?'
ON_ERROR = CONTINUE;

INSERT INTO LOAD_REJECTS (TARGET_TABLE, ERROR_MESSAGE, FILE_NAME, LINE_NUMBER, CHARACTER_POS, REJECTED_RECORD)
SELECT 'RAW_RESULTS', ERROR, FILE, LINE, CHARACTER, REJECTED_RECORD
FROM TABLE(VALIDATE(RAW_RESULTS, JOB_ID => '_last'));


COPY INTO RAW_PIT_STOPS (
    raceId, driverId, stop, lap, time, duration, milliseconds,
    DW_FILE_NAME, DW_FILE_ROW_NUMBER, DW_FILE_LAST_MODIFIED
)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7,
           METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_LAST_MODIFIED
    FROM @STG_F1_FILES/pit_stops/
)
FILE_FORMAT = (FORMAT_NAME = FF_F1_CSV)
PATTERN = '.*pit_stops_[0-9]{4}[.]csv([.]gz)?'
ON_ERROR = CONTINUE;

INSERT INTO LOAD_REJECTS (TARGET_TABLE, ERROR_MESSAGE, FILE_NAME, LINE_NUMBER, CHARACTER_POS, REJECTED_RECORD)
SELECT 'RAW_PIT_STOPS', ERROR, FILE, LINE, CHARACTER, REJECTED_RECORD
FROM TABLE(VALIDATE(RAW_PIT_STOPS, JOB_ID => '_last'));


/* ----------------------------------------------------------------------------
   3. LOAD AUDIT

   One procedure, one job: copy COPY_HISTORY into LOAD_AUDIT. It does not load
   data and it does not validate data. INFORMATION_SCHEMA.COPY_HISTORY is used
   rather than ACCOUNT_USAGE because the latter lags by up to two hours, which
   makes it useless for verifying a load that just finished.

   The NOT EXISTS guard makes repeat invocation safe.
   ---------------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE SP_RECORD_LOAD_AUDIT(P_TABLES ARRAY, P_LOOKBACK_HOURS NUMBER)
RETURNS STRING
LANGUAGE SQL
COMMENT = 'Append COPY_HISTORY for the given RAW tables into LOAD_AUDIT.'
AS
$$
DECLARE
    v_table       STRING;
    v_inserted    NUMBER DEFAULT 0;
BEGIN
    FOR i IN 0 TO ARRAY_SIZE(:P_TABLES) - 1 DO
        v_table := GET(:P_TABLES, i)::STRING;

        EXECUTE IMMEDIATE
            'INSERT INTO F1_DB.RAW.LOAD_AUDIT
                 (TARGET_TABLE, FILE_NAME, LAST_LOAD_TIME, ROW_COUNT,
                  ROW_PARSED, ERROR_COUNT, FIRST_ERROR_MESSAGE, LOAD_STATUS)
             SELECT ''' || v_table || ''', ch.FILE_NAME, ch.LAST_LOAD_TIME,
                    ch.ROW_COUNT, ch.ROW_PARSED, ch.ERROR_COUNT,
                    ch.FIRST_ERROR_MESSAGE, ch.STATUS
             FROM TABLE(F1_DB.INFORMATION_SCHEMA.COPY_HISTORY(
                      TABLE_NAME => ''F1_DB.RAW.' || v_table || ''',
                      START_TIME => DATEADD(hour, -' || :P_LOOKBACK_HOURS || ', CURRENT_TIMESTAMP())
                  )) ch
             WHERE NOT EXISTS (
                 SELECT 1 FROM F1_DB.RAW.LOAD_AUDIT la
                 WHERE la.TARGET_TABLE = ''' || v_table || '''
                   AND la.FILE_NAME    = ch.FILE_NAME
                   AND la.LAST_LOAD_TIME = ch.LAST_LOAD_TIME
             )';

        v_inserted := v_inserted + SQLROWCOUNT;
    END FOR;

    RETURN 'LOAD_AUDIT rows inserted: ' || v_inserted;
END;
$$;

CALL SP_RECORD_LOAD_AUDIT(
    ARRAY_CONSTRUCT('RAW_CIRCUITS', 'RAW_CONSTRUCTORS', 'RAW_DRIVERS',
                    'RAW_STATUS', 'RAW_RACES', 'RAW_RESULTS', 'RAW_PIT_STOPS'),
    24
);

/* ----------------------------------------------------------------------------
   VERIFICATION — screenshot these three for the submission.
   ---------------------------------------------------------------------------- */

-- Did anything fail to parse? Expected: zero rows.
SELECT TARGET_TABLE, COUNT(*) AS reject_count
FROM LOAD_REJECTS
GROUP BY TARGET_TABLE;

-- What loaded, from which file, how cleanly.
SELECT TARGET_TABLE, FILE_NAME, ROW_COUNT, ERROR_COUNT, LOAD_STATUS, LAST_LOAD_TIME
FROM LOAD_AUDIT
ORDER BY LAST_LOAD_TIME DESC, TARGET_TABLE
LIMIT 50;

-- Row counts landed per table.
SELECT 'RAW_CIRCUITS' AS tbl, COUNT(*) AS row_count FROM RAW_CIRCUITS
UNION ALL SELECT 'RAW_CONSTRUCTORS', COUNT(*) FROM RAW_CONSTRUCTORS
UNION ALL SELECT 'RAW_DRIVERS',      COUNT(*) FROM RAW_DRIVERS
UNION ALL SELECT 'RAW_STATUS',       COUNT(*) FROM RAW_STATUS
UNION ALL SELECT 'RAW_RACES',        COUNT(*) FROM RAW_RACES
UNION ALL SELECT 'RAW_RESULTS',      COUNT(*) FROM RAW_RESULTS
UNION ALL SELECT 'RAW_PIT_STOPS',    COUNT(*) FROM RAW_PIT_STOPS
ORDER BY tbl;
