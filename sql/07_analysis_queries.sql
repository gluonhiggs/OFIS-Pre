/* ============================================================================
   07_analysis_queries.sql

   Purpose     : Demonstrate the analytics layer answers real questions.
   Run as      : FR_F1_ANALYST  (deliberately — proves least privilege works)
   Depends on  : 04_analytics_dynamic_tables.sql

   Run these as the analyst role, not the engineer role. If any query succeeds
   under FR_F1_ANALYST, the grant chain is correct. If one fails, the grant
   chain is wrong, and that is worth knowing before the dashboard is built on
   top of it.

   Queries are ordered by increasing analytical depth, not by importance.
   ============================================================================ */

USE ROLE FR_F1_ANALYST;
USE WAREHOUSE WH_F1_BI;
USE DATABASE F1_DB;
USE SCHEMA ANALYTICS;

/* ----------------------------------------------------------------------------
   Q1. Shape of the data. Always the first query against an unfamiliar model.
   ---------------------------------------------------------------------------- */
SELECT
    SEASON_YEAR,
    ROUNDS,
    DRIVERS,
    CONSTRUCTORS,
    SEASON_START,
    SEASON_END
FROM V_SEASON_SUMMARY
WHERE SEASON_YEAR >= 2015
ORDER BY SEASON_YEAR DESC;


/* ----------------------------------------------------------------------------
   Q2. Five-dimension join: one race, full classification.

   Reads as a single flat table because V_RACE_RESULT already resolves the
   star. The join is real — it is simply written once rather than by every
   consumer, which is the entire argument for a presentation layer.
   ---------------------------------------------------------------------------- */
SELECT
    FINISH_POSITION,
    DRIVER_NAME,
    CONSTRUCTOR_NAME,
    GRID_POSITION,
    POSITIONS_GAINED,
    POINTS,
    STATUS_DESCRIPTION
FROM V_RACE_RESULT
WHERE SEASON_YEAR = 2023
  AND RACE_NAME    = 'Monaco Grand Prix'
ORDER BY POSITION_ORDER;


/* ----------------------------------------------------------------------------
   Q3. Final championship standings for a season.

   QUALIFY filters on a window function without the CTE-plus-subquery
   scaffolding the same logic needs in most other dialects. Taking the last
   round per driver is what turns a progression table into a standings table.
   ---------------------------------------------------------------------------- */
SELECT
    CHAMPIONSHIP_POSITION,
    DRIVER_NAME,
    CONSTRUCTOR_NAME,
    CUMULATIVE_POINTS
FROM V_DRIVER_SEASON_PROGRESSION
WHERE SEASON_YEAR = 2023
QUALIFY ROW_NUMBER() OVER (PARTITION BY DRIVER_ID ORDER BY ROUND_NUMBER DESC) = 1
ORDER BY CHAMPIONSHIP_POSITION
LIMIT 20;


/* ----------------------------------------------------------------------------
   Q4. Title race margin, round by round.

   Two windows over the same partition: the running total, and the running
   total of whoever leads at that round. The difference is the gap — the
   number that decides whether a season was a contest or a procession.
   ---------------------------------------------------------------------------- */
WITH standings AS (
    SELECT
        ROUND_NUMBER,
        RACE_NAME,
        DRIVER_NAME,
        CUMULATIVE_POINTS,
        MAX(CUMULATIVE_POINTS) OVER (PARTITION BY ROUND_NUMBER) AS LEADER_POINTS
    FROM V_DRIVER_SEASON_PROGRESSION
    WHERE SEASON_YEAR = 2021
)
SELECT
    ROUND_NUMBER,
    RACE_NAME,
    DRIVER_NAME,
    CUMULATIVE_POINTS,
    LEADER_POINTS - CUMULATIVE_POINTS AS POINTS_BEHIND_LEADER
FROM standings
QUALIFY DENSE_RANK() OVER (PARTITION BY ROUND_NUMBER ORDER BY CUMULATIVE_POINTS DESC) <= 2
ORDER BY ROUND_NUMBER, CUMULATIVE_POINTS DESC;


/* ----------------------------------------------------------------------------
   Q5. Rolling form: average finishing position over the last five races.

   A sliding frame rather than an unbounded one. ROWS BETWEEN 4 PRECEDING AND
   CURRENT ROW is what distinguishes "recent form" from "season average", and
   the difference between the two is where a mid-season upturn shows up.
   ---------------------------------------------------------------------------- */
