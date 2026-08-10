/* ============================================================================
   05_data_quality.sql

   Purpose     : Attach measurable, scheduled quality metrics to STAGING.
   Run as      : FR_F1_ENGINEER
   Requires    : Enterprise Edition. Grants issued in 00_account_setup.sql.
   Idempotent  : Yes — CREATE OR REPLACE, and DMF attachment is idempotent
                 except for re-adding an identical association, which errors
                 harmlessly. Section 5 provides the detach statements.
   Depends on  : 03_staging_merge.sql

   Why data metric functions rather than a hand-rolled checks table:

     - They are scheduled by Snowflake, so the check runs whether or not
       anyone remembered to call it after a load.
     - TRIGGER_ON_CHANGES fires on actual DML rather than on a clock, so a
       table that did not change is not re-measured and not re-billed.
     - Results land in one account-wide view, so quality history is queryable
       and trendable without building any of that infrastructure.

   Metrics are attached to STAGING, not ANALYTICS. STAGING is where correctness
   is asserted; by the time data reaches ANALYTICS it is assumed good. Measuring
   the layer you already trust tells you nothing you can act on.

   Note this configuration measures and records. It does not block. Deciding
   what a breach should halt is a production question — see the design notes.
   ============================================================================ */

USE ROLE FR_F1_ENGINEER;
USE WAREHOUSE WH_F1_TRANSFORM;
USE DATABASE F1_DB;
USE SCHEMA STAGING;

/* ============================================================================
   1. CUSTOM DATA METRIC FUNCTIONS

   Each takes a table argument and returns a single number: the count of rows
   violating one rule. One function, one rule — a metric that folds several
   checks into a single number cannot tell you which one broke.

   The body may only reference the table argument, which is what keeps a DMF
   cheap enough to run on every change.
   ============================================================================ */

CREATE OR REPLACE DATA METRIC FUNCTION DMF_GRID_POSITION_OUT_OF_RANGE(
    ARG_T TABLE(GRID_POSITION NUMBER)
)
RETURNS NUMBER
COMMENT = 'Grid slots outside 0..40. 0 is a legal pit-lane start, not an error.'
AS
$$
    SELECT COUNT(*)
    FROM ARG_T
    WHERE GRID_POSITION IS NOT NULL
      AND (GRID_POSITION < 0 OR GRID_POSITION > 40)
$$;

CREATE OR REPLACE DATA METRIC FUNCTION DMF_POINTS_OUT_OF_RANGE(
    ARG_T TABLE(POINTS NUMBER)
)
RETURNS NUMBER
COMMENT = 'Points outside 0..50 for a single entry. Catches decimal-shift and sign errors.'
AS
$$
    SELECT COUNT(*)
    FROM ARG_T
    WHERE POINTS IS NOT NULL
      AND (POINTS < 0 OR POINTS > 50)
$$;

CREATE OR REPLACE DATA METRIC FUNCTION DMF_IMPLAUSIBLE_PIT_DURATION(
    ARG_T TABLE(DURATION_MS NUMBER)
)
RETURNS NUMBER
COMMENT = 'Pit stops under 1s or over 5min — timing-feed artefacts, not stops.'
AS
$$
    SELECT COUNT(*)
    FROM ARG_T
    WHERE DURATION_MS IS NOT NULL
      AND (DURATION_MS < 1000 OR DURATION_MS > 300000)
$$;

/* ============================================================================
   2. SCHEDULES

   TRIGGER_ON_CHANGES rather than a fixed interval: these tables change only
   when a MERGE runs, and measuring an unchanged table burns credits to
   re-confirm yesterday's answer.

   The schedule is set before metrics are attached, so no metric is ever in an
   attached-but-unscheduled state.
   ============================================================================ */
ALTER TABLE STG_RACE_RESULT SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';
ALTER TABLE STG_DRIVER      SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';
ALTER TABLE STG_RACE        SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';
ALTER TABLE STG_PIT_STOP    SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';

/* ============================================================================
   3. ATTACH METRICS

   System DMFs live in SNOWFLAKE.CORE and cover the structural checks —
   uniqueness, completeness, volume. Custom DMFs cover the domain rules that
   no generic metric could know about.
   ============================================================================ */

-- 3.1 STG_RACE_RESULT — the central fact ------------------------------------
ALTER TABLE STG_RACE_RESULT
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.DUPLICATE_COUNT ON (RESULT_ID);

ALTER TABLE STG_RACE_RESULT
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (RACE_ID);

ALTER TABLE STG_RACE_RESULT
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (DRIVER_ID);

ALTER TABLE STG_RACE_RESULT
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (CONSTRUCTOR_ID);

ALTER TABLE STG_RACE_RESULT
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ();

ALTER TABLE STG_RACE_RESULT
    ADD DATA METRIC FUNCTION DMF_GRID_POSITION_OUT_OF_RANGE ON (GRID_POSITION);

ALTER TABLE STG_RACE_RESULT
    ADD DATA METRIC FUNCTION DMF_POINTS_OUT_OF_RANGE ON (POINTS);

/* NULL_COUNT on the three foreign keys is the closest available proxy for
   referential integrity, since Snowflake does not enforce FK constraints.
   True orphan detection needs a cross-table query, which a DMF body cannot
   perform — that check lives in section 4 instead. Knowing where the tool
   stops is part of using it correctly. */

-- 3.2 STG_DRIVER -------------------------------------------------------------
ALTER TABLE STG_DRIVER
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.DUPLICATE_COUNT ON (DRIVER_ID);

