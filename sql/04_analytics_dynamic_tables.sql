/* ============================================================================
   04_analytics_dynamic_tables.sql

   Purpose     : Dimensional model as dynamic tables, plus presentation views.
   Run as      : FR_F1_ENGINEER
   Idempotent  : Yes.
   Depends on  : 03_staging_merge.sql

   -- The central design decision in this file --------------------------------

   Every dynamic table below is a single-source projection: one FROM clause,
   no joins, no window functions, no non-deterministic expressions. Joins and
   analytics live in the views underneath.

   This is not stylistic. A dynamic table declares REFRESH_MODE = AUTO by
   default and silently degrades to FULL refresh when its query contains
   constructs it cannot maintain incrementally. A full refresh recomputes the
   entire table on every schedule tick, which quietly converts an incremental
   pipeline into an expensive polling loop that still looks correct.

   Two safeguards:
     - REFRESH_MODE = INCREMENTAL is set explicitly. If Snowflake cannot honour
       it for a given query, CREATE fails immediately rather than degrading in
       production six months later.
     - Keeping the queries trivially incrementalisable means that constraint is
       never binding.

   The cost of this choice is that consumers join at query time. On a star this
   small that is free, and the views make it invisible. On a genuinely large
   model you would materialise selected joins as a second dynamic table layer
   with TARGET_LAG = 'DOWNSTREAM' and accept the refresh-mode analysis that
   comes with it.
   ============================================================================ */

USE ROLE FR_F1_ENGINEER;
USE WAREHOUSE WH_F1_TRANSFORM;
USE DATABASE F1_DB;
USE SCHEMA ANALYTICS;

/* ============================================================================
   1. DIMENSIONS
   ============================================================================ */

CREATE OR REPLACE DYNAMIC TABLE DIM_DRIVER
    TARGET_LAG   = '60 minutes'
    WAREHOUSE    = WH_F1_TRANSFORM
    REFRESH_MODE = INCREMENTAL
    INITIALIZE   = ON_CREATE
    COMMENT      = 'One row per driver. Type 1 — no history retained.'
AS
SELECT
    DRIVER_ID,
    DRIVER_REF,
    DRIVER_CODE,
    PERMANENT_NUMBER,
    FORENAME,
    SURNAME,
    FULL_NAME,
    DATE_OF_BIRTH,
    NATIONALITY
FROM F1_DB.STAGING.STG_DRIVER;

CREATE OR REPLACE DYNAMIC TABLE DIM_CONSTRUCTOR
    TARGET_LAG   = '60 minutes'
    WAREHOUSE    = WH_F1_TRANSFORM
    REFRESH_MODE = INCREMENTAL
    INITIALIZE   = ON_CREATE
    COMMENT      = 'One row per constructor. Type 1.'
AS
SELECT
    CONSTRUCTOR_ID,
    CONSTRUCTOR_REF,
    CONSTRUCTOR_NAME,
    NATIONALITY
FROM F1_DB.STAGING.STG_CONSTRUCTOR;

CREATE OR REPLACE DYNAMIC TABLE DIM_CIRCUIT
    TARGET_LAG   = '60 minutes'
    WAREHOUSE    = WH_F1_TRANSFORM
    REFRESH_MODE = INCREMENTAL
    INITIALIZE   = ON_CREATE
    COMMENT      = 'One row per circuit, with geography for map rendering.'
AS
SELECT
    CIRCUIT_ID,
    CIRCUIT_REF,
    CIRCUIT_NAME,
    LOCATION,
    COUNTRY,
    LATITUDE,
    LONGITUDE,
    ALTITUDE_M
FROM F1_DB.STAGING.STG_CIRCUIT;

CREATE OR REPLACE DYNAMIC TABLE DIM_RACE
    TARGET_LAG   = '60 minutes'
    WAREHOUSE    = WH_F1_TRANSFORM
    REFRESH_MODE = INCREMENTAL
    INITIALIZE   = ON_CREATE
    COMMENT      = 'One row per race. Doubles as the date spine for the model.'
AS
SELECT
    RACE_ID,
    SEASON_YEAR,
    ROUND_NUMBER,
    CIRCUIT_ID,
    RACE_NAME,
    RACE_DATE,
    RACE_START_UTC,
    DATE_PART('month', RACE_DATE)   AS RACE_MONTH,
    DAYNAME(RACE_DATE)              AS RACE_DAY_NAME
FROM F1_DB.STAGING.STG_RACE;

CREATE OR REPLACE DYNAMIC TABLE DIM_STATUS
    TARGET_LAG   = '60 minutes'
    WAREHOUSE    = WH_F1_TRANSFORM
    REFRESH_MODE = INCREMENTAL
    INITIALIZE   = ON_CREATE
    COMMENT      = 'Race outcome codes, with the classified-finish flag.'