SELECT
    RACE_DATE,
    RACE_NAME,
    DRIVER_NAME,
    FINISH_POSITION,
    ROUND(AVG(FINISH_POSITION) OVER (
        PARTITION BY DRIVER_ID
        ORDER BY RACE_DATE
        ROWS BETWEEN 4 PRECEDING AND CURRENT ROW
    ), 2) AS FORM_LAST_5_RACES,
    COUNT(*) OVER (
        PARTITION BY DRIVER_ID
        ORDER BY RACE_DATE
        ROWS BETWEEN 4 PRECEDING AND CURRENT ROW
    ) AS RACES_IN_WINDOW
FROM V_RACE_RESULT
WHERE SEASON_YEAR = 2023
  AND FINISH_POSITION IS NOT NULL
ORDER BY DRIVER_NAME, RACE_DATE;

/* RACES_IN_WINDOW is carried so the first four rows per driver are visibly
   partial rather than being mistaken for genuine five-race form. */


/* ----------------------------------------------------------------------------
   Q6. Teammate comparison — the only fair driver-versus-driver measure,
   because it holds the car constant.

   Self-join on (race, constructor) with an inequality predicate to avoid
   pairing a driver with themselves and to emit each pairing once.
   ---------------------------------------------------------------------------- */
/* This one joins the fact table directly rather than V_RACE_RESULT. The view
   does not expose RACE_ID, and widening a presentation view to serve a single
   analytical query is how presentation layers turn into dumping grounds. */
WITH teammate_pairs AS (
    SELECT
        r.SEASON_YEAR,
        t.CONSTRUCTOR_NAME,
        da.FULL_NAME     AS DRIVER_A,
        db.FULL_NAME     AS DRIVER_B,
        fa.POSITION_ORDER AS POS_A,
        fb.POSITION_ORDER AS POS_B
    FROM FCT_RACE_RESULT fa
    JOIN FCT_RACE_RESULT fb
      ON  fa.RACE_ID        = fb.RACE_ID
      AND fa.CONSTRUCTOR_ID = fb.CONSTRUCTOR_ID
      AND fa.DRIVER_ID      < fb.DRIVER_ID          -- each pairing once
    JOIN DIM_RACE        r  ON fa.RACE_ID        = r.RACE_ID
    JOIN DIM_CONSTRUCTOR t  ON fa.CONSTRUCTOR_ID = t.CONSTRUCTOR_ID
    JOIN DIM_DRIVER      da ON fa.DRIVER_ID      = da.DRIVER_ID
    JOIN DIM_DRIVER      db ON fb.DRIVER_ID      = db.DRIVER_ID
    WHERE r.SEASON_YEAR = 2023
)
SELECT
    CONSTRUCTOR_NAME,
    DRIVER_A,
    DRIVER_B,
    COUNT(*)                              AS RACES_TOGETHER,
    SUM(IFF(POS_A < POS_B, 1, 0))         AS A_AHEAD,
    SUM(IFF(POS_B < POS_A, 1, 0))         AS B_AHEAD,
    ROUND(100.0 * SUM(IFF(POS_A < POS_B, 1, 0)) / NULLIF(COUNT(*), 0), 1) AS A_WIN_PCT
FROM teammate_pairs
GROUP BY CONSTRUCTOR_NAME, DRIVER_A, DRIVER_B
HAVING COUNT(*) >= 5
ORDER BY A_WIN_PCT DESC;


/* ----------------------------------------------------------------------------
   Q7. Pit crew performance and its spread.

   NTILE buckets the field; the median-versus-P90 gap says whether a crew is
   consistently quick or merely occasionally quick. Ranking on the median alone
   would rate those two identically.
   ---------------------------------------------------------------------------- */
SELECT
    CONSTRUCTOR_NAME,
    STOP_COUNT,
    MEDIAN_STOP_SECONDS,
    P90_STOP_SECONDS,
    ROUND(P90_STOP_SECONDS - MEDIAN_STOP_SECONDS, 3) AS CONSISTENCY_SPREAD,
    SEASON_RANK,
    SECONDS_VS_FIELD_MEDIAN,
    NTILE(4) OVER (ORDER BY MEDIAN_STOP_SECONDS) AS SPEED_QUARTILE