ALTER TABLE STG_DRIVER
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (FULL_NAME);

-- 3.3 STG_RACE ---------------------------------------------------------------
ALTER TABLE STG_RACE
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.DUPLICATE_COUNT ON (RACE_ID);

ALTER TABLE STG_RACE
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (SEASON_YEAR);

/* FRESHNESS answers "has anything arrived lately", which is the check that
   catches a pipeline that stopped running — the failure mode a row-count
   check cannot see, because a stalled pipeline leaves counts perfectly
   correct and perfectly stale. */
ALTER TABLE STG_RACE
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS ON (DW_UPDATED_AT);

-- 3.4 STG_PIT_STOP -----------------------------------------------------------
ALTER TABLE STG_PIT_STOP
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.DUPLICATE_COUNT ON (PIT_STOP_KEY);

ALTER TABLE STG_PIT_STOP
    ADD DATA METRIC FUNCTION DMF_IMPLAUSIBLE_PIT_DURATION ON (DURATION_MS);

/* ============================================================================
   4. CROSS-TABLE INTEGRITY

   What DMFs cannot express. A plain view, run on demand or wired to a task.
   ============================================================================ */
CREATE OR REPLACE VIEW V_REFERENTIAL_INTEGRITY_CHECK AS
SELECT 'STG_RACE_RESULT.RACE_ID -> STG_RACE'          AS relationship,
       COUNT(*)                                        AS orphan_count
FROM STG_RACE_RESULT f
LEFT JOIN STG_RACE d ON f.RACE_ID = d.RACE_ID
WHERE d.RACE_ID IS NULL
UNION ALL
SELECT 'STG_RACE_RESULT.DRIVER_ID -> STG_DRIVER',      COUNT(*)
FROM STG_RACE_RESULT f
LEFT JOIN STG_DRIVER d ON f.DRIVER_ID = d.DRIVER_ID
WHERE d.DRIVER_ID IS NULL
UNION ALL
SELECT 'STG_RACE_RESULT.CONSTRUCTOR_ID -> STG_CONSTRUCTOR', COUNT(*)
FROM STG_RACE_RESULT f
LEFT JOIN STG_CONSTRUCTOR d ON f.CONSTRUCTOR_ID = d.CONSTRUCTOR_ID
WHERE d.CONSTRUCTOR_ID IS NULL
UNION ALL
SELECT 'STG_RACE.CIRCUIT_ID -> STG_CIRCUIT',           COUNT(*)
FROM STG_RACE f
LEFT JOIN STG_CIRCUIT d ON f.CIRCUIT_ID = d.CIRCUIT_ID
WHERE d.CIRCUIT_ID IS NULL
UNION ALL
SELECT 'STG_PIT_STOP.RACE_ID -> STG_RACE',             COUNT(*)
FROM STG_PIT_STOP f
LEFT JOIN STG_RACE d ON f.RACE_ID = d.RACE_ID
WHERE d.RACE_ID IS NULL;

/* ============================================================================
   5. READING THE RESULTS

   Snowflake writes every measurement to SNOWFLAKE.LOCAL.DATA_QUALITY_
   MONITORING_RESULTS. Expect a delay of a few minutes after the first
   attachment before rows appear.
   ============================================================================ */
CREATE OR REPLACE VIEW V_DATA_QUALITY_LATEST AS
SELECT
    TABLE_NAME,
    METRIC_NAME,
    ARGUMENT_NAMES,
    VALUE          AS METRIC_VALUE,
    MEASUREMENT_TIME,
    CASE
        WHEN METRIC_NAME IN ('DUPLICATE_COUNT', 'NULL_COUNT') AND VALUE > 0 THEN 'BREACH'
        WHEN METRIC_NAME LIKE 'DMF_%'                          AND VALUE > 0 THEN 'BREACH'
        WHEN METRIC_NAME = 'ROW_COUNT'                         AND VALUE = 0 THEN 'BREACH'
        ELSE 'OK'
    END AS STATUS
FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
WHERE TABLE_DATABASE = 'F1_DB'
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY TABLE_NAME, METRIC_NAME, ARGUMENT_NAMES
    ORDER BY MEASUREMENT_TIME DESC
) = 1;

/* ----------------------------------------------------------------------------
   VERIFICATION — screenshot the first two for the submission.
   ---------------------------------------------------------------------------- */

-- Orphans across the model. Expected: all zero.
SELECT * FROM V_REFERENTIAL_INTEGRITY_CHECK ORDER BY relationship;

-- Latest value of every attached metric.
SELECT * FROM V_DATA_QUALITY_LATEST ORDER BY STATUS DESC, TABLE_NAME, METRIC_NAME;

-- What is attached where.
SELECT * FROM TABLE(INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
    REF_ENTITY_NAME   => 'F1_DB.STAGING.STG_RACE_RESULT',
    REF_ENTITY_DOMAIN => 'TABLE'
));

/* ----------------------------------------------------------------------------
   TEARDOWN — needed before dropping or replacing a table with metrics attached.
   Kept here because a script that cannot be undone is not finished.
   ----------------------------------------------------------------------------
ALTER TABLE STG_RACE_RESULT DROP DATA METRIC FUNCTION
    SNOWFLAKE.CORE.DUPLICATE_COUNT ON (RESULT_ID);
ALTER TABLE STG_RACE_RESULT UNSET DATA_METRIC_SCHEDULE;
   ---------------------------------------------------------------------------- */
