/* ============================================================================
   03_staging_merge.sql

   Purpose     : Type, rename, deduplicate and conform RAW into STAGING.
   Run as      : FR_F1_ENGINEER
   Idempotent  : Yes — MERGE on business key, not truncate-and-reload.
   Depends on  : 02_copy_into_raw.sql

   Three rules this layer enforces:

     1. TRY_ conversions only. TO_NUMBER on a bad value aborts the whole
        statement; TRY_TO_NUMBER yields NULL and lets script 05 quantify how
        much is broken. A pipeline that fails loudly on one bad row is not
        more correct, it is just less available.

     2. Deduplicate before MERGE. RAW is append-only, so re-loading a season
        leaves two generations of the same business key. MERGE raises
        "duplicate row would be updated" if the source is not unique, so the
        QUALIFY clause picking the newest arrival is load-bearing, not tidy.

     3. Hash-diff on update. Comparing ROW_HASH means unchanged rows are not
        rewritten, so DW_UPDATED_AT stays meaningful and micro-partition churn
        stays proportional to real change rather than to load frequency.

   Naming shifts from the source's camelCase to snake_case here. That is a
   deliberate, single-place transformation — RAW still mirrors the CSV exactly.
   ============================================================================ */

USE ROLE FR_F1_ENGINEER;
USE WAREHOUSE WH_F1_TRANSFORM;
USE DATABASE F1_DB;
USE SCHEMA STAGING;

/* ----------------------------------------------------------------------------
   0. SHARED UDF

   Lap and pit-stop durations arrive in two shapes: "1:27.452" and "22.879".
   Parsing appears three times across this layer, so it lives in one function.
   Deterministic and SQL-only, which keeps it eligible for incremental refresh
   if a downstream dynamic table ever needs it.
   ---------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION FN_DURATION_TO_MS(P_DURATION VARCHAR)
RETURNS NUMBER(38,0)
LANGUAGE SQL
COMMENT = 'Parse "m:ss.SSS" or "ss.SSS" into whole milliseconds. NULL-safe.'
AS
$$
    CAST(
        CASE
            WHEN P_DURATION IS NULL THEN NULL
            WHEN POSITION(':' IN P_DURATION) > 0
                THEN TRY_TO_NUMBER(SPLIT_PART(P_DURATION, ':', 1)) * 60000
                   + ROUND(TRY_TO_DOUBLE(SPLIT_PART(P_DURATION, ':', 2)) * 1000)
            ELSE ROUND(TRY_TO_DOUBLE(P_DURATION) * 1000)
        END AS NUMBER(38,0)
    )
$$;

/* ============================================================================
   1. TABLE DEFINITIONS

   Every table carries the same four housekeeping columns. ROW_HASH drives
   change detection; DW_SOURCE_FILE preserves lineage through the layer so a
   suspect analytics row can still be traced back to a physical file.
   ============================================================================ */