AS
SELECT
    STATUS_ID,
    STATUS_DESCRIPTION,
    IS_CLASSIFIED_FINISH,
    CASE
        WHEN IS_CLASSIFIED_FINISH                       THEN 'Classified'
        WHEN STATUS_DESCRIPTION ILIKE '%Disqualified%'  THEN 'Disqualified'
        WHEN STATUS_DESCRIPTION ILIKE '%Accident%'
          OR STATUS_DESCRIPTION ILIKE '%Collision%'
          OR STATUS_DESCRIPTION ILIKE '%Spun off%'      THEN 'Incident'
        WHEN STATUS_DESCRIPTION ILIKE '%Withdrew%'
          OR STATUS_DESCRIPTION ILIKE '%Did not%'       THEN 'Did not start'
        ELSE 'Mechanical'
    END AS RETIREMENT_CATEGORY
FROM F1_DB.STAGING.STG_STATUS;

/* RETIREMENT_CATEGORY collapses ~140 granular status codes into five buckets.
   The mechanical bucket is the residual, which is the honest way round: an
   unrecognised new status is counted as a car failure rather than being
   silently dropped from reliability metrics. */

/* ============================================================================
   2. FACTS

   Facts hold foreign keys and measures only. No descriptive attributes are
   denormalised in, which is what keeps these tables incrementally refreshable
   and what stops a driver rename from rewriting sixty years of results.
   ============================================================================ */

CREATE OR REPLACE DYNAMIC TABLE FCT_RACE_RESULT
    TARGET_LAG   = '60 minutes'
    WAREHOUSE    = WH_F1_TRANSFORM
    REFRESH_MODE = INCREMENTAL
    INITIALIZE   = ON_CREATE
    COMMENT      = 'Grain: one row per driver per race entry.'
AS
SELECT
    RESULT_ID,
    RACE_ID,
    DRIVER_ID,
    CONSTRUCTOR_ID,
    STATUS_ID,
    GRID_POSITION,
    FINISH_POSITION,
    POSITION_ORDER,
    POINTS,
    LAPS_COMPLETED,
    RACE_DURATION_MS,
    FASTEST_LAP_MS,
    FASTEST_LAP_SPEED_KPH,
    -- Derived measures, kept here because they are row-local and deterministic.
    CASE WHEN GRID_POSITION = 0 THEN TRUE ELSE FALSE END AS IS_PIT_LANE_START,
    CASE
        WHEN GRID_POSITION IS NULL OR GRID_POSITION = 0 OR FINISH_POSITION IS NULL
            THEN NULL
        ELSE GRID_POSITION - FINISH_POSITION
    END AS POSITIONS_GAINED,
    CASE WHEN FINISH_POSITION = 1 THEN 1 ELSE 0 END AS IS_WIN,
    CASE WHEN FINISH_POSITION <= 3 THEN 1 ELSE 0 END AS IS_PODIUM
FROM F1_DB.STAGING.STG_RACE_RESULT;

/* POSITIONS_GAINED is NULL rather than 0 when the driver started from the pit
   lane or failed to finish. Encoding "not applicable" as zero would drag every
   average toward the middle and make the metric quietly wrong. */

CREATE OR REPLACE DYNAMIC TABLE FCT_PIT_STOP
    TARGET_LAG   = '60 minutes'
    WAREHOUSE    = WH_F1_TRANSFORM
    REFRESH_MODE = INCREMENTAL
    INITIALIZE   = ON_CREATE
    COMMENT      = 'Grain: one row per pit stop.'
AS
SELECT
    PIT_STOP_KEY,
    RACE_ID,
    DRIVER_ID,
    STOP_NUMBER,
    LAP_NUMBER,
    DURATION_MS,
    ROUND(DURATION_MS / 1000.0, 3) AS DURATION_SECONDS
FROM F1_DB.STAGING.STG_PIT_STOP
WHERE DURATION_MS IS NOT NULL
  AND DURATION_MS BETWEEN 1000 AND 300000;

/* The duration filter removes timing-feed artefacts: sub-second values that
   are impossible, and multi-minute values that are garage repairs rather than
   pit stops. Both would dominate any average. Excluded rows remain visible in
   STAGING, so the filter is a presentation decision, not data loss. */

/* ============================================================================
   3. PRESENTATION VIEWS

   The joins and window functions live here. Views are evaluated at query time,
   so they carry no refresh cost and no incremental-refresh constraint.
   ============================================================================ */