FROM V_CONSTRUCTOR_PIT_PERFORMANCE
WHERE SEASON_YEAR = 2023
ORDER BY SEASON_RANK;


/* ----------------------------------------------------------------------------
   Q8. Constructor points by season, pivoted.

   PIVOT with an explicit value list. The alternative — a dynamic pivot built
   by a procedure — is the right call when the column set is unknown, and the
   wrong call for five fixed seasons.
   ---------------------------------------------------------------------------- */
SELECT *
FROM (
    SELECT CONSTRUCTOR_NAME, SEASON_YEAR, SEASON_POINTS
    FROM V_CONSTRUCTOR_RELIABILITY
    WHERE SEASON_YEAR BETWEEN 2019 AND 2023
)
PIVOT (
    SUM(SEASON_POINTS) FOR SEASON_YEAR IN (2019, 2020, 2021, 2022, 2023)
) AS p (CONSTRUCTOR_NAME, "2019", "2020", "2021", "2022", "2023")
ORDER BY "2023" DESC NULLS LAST;


/* ----------------------------------------------------------------------------
   Q9. Reliability versus results.

   Correlating finish rate against points earned. The interesting rows are the
   ones off the diagonal: teams that finished everything and scored nothing,
   and teams that scored despite breaking down.
   ---------------------------------------------------------------------------- */
SELECT
    CONSTRUCTOR_NAME,
    ENTRIES,
    FINISH_RATE_PCT,
    MECHANICAL_DNFS,
    INCIDENT_DNFS,
    SEASON_POINTS,
    RANK() OVER (ORDER BY FINISH_RATE_PCT DESC) AS RELIABILITY_RANK,
    RANK() OVER (ORDER BY SEASON_POINTS DESC)   AS POINTS_RANK,
    RANK() OVER (ORDER BY FINISH_RATE_PCT DESC)
        - RANK() OVER (ORDER BY SEASON_POINTS DESC) AS RANK_DIVERGENCE
FROM V_CONSTRUCTOR_RELIABILITY
WHERE SEASON_YEAR = 2023
ORDER BY RANK_DIVERGENCE DESC;


/* ----------------------------------------------------------------------------
   Q10. Longest winless runs — gaps and islands.

   A running count of wins assigns every race to the "island" following the
   most recent win; grouping by that island measures the gap between wins.
   Reaching for this pattern instead of a self-join is the difference between
   a query that runs once and a query that runs on a billion rows.
   ---------------------------------------------------------------------------- */
WITH driver_races AS (
    SELECT
        DRIVER_ID,
        DRIVER_NAME,
        RACE_DATE,
        IS_WIN,
        SUM(IS_WIN) OVER (
            PARTITION BY DRIVER_ID ORDER BY RACE_DATE
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS WINS_SO_FAR
    FROM V_RACE_RESULT
    WHERE SEASON_YEAR BETWEEN 2010 AND 2023
),
droughts AS (
    SELECT
        DRIVER_ID,
        DRIVER_NAME,
        WINS_SO_FAR,
        COUNT(*)       AS RACES_IN_DROUGHT,
        MIN(RACE_DATE) AS DROUGHT_START,
        MAX(RACE_DATE) AS DROUGHT_END
    FROM driver_races
    WHERE WINS_SO_FAR > 0        -- only drivers who had already won
      AND IS_WIN = 0
    GROUP BY DRIVER_ID, DRIVER_NAME, WINS_SO_FAR
)
SELECT
    DRIVER_NAME,
    RACES_IN_DROUGHT,
    DROUGHT_START,
    DROUGHT_END,
    DATEDIFF('day', DROUGHT_START, DROUGHT_END) AS DAYS_WITHOUT_A_WIN
FROM droughts
WHERE RACES_IN_DROUGHT >= 20
ORDER BY RACES_IN_DROUGHT DESC
LIMIT 15;


/* ----------------------------------------------------------------------------
   Q11. Access control check.

   Both statements must fail with "does not exist or not authorized". A silent
   success here means the analyst role can read unvalidated data and the grant
   model in script 00 is broken.
   ----------------------------------------------------------------------------
SELECT * FROM F1_DB.RAW.RAW_RESULTS       LIMIT 1;
SELECT * FROM F1_DB.STAGING.STG_RACE_RESULT LIMIT 1;
   ---------------------------------------------------------------------------- */