CREATE TABLE IF NOT EXISTS STG_CIRCUIT (
    CIRCUIT_ID      NUMBER(38,0)  NOT NULL PRIMARY KEY,
    CIRCUIT_REF     VARCHAR(100),
    CIRCUIT_NAME    VARCHAR(255),
    LOCATION        VARCHAR(255),
    COUNTRY         VARCHAR(100),
    LATITUDE        FLOAT,
    LONGITUDE       FLOAT,
    ALTITUDE_M      NUMBER(10,0),
    ROW_HASH        VARCHAR(64)   NOT NULL,
    DW_SOURCE_FILE  VARCHAR(1000),
    DW_INSERTED_AT  TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    DW_UPDATED_AT   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS STG_CONSTRUCTOR (
    CONSTRUCTOR_ID   NUMBER(38,0) NOT NULL PRIMARY KEY,
    CONSTRUCTOR_REF  VARCHAR(100),
    CONSTRUCTOR_NAME VARCHAR(255),
    NATIONALITY      VARCHAR(100),
    ROW_HASH         VARCHAR(64)  NOT NULL,
    DW_SOURCE_FILE   VARCHAR(1000),
    DW_INSERTED_AT   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    DW_UPDATED_AT    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS STG_DRIVER (
    DRIVER_ID       NUMBER(38,0) NOT NULL PRIMARY KEY,
    DRIVER_REF      VARCHAR(100),
    PERMANENT_NUMBER NUMBER(10,0),
    DRIVER_CODE     VARCHAR(10),
    FORENAME        VARCHAR(100),
    SURNAME         VARCHAR(100),
    FULL_NAME       VARCHAR(200),
    DATE_OF_BIRTH   DATE,
    NATIONALITY     VARCHAR(100),
    ROW_HASH        VARCHAR(64)  NOT NULL,
    DW_SOURCE_FILE  VARCHAR(1000),
    DW_INSERTED_AT  TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    DW_UPDATED_AT   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS STG_STATUS (
    STATUS_ID          NUMBER(38,0) NOT NULL PRIMARY KEY,
    STATUS_DESCRIPTION VARCHAR(255),
    IS_CLASSIFIED_FINISH BOOLEAN,
    ROW_HASH           VARCHAR(64) NOT NULL,
    DW_SOURCE_FILE     VARCHAR(1000),
    DW_INSERTED_AT     TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    DW_UPDATED_AT      TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS STG_RACE (
    RACE_ID         NUMBER(38,0) NOT NULL PRIMARY KEY,
    SEASON_YEAR     NUMBER(4,0),
    ROUND_NUMBER    NUMBER(4,0),
    CIRCUIT_ID      NUMBER(38,0),
    RACE_NAME       VARCHAR(255),
    RACE_DATE       DATE,
    RACE_START_UTC  TIME,
    ROW_HASH        VARCHAR(64)  NOT NULL,
    DW_SOURCE_FILE  VARCHAR(1000),
    DW_INSERTED_AT  TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    DW_UPDATED_AT   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS STG_RACE_RESULT (
    RESULT_ID            NUMBER(38,0) NOT NULL PRIMARY KEY,
    RACE_ID              NUMBER(38,0),
    DRIVER_ID            NUMBER(38,0),
    CONSTRUCTOR_ID       NUMBER(38,0),
    STATUS_ID            NUMBER(38,0),
    CAR_NUMBER           NUMBER(10,0),
    GRID_POSITION        NUMBER(4,0),
    FINISH_POSITION      NUMBER(4,0),
    POSITION_ORDER       NUMBER(4,0),
    POINTS               NUMBER(8,2),
    LAPS_COMPLETED       NUMBER(6,0),
    RACE_DURATION_MS     NUMBER(18,0),
    FASTEST_LAP_NUMBER   NUMBER(6,0),
    FASTEST_LAP_RANK     NUMBER(6,0),
    FASTEST_LAP_MS       NUMBER(18,0),
    FASTEST_LAP_SPEED_KPH FLOAT,
    ROW_HASH             VARCHAR(64) NOT NULL,
    DW_SOURCE_FILE       VARCHAR(1000),
    DW_INSERTED_AT       TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    DW_UPDATED_AT        TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS STG_PIT_STOP (
    PIT_STOP_KEY    VARCHAR(64)  NOT NULL PRIMARY KEY,
    RACE_ID         NUMBER(38,0),
    DRIVER_ID       NUMBER(38,0),
    STOP_NUMBER     NUMBER(4,0),
    LAP_NUMBER      NUMBER(6,0),
    STOP_TIME_LOCAL TIME,
    DURATION_MS     NUMBER(18,0),
    ROW_HASH        VARCHAR(64)  NOT NULL,
    DW_SOURCE_FILE  VARCHAR(1000),
    DW_INSERTED_AT  TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    DW_UPDATED_AT   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

/* pit_stops.csv has no surrogate key. The natural key is
   (raceId, driverId, stop); PIT_STOP_KEY is its deterministic hash so the
   MERGE predicate stays a single-column equality. */

/* ============================================================================
   2. MERGES

   Pattern, identical for every table:
       typed  -> cast, rename, dedupe on business key
       hashed -> add ROW_HASH over the business attributes only
       MERGE  -> insert new keys, update only genuinely changed rows

   ROW_HASH deliberately excludes lineage columns. Re-loading the same content
   from a differently-named file is not a data change and must not register
   as one.
   ============================================================================ */

-- 2.1 Circuits ---------------------------------------------------------------
MERGE INTO STG_CIRCUIT AS tgt
USING (
    WITH typed AS (
        SELECT
            TRY_TO_NUMBER(circuitId)                       AS CIRCUIT_ID,
            circuitRef                                     AS CIRCUIT_REF,
            name                                           AS CIRCUIT_NAME,
            location                                       AS LOCATION,
            country                                        AS COUNTRY,
            TRY_TO_DOUBLE(lat)                             AS LATITUDE,
            TRY_TO_DOUBLE(lng)                             AS LONGITUDE,
            TRY_TO_NUMBER(alt)                             AS ALTITUDE_M,
            DW_FILE_NAME                                   AS DW_SOURCE_FILE
        FROM F1_DB.RAW.RAW_CIRCUITS
        WHERE TRY_TO_NUMBER(circuitId) IS NOT NULL
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY TRY_TO_NUMBER(circuitId)
            ORDER BY DW_LOADED_AT DESC, DW_FILE_ROW_NUMBER DESC
        ) = 1
    )
    SELECT
        typed.*,
        SHA2(CONCAT_WS('||',
            COALESCE(CIRCUIT_REF, '~'), COALESCE(CIRCUIT_NAME, '~'),
            COALESCE(LOCATION, '~'),    COALESCE(COUNTRY, '~'),
            COALESCE(LATITUDE::VARCHAR, '~'), COALESCE(LONGITUDE::VARCHAR, '~'),
            COALESCE(ALTITUDE_M::VARCHAR, '~')
        ), 256) AS ROW_HASH
    FROM typed
) AS src
ON tgt.CIRCUIT_ID = src.CIRCUIT_ID
WHEN MATCHED AND tgt.ROW_HASH <> src.ROW_HASH THEN UPDATE SET
    tgt.CIRCUIT_REF = src.CIRCUIT_REF, tgt.CIRCUIT_NAME = src.CIRCUIT_NAME,
    tgt.LOCATION = src.LOCATION, tgt.COUNTRY = src.COUNTRY,
    tgt.LATITUDE = src.LATITUDE, tgt.LONGITUDE = src.LONGITUDE,
    tgt.ALTITUDE_M = src.ALTITUDE_M, tgt.ROW_HASH = src.ROW_HASH,
    tgt.DW_SOURCE_FILE = src.DW_SOURCE_FILE,
    tgt.DW_UPDATED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    CIRCUIT_ID, CIRCUIT_REF, CIRCUIT_NAME, LOCATION, COUNTRY,
    LATITUDE, LONGITUDE, ALTITUDE_M, ROW_HASH, DW_SOURCE_FILE
) VALUES (
    src.CIRCUIT_ID, src.CIRCUIT_REF, src.CIRCUIT_NAME, src.LOCATION, src.COUNTRY,
    src.LATITUDE, src.LONGITUDE, src.ALTITUDE_M, src.ROW_HASH, src.DW_SOURCE_FILE
);

-- 2.2 Constructors -----------------------------------------------------------
MERGE INTO STG_CONSTRUCTOR AS tgt
USING (
    WITH typed AS (
        SELECT
            TRY_TO_NUMBER(constructorId) AS CONSTRUCTOR_ID,
            constructorRef               AS CONSTRUCTOR_REF,
            name                         AS CONSTRUCTOR_NAME,
            nationality                  AS NATIONALITY,
            DW_FILE_NAME                 AS DW_SOURCE_FILE
        FROM F1_DB.RAW.RAW_CONSTRUCTORS
        WHERE TRY_TO_NUMBER(constructorId) IS NOT NULL
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY TRY_TO_NUMBER(constructorId)
            ORDER BY DW_LOADED_AT DESC, DW_FILE_ROW_NUMBER DESC
        ) = 1
    )
    SELECT typed.*,
        SHA2(CONCAT_WS('||',
            COALESCE(CONSTRUCTOR_REF, '~'), COALESCE(CONSTRUCTOR_NAME, '~'),
            COALESCE(NATIONALITY, '~')
        ), 256) AS ROW_HASH
    FROM typed
) AS src
ON tgt.CONSTRUCTOR_ID = src.CONSTRUCTOR_ID
WHEN MATCHED AND tgt.ROW_HASH <> src.ROW_HASH THEN UPDATE SET
    tgt.CONSTRUCTOR_REF = src.CONSTRUCTOR_REF,
    tgt.CONSTRUCTOR_NAME = src.CONSTRUCTOR_NAME,
    tgt.NATIONALITY = src.NATIONALITY, tgt.ROW_HASH = src.ROW_HASH,
    tgt.DW_SOURCE_FILE = src.DW_SOURCE_FILE,
    tgt.DW_UPDATED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    CONSTRUCTOR_ID, CONSTRUCTOR_REF, CONSTRUCTOR_NAME, NATIONALITY,
    ROW_HASH, DW_SOURCE_FILE
) VALUES (
    src.CONSTRUCTOR_ID, src.CONSTRUCTOR_REF, src.CONSTRUCTOR_NAME,
    src.NATIONALITY, src.ROW_HASH, src.DW_SOURCE_FILE
);

-- 2.3 Drivers ----------------------------------------------------------------
MERGE INTO STG_DRIVER AS tgt
USING (
    WITH typed AS (
        SELECT
            TRY_TO_NUMBER(driverId)          AS DRIVER_ID,
            driverRef                        AS DRIVER_REF,
            TRY_TO_NUMBER(number)            AS PERMANENT_NUMBER,
            code                             AS DRIVER_CODE,
            forename                         AS FORENAME,
            surname                          AS SURNAME,
            TRIM(forename || ' ' || surname) AS FULL_NAME,
            TRY_TO_DATE(dob, 'YYYY-MM-DD')   AS DATE_OF_BIRTH,
            nationality                      AS NATIONALITY,
            DW_FILE_NAME                     AS DW_SOURCE_FILE
        FROM F1_DB.RAW.RAW_DRIVERS
        WHERE TRY_TO_NUMBER(driverId) IS NOT NULL
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY TRY_TO_NUMBER(driverId)
            ORDER BY DW_LOADED_AT DESC, DW_FILE_ROW_NUMBER DESC
        ) = 1
    )
    SELECT typed.*,
        SHA2(CONCAT_WS('||',
            COALESCE(DRIVER_REF, '~'), COALESCE(PERMANENT_NUMBER::VARCHAR, '~'),
            COALESCE(DRIVER_CODE, '~'), COALESCE(FORENAME, '~'),
            COALESCE(SURNAME, '~'), COALESCE(DATE_OF_BIRTH::VARCHAR, '~'),
            COALESCE(NATIONALITY, '~')
        ), 256) AS ROW_HASH
    FROM typed
) AS src
ON tgt.DRIVER_ID = src.DRIVER_ID
WHEN MATCHED AND tgt.ROW_HASH <> src.ROW_HASH THEN UPDATE SET
    tgt.DRIVER_REF = src.DRIVER_REF, tgt.PERMANENT_NUMBER = src.PERMANENT_NUMBER,
    tgt.DRIVER_CODE = src.DRIVER_CODE, tgt.FORENAME = src.FORENAME,
    tgt.SURNAME = src.SURNAME, tgt.FULL_NAME = src.FULL_NAME,
    tgt.DATE_OF_BIRTH = src.DATE_OF_BIRTH, tgt.NATIONALITY = src.NATIONALITY,
    tgt.ROW_HASH = src.ROW_HASH, tgt.DW_SOURCE_FILE = src.DW_SOURCE_FILE,
    tgt.DW_UPDATED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    DRIVER_ID, DRIVER_REF, PERMANENT_NUMBER, DRIVER_CODE, FORENAME, SURNAME,
    FULL_NAME, DATE_OF_BIRTH, NATIONALITY, ROW_HASH, DW_SOURCE_FILE
) VALUES (
    src.DRIVER_ID, src.DRIVER_REF, src.PERMANENT_NUMBER, src.DRIVER_CODE,
    src.FORENAME, src.SURNAME, src.FULL_NAME, src.DATE_OF_BIRTH,
    src.NATIONALITY, src.ROW_HASH, src.DW_SOURCE_FILE
);

-- 2.4 Status -----------------------------------------------------------------
/* IS_CLASSIFIED_FINISH is derived, not sourced. statusId 1 is "Finished" and
   the "+N Lap(s)" statuses are also classified finishes; everything else is a
   retirement or disqualification. Encoding that here means every downstream
   reliability metric shares one definition instead of re-deriving it. */
MERGE INTO STG_STATUS AS tgt
USING (
    WITH typed AS (
        SELECT
            TRY_TO_NUMBER(statusId) AS STATUS_ID,
            status                  AS STATUS_DESCRIPTION,
            (TRY_TO_NUMBER(statusId) = 1 OR status ILIKE '+%Lap%') AS IS_CLASSIFIED_FINISH,
            DW_FILE_NAME            AS DW_SOURCE_FILE
        FROM F1_DB.RAW.RAW_STATUS
        WHERE TRY_TO_NUMBER(statusId) IS NOT NULL
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY TRY_TO_NUMBER(statusId)
            ORDER BY DW_LOADED_AT DESC, DW_FILE_ROW_NUMBER DESC
        ) = 1
    )
    SELECT typed.*,
        SHA2(CONCAT_WS('||',
            COALESCE(STATUS_DESCRIPTION, '~'),
            COALESCE(IS_CLASSIFIED_FINISH::VARCHAR, '~')
        ), 256) AS ROW_HASH
    FROM typed
) AS src
ON tgt.STATUS_ID = src.STATUS_ID
WHEN MATCHED AND tgt.ROW_HASH <> src.ROW_HASH THEN UPDATE SET
    tgt.STATUS_DESCRIPTION = src.STATUS_DESCRIPTION,
    tgt.IS_CLASSIFIED_FINISH = src.IS_CLASSIFIED_FINISH,
    tgt.ROW_HASH = src.ROW_HASH, tgt.DW_SOURCE_FILE = src.DW_SOURCE_FILE,
    tgt.DW_UPDATED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    STATUS_ID, STATUS_DESCRIPTION, IS_CLASSIFIED_FINISH, ROW_HASH, DW_SOURCE_FILE
) VALUES (
    src.STATUS_ID, src.STATUS_DESCRIPTION, src.IS_CLASSIFIED_FINISH,
    src.ROW_HASH, src.DW_SOURCE_FILE
);