/* ----------------------------------------------------------------------------
   3.1 Wide result view — the workhorse join across five dimensions.
   ---------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW V_RACE_RESULT AS
SELECT
    f.RESULT_ID,
    r.SEASON_YEAR,
    r.ROUND_NUMBER,
    r.RACE_NAME,
    r.RACE_DATE,
    c.CIRCUIT_NAME,
    c.COUNTRY            AS CIRCUIT_COUNTRY,
    c.LATITUDE,
    c.LONGITUDE,
    d.DRIVER_ID,
    d.FULL_NAME          AS DRIVER_NAME,
    d.DRIVER_CODE,
    d.NATIONALITY        AS DRIVER_NATIONALITY,
    t.CONSTRUCTOR_ID,
    t.CONSTRUCTOR_NAME,
    s.STATUS_DESCRIPTION,
    s.IS_CLASSIFIED_FINISH,
    s.RETIREMENT_CATEGORY,
    f.GRID_POSITION,
    f.FINISH_POSITION,
    f.POSITION_ORDER,
    f.POINTS,
    f.LAPS_COMPLETED,
    f.POSITIONS_GAINED,
    f.IS_PIT_LANE_START,
    f.IS_WIN,
    f.IS_PODIUM,
    f.FASTEST_LAP_MS,
    f.FASTEST_LAP_SPEED_KPH
FROM FCT_RACE_RESULT f
JOIN DIM_RACE        r ON f.RACE_ID        = r.RACE_ID
JOIN DIM_CIRCUIT     c ON r.CIRCUIT_ID     = c.CIRCUIT_ID
JOIN DIM_DRIVER      d ON f.DRIVER_ID      = d.DRIVER_ID
JOIN DIM_CONSTRUCTOR t ON f.CONSTRUCTOR_ID = t.CONSTRUCTOR_ID
LEFT JOIN DIM_STATUS s ON f.STATUS_ID      = s.STATUS_ID;

/* DIM_STATUS is LEFT joined alone: a result whose status code is missing from
   the lookup must still appear in the standings. The other four are inner
   joins because a result without a race, driver or constructor is corrupt and
   should surface as a row-count discrepancy, not be silently accepted. */

/* ----------------------------------------------------------------------------
   3.2 Championship progression — the dashboard's primary insight.

   SUM(...) OVER (PARTITION BY driver, season ORDER BY round) is the running
   championship total after each round. RANK over the same frame gives the
   standings position at that point in the season, which is what makes the
   chart a title race rather than a bar chart of season totals.
   ---------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW V_DRIVER_SEASON_PROGRESSION AS
WITH per_round AS (
    SELECT
        SEASON_YEAR,
        ROUND_NUMBER,
        RACE_NAME,
        RACE_DATE,
        DRIVER_ID,
        DRIVER_NAME,
        DRIVER_CODE,
        CONSTRUCTOR_NAME,
        SUM(POINTS)      AS ROUND_POINTS,
        MIN(FINISH_POSITION) AS FINISH_POSITION
    FROM V_RACE_RESULT
    GROUP BY ALL
)
SELECT
    SEASON_YEAR,
    ROUND_NUMBER,
    RACE_NAME,
    RACE_DATE,
    DRIVER_ID,
    DRIVER_NAME,
    DRIVER_CODE,
    CONSTRUCTOR_NAME,
    ROUND_POINTS,
    FINISH_POSITION,
    SUM(ROUND_POINTS) OVER (
        PARTITION BY SEASON_YEAR, DRIVER_ID
        ORDER BY ROUND_NUMBER
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS CUMULATIVE_POINTS,
    RANK() OVER (
        PARTITION BY SEASON_YEAR, ROUND_NUMBER
        ORDER BY SUM(ROUND_POINTS) OVER (
            PARTITION BY SEASON_YEAR, DRIVER_ID
            ORDER BY ROUND_NUMBER
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) DESC
    ) AS CHAMPIONSHIP_POSITION,
    LAG(FINISH_POSITION) OVER (
        PARTITION BY SEASON_YEAR, DRIVER_ID ORDER BY ROUND_NUMBER
    ) AS PREVIOUS_ROUND_FINISH
FROM per_round;

/* A driver who misses a round has no row for it, so the running total carries
   forward on their next appearance rather than resetting. That is the correct
   championship semantic and it comes free from the frame definition. */