-- 2.5 Races ------------------------------------------------------------------
MERGE INTO STG_RACE AS tgt
USING (
    WITH typed AS (
        SELECT
            TRY_TO_NUMBER(raceId)            AS RACE_ID,
            TRY_TO_NUMBER(year)              AS SEASON_YEAR,
            TRY_TO_NUMBER(round)             AS ROUND_NUMBER,
            TRY_TO_NUMBER(circuitId)         AS CIRCUIT_ID,
            name                             AS RACE_NAME,
            TRY_TO_DATE(date, 'YYYY-MM-DD')  AS RACE_DATE,
            TRY_TO_TIME(time, 'HH24:MI:SS')  AS RACE_START_UTC,
            DW_FILE_NAME                     AS DW_SOURCE_FILE
        FROM F1_DB.RAW.RAW_RACES
        WHERE TRY_TO_NUMBER(raceId) IS NOT NULL
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY TRY_TO_NUMBER(raceId)
            ORDER BY DW_LOADED_AT DESC, DW_FILE_ROW_NUMBER DESC
        ) = 1
    )
    SELECT typed.*,
        SHA2(CONCAT_WS('||',
            COALESCE(SEASON_YEAR::VARCHAR, '~'), COALESCE(ROUND_NUMBER::VARCHAR, '~'),
            COALESCE(CIRCUIT_ID::VARCHAR, '~'),  COALESCE(RACE_NAME, '~'),
            COALESCE(RACE_DATE::VARCHAR, '~'),   COALESCE(RACE_START_UTC::VARCHAR, '~')
        ), 256) AS ROW_HASH
    FROM typed
) AS src
ON tgt.RACE_ID = src.RACE_ID
WHEN MATCHED AND tgt.ROW_HASH <> src.ROW_HASH THEN UPDATE SET
    tgt.SEASON_YEAR = src.SEASON_YEAR, tgt.ROUND_NUMBER = src.ROUND_NUMBER,
    tgt.CIRCUIT_ID = src.CIRCUIT_ID, tgt.RACE_NAME = src.RACE_NAME,
    tgt.RACE_DATE = src.RACE_DATE, tgt.RACE_START_UTC = src.RACE_START_UTC,
    tgt.ROW_HASH = src.ROW_HASH, tgt.DW_SOURCE_FILE = src.DW_SOURCE_FILE,
    tgt.DW_UPDATED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    RACE_ID, SEASON_YEAR, ROUND_NUMBER, CIRCUIT_ID, RACE_NAME, RACE_DATE,
    RACE_START_UTC, ROW_HASH, DW_SOURCE_FILE
) VALUES (
    src.RACE_ID, src.SEASON_YEAR, src.ROUND_NUMBER, src.CIRCUIT_ID,
    src.RACE_NAME, src.RACE_DATE, src.RACE_START_UTC, src.ROW_HASH,
    src.DW_SOURCE_FILE
);

-- 2.6 Race results -----------------------------------------------------------
/* Two source conventions worth knowing before reading the CAST list:
     - position is \N for any car that did not finish; positionText carries
       'R', 'D', 'W' etc. We keep FINISH_POSITION strictly numeric and let
       STATUS_ID explain absence. POSITION_ORDER remains dense for sorting.
     - grid = 0 means a pit-lane start, not "pole". It is preserved as 0 and
       interpreted, not silently converted, in the analytics layer. */
MERGE INTO STG_RACE_RESULT AS tgt
USING (
    WITH typed AS (
        SELECT
            TRY_TO_NUMBER(resultId)          AS RESULT_ID,
            TRY_TO_NUMBER(raceId)            AS RACE_ID,
            TRY_TO_NUMBER(driverId)          AS DRIVER_ID,
            TRY_TO_NUMBER(constructorId)     AS CONSTRUCTOR_ID,
            TRY_TO_NUMBER(statusId)          AS STATUS_ID,
            TRY_TO_NUMBER(number)            AS CAR_NUMBER,
            TRY_TO_NUMBER(grid)              AS GRID_POSITION,
            TRY_TO_NUMBER(position)          AS FINISH_POSITION,
            TRY_TO_NUMBER(positionOrder)     AS POSITION_ORDER,
            TRY_TO_DECIMAL(points, 8, 2)     AS POINTS,
            TRY_TO_NUMBER(laps)              AS LAPS_COMPLETED,
            TRY_TO_NUMBER(milliseconds)      AS RACE_DURATION_MS,
            TRY_TO_NUMBER(fastestLap)        AS FASTEST_LAP_NUMBER,
            TRY_TO_NUMBER(rank)              AS FASTEST_LAP_RANK,
            FN_DURATION_TO_MS(fastestLapTime) AS FASTEST_LAP_MS,
            TRY_TO_DOUBLE(fastestLapSpeed)   AS FASTEST_LAP_SPEED_KPH,
            DW_FILE_NAME                     AS DW_SOURCE_FILE
        FROM F1_DB.RAW.RAW_RESULTS
        WHERE TRY_TO_NUMBER(resultId) IS NOT NULL
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY TRY_TO_NUMBER(resultId)
            ORDER BY DW_LOADED_AT DESC, DW_FILE_ROW_NUMBER DESC
        ) = 1
    )
    SELECT typed.*,
        SHA2(CONCAT_WS('||',
            COALESCE(RACE_ID::VARCHAR, '~'), COALESCE(DRIVER_ID::VARCHAR, '~'),
            COALESCE(CONSTRUCTOR_ID::VARCHAR, '~'), COALESCE(STATUS_ID::VARCHAR, '~'),
            COALESCE(GRID_POSITION::VARCHAR, '~'), COALESCE(FINISH_POSITION::VARCHAR, '~'),
            COALESCE(POSITION_ORDER::VARCHAR, '~'), COALESCE(POINTS::VARCHAR, '~'),
            COALESCE(LAPS_COMPLETED::VARCHAR, '~'), COALESCE(RACE_DURATION_MS::VARCHAR, '~'),
            COALESCE(FASTEST_LAP_MS::VARCHAR, '~')
        ), 256) AS ROW_HASH
    FROM typed
) AS src
ON tgt.RESULT_ID = src.RESULT_ID
WHEN MATCHED AND tgt.ROW_HASH <> src.ROW_HASH THEN UPDATE SET
    tgt.RACE_ID = src.RACE_ID, tgt.DRIVER_ID = src.DRIVER_ID,
    tgt.CONSTRUCTOR_ID = src.CONSTRUCTOR_ID, tgt.STATUS_ID = src.STATUS_ID,
    tgt.CAR_NUMBER = src.CAR_NUMBER, tgt.GRID_POSITION = src.GRID_POSITION,
    tgt.FINISH_POSITION = src.FINISH_POSITION, tgt.POSITION_ORDER = src.POSITION_ORDER,
    tgt.POINTS = src.POINTS, tgt.LAPS_COMPLETED = src.LAPS_COMPLETED,
    tgt.RACE_DURATION_MS = src.RACE_DURATION_MS,
    tgt.FASTEST_LAP_NUMBER = src.FASTEST_LAP_NUMBER,
    tgt.FASTEST_LAP_RANK = src.FASTEST_LAP_RANK,
    tgt.FASTEST_LAP_MS = src.FASTEST_LAP_MS,
    tgt.FASTEST_LAP_SPEED_KPH = src.FASTEST_LAP_SPEED_KPH,
    tgt.ROW_HASH = src.ROW_HASH, tgt.DW_SOURCE_FILE = src.DW_SOURCE_FILE,
    tgt.DW_UPDATED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    RESULT_ID, RACE_ID, DRIVER_ID, CONSTRUCTOR_ID, STATUS_ID, CAR_NUMBER,
    GRID_POSITION, FINISH_POSITION, POSITION_ORDER, POINTS, LAPS_COMPLETED,
    RACE_DURATION_MS, FASTEST_LAP_NUMBER, FASTEST_LAP_RANK, FASTEST_LAP_MS,
    FASTEST_LAP_SPEED_KPH, ROW_HASH, DW_SOURCE_FILE
) VALUES (
    src.RESULT_ID, src.RACE_ID, src.DRIVER_ID, src.CONSTRUCTOR_ID, src.STATUS_ID,
    src.CAR_NUMBER, src.GRID_POSITION, src.FINISH_POSITION, src.POSITION_ORDER,
    src.POINTS, src.LAPS_COMPLETED, src.RACE_DURATION_MS, src.FASTEST_LAP_NUMBER,
    src.FASTEST_LAP_RANK, src.FASTEST_LAP_MS, src.FASTEST_LAP_SPEED_KPH,
    src.ROW_HASH, src.DW_SOURCE_FILE
);