/* ----------------------------------------------------------------------------
   3.3 Pit stop performance — the dashboard's second insight.
   ---------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW V_CONSTRUCTOR_PIT_PERFORMANCE AS
WITH stops AS (
    SELECT
        r.SEASON_YEAR,
        t.CONSTRUCTOR_ID,
        t.CONSTRUCTOR_NAME,
        p.DURATION_SECONDS
    FROM FCT_PIT_STOP p
    JOIN DIM_RACE r ON p.RACE_ID = r.RACE_ID
    JOIN FCT_RACE_RESULT f
         ON p.RACE_ID = f.RACE_ID AND p.DRIVER_ID = f.DRIVER_ID
    JOIN DIM_CONSTRUCTOR t ON f.CONSTRUCTOR_ID = t.CONSTRUCTOR_ID
)
SELECT
    SEASON_YEAR,
    CONSTRUCTOR_ID,
    CONSTRUCTOR_NAME,
    COUNT(*)                    AS STOP_COUNT,
    ROUND(MEDIAN(DURATION_SECONDS), 3) AS MEDIAN_STOP_SECONDS,
    ROUND(AVG(DURATION_SECONDS), 3)    AS MEAN_STOP_SECONDS,
    ROUND(MIN(DURATION_SECONDS), 3)    AS FASTEST_STOP_SECONDS,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY DURATION_SECONDS), 3)
                                AS P90_STOP_SECONDS,
    RANK() OVER (
        PARTITION BY SEASON_YEAR ORDER BY MEDIAN(DURATION_SECONDS)
    ) AS SEASON_RANK,
    ROUND(
        MEDIAN(DURATION_SECONDS)
        - AVG(MEDIAN(DURATION_SECONDS)) OVER (PARTITION BY SEASON_YEAR),
    3) AS SECONDS_VS_FIELD_MEDIAN
FROM stops
GROUP BY SEASON_YEAR, CONSTRUCTOR_ID, CONSTRUCTOR_NAME
HAVING COUNT(*) >= 10;

/* Median rather than mean: a single 40-second stop for a front-wing change
   moves the mean of a 20-stop season by two seconds and tells you nothing
   about crew performance. P90 is carried alongside so the tail stays visible
   rather than being hidden by the choice of a robust central estimate.

   HAVING COUNT(*) >= 10 suppresses constructors with too few stops in a season
   to rank meaningfully. */

/* ----------------------------------------------------------------------------
   3.4 Reliability — supporting metric.
   ---------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW V_CONSTRUCTOR_RELIABILITY AS
SELECT
    SEASON_YEAR,
    CONSTRUCTOR_NAME,
    COUNT(*)                                          AS ENTRIES,
    SUM(IFF(IS_CLASSIFIED_FINISH, 1, 0))              AS CLASSIFIED_FINISHES,
    ROUND(100.0 * SUM(IFF(IS_CLASSIFIED_FINISH, 1, 0)) / NULLIF(COUNT(*), 0), 1)
                                                      AS FINISH_RATE_PCT,
    SUM(IFF(RETIREMENT_CATEGORY = 'Mechanical', 1, 0)) AS MECHANICAL_DNFS,
    SUM(IFF(RETIREMENT_CATEGORY = 'Incident', 1, 0))   AS INCIDENT_DNFS,
    SUM(POINTS)                                        AS SEASON_POINTS
FROM V_RACE_RESULT
GROUP BY SEASON_YEAR, CONSTRUCTOR_NAME;

/* ----------------------------------------------------------------------------
   3.5 Season index — populates the dashboard's season selector cheaply.
   ---------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW V_SEASON_SUMMARY AS
SELECT
    SEASON_YEAR,
    COUNT(DISTINCT RACE_NAME)       AS ROUNDS,
    COUNT(DISTINCT DRIVER_ID)       AS DRIVERS,
    COUNT(DISTINCT CONSTRUCTOR_ID)  AS CONSTRUCTORS,
    MIN(RACE_DATE)                  AS SEASON_START,
    MAX(RACE_DATE)                  AS SEASON_END
FROM V_RACE_RESULT
GROUP BY SEASON_YEAR;

/* ----------------------------------------------------------------------------
   VERIFICATION
   ---------------------------------------------------------------------------- */

-- Confirm every dynamic table actually resolved to INCREMENTAL, not FULL.
SHOW DYNAMIC TABLES IN SCHEMA F1_DB.ANALYTICS;

SELECT NAME, TARGET_LAG_SEC, SCHEDULING_STATE, LAST_COMPLETED_REFRESH_STATE
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES())
ORDER BY NAME;

-- Sanity check the headline view.
SELECT SEASON_YEAR, DRIVER_NAME, CUMULATIVE_POINTS, CHAMPIONSHIP_POSITION
FROM V_DRIVER_SEASON_PROGRESSION
WHERE SEASON_YEAR = 2023
QUALIFY ROW_NUMBER() OVER (PARTITION BY DRIVER_ID ORDER BY ROUND_NUMBER DESC) = 1
ORDER BY CHAMPIONSHIP_POSITION
LIMIT 10;