-- 2.7 Pit stops --------------------------------------------------------------
/* DURATION_MS prefers the source milliseconds column and falls back to parsing
   the display duration, because early seasons populate only one of the two. */
MERGE INTO STG_PIT_STOP AS tgt
USING (
    WITH typed AS (
        SELECT
            SHA2(CONCAT_WS('||', raceId, driverId, stop), 256) AS PIT_STOP_KEY,
            TRY_TO_NUMBER(raceId)           AS RACE_ID,
            TRY_TO_NUMBER(driverId)         AS DRIVER_ID,
            TRY_TO_NUMBER(stop)             AS STOP_NUMBER,
            TRY_TO_NUMBER(lap)              AS LAP_NUMBER,
            TRY_TO_TIME(time, 'HH24:MI:SS') AS STOP_TIME_LOCAL,
            COALESCE(TRY_TO_NUMBER(milliseconds), FN_DURATION_TO_MS(duration)) AS DURATION_MS,
            DW_FILE_NAME                    AS DW_SOURCE_FILE
        FROM F1_DB.RAW.RAW_PIT_STOPS
        WHERE TRY_TO_NUMBER(raceId) IS NOT NULL
          AND TRY_TO_NUMBER(driverId) IS NOT NULL
          AND TRY_TO_NUMBER(stop) IS NOT NULL
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY SHA2(CONCAT_WS('||', raceId, driverId, stop), 256)
            ORDER BY DW_LOADED_AT DESC, DW_FILE_ROW_NUMBER DESC
        ) = 1
    )
    SELECT typed.*,
        SHA2(CONCAT_WS('||',
            COALESCE(LAP_NUMBER::VARCHAR, '~'),
            COALESCE(STOP_TIME_LOCAL::VARCHAR, '~'),
            COALESCE(DURATION_MS::VARCHAR, '~')
        ), 256) AS ROW_HASH
    FROM typed
) AS src
ON tgt.PIT_STOP_KEY = src.PIT_STOP_KEY
WHEN MATCHED AND tgt.ROW_HASH <> src.ROW_HASH THEN UPDATE SET
    tgt.LAP_NUMBER = src.LAP_NUMBER, tgt.STOP_TIME_LOCAL = src.STOP_TIME_LOCAL,
    tgt.DURATION_MS = src.DURATION_MS, tgt.ROW_HASH = src.ROW_HASH,
    tgt.DW_SOURCE_FILE = src.DW_SOURCE_FILE,
    tgt.DW_UPDATED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    PIT_STOP_KEY, RACE_ID, DRIVER_ID, STOP_NUMBER, LAP_NUMBER,
    STOP_TIME_LOCAL, DURATION_MS, ROW_HASH, DW_SOURCE_FILE
) VALUES (
    src.PIT_STOP_KEY, src.RACE_ID, src.DRIVER_ID, src.STOP_NUMBER,
    src.LAP_NUMBER, src.STOP_TIME_LOCAL, src.DURATION_MS, src.ROW_HASH,
    src.DW_SOURCE_FILE
);

/* ----------------------------------------------------------------------------
   VERIFICATION

   Re-run this whole script immediately. Every MERGE should report 0 inserted
   and 0 updated. That is the idempotency proof, and it is worth screenshotting.
   ---------------------------------------------------------------------------- */
SELECT 'STG_CIRCUIT' AS tbl, COUNT(*) AS row_count, MAX(DW_UPDATED_AT) AS last_change FROM STG_CIRCUIT
UNION ALL SELECT 'STG_CONSTRUCTOR', COUNT(*), MAX(DW_UPDATED_AT) FROM STG_CONSTRUCTOR
UNION ALL SELECT 'STG_DRIVER',      COUNT(*), MAX(DW_UPDATED_AT) FROM STG_DRIVER
UNION ALL SELECT 'STG_STATUS',      COUNT(*), MAX(DW_UPDATED_AT) FROM STG_STATUS
UNION ALL SELECT 'STG_RACE',        COUNT(*), MAX(DW_UPDATED_AT) FROM STG_RACE
UNION ALL SELECT 'STG_RACE_RESULT', COUNT(*), MAX(DW_UPDATED_AT) FROM STG_RACE_RESULT
UNION ALL SELECT 'STG_PIT_STOP',    COUNT(*), MAX(DW_UPDATED_AT) FROM STG_PIT_STOP
ORDER BY tbl;

-- Referential integrity is not enforced by constraints in Snowflake, so check it.
SELECT COUNT(*) AS orphan_results
FROM STG_RACE_RESULT r
LEFT JOIN STG_RACE ra ON r.RACE_ID = ra.RACE_ID
WHERE ra.RACE_ID IS NULL;
