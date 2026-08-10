/* ============================================================================
   06_governance.sql

   Purpose     : Classification tags, column masking, dev clone, app grants.
   Run as      : FR_F1_ENGINEER (ACCOUNTADMIN for the tag-propagation note)
   Requires    : Enterprise Edition.
   Idempotent  : Yes.
   Depends on  : 04_analytics_dynamic_tables.sql

   Driver date of birth is the only genuine personal data in this model. That
   makes it a small but real demonstration: the mechanism matters more than the
   volume, and a pipeline that has never had to think about column-level access
   tends to acquire the habit late and expensively.
   ============================================================================ */

USE ROLE FR_F1_ENGINEER;
USE WAREHOUSE WH_F1_TRANSFORM;
USE DATABASE F1_DB;
USE SCHEMA ANALYTICS;

/* ============================================================================
   1. CLASSIFICATION TAG

   Tags are the durable half of this. A masking policy protects one column; a
   tag records what kind of data a column holds, which is what lets you answer
   "where is our PII" across a warehouse nobody remembers building.
   ============================================================================ */
CREATE TAG IF NOT EXISTS DATA_SENSITIVITY
    ALLOWED_VALUES 'PUBLIC', 'INTERNAL', 'PII'
    COMMENT = 'Column classification. Drives discovery and, at scale, policy.';

/* ============================================================================
   2. MASKING POLICY

   IS_ROLE_IN_SESSION is used rather than CURRENT_ROLE(). CURRENT_ROLE only
   sees the primary role, so a user whose engineer access arrives through a
   secondary role would be masked incorrectly. This is the standard mistake in
   hand-written masking policies and it fails in the permissive direction only
   by luck.
   ============================================================================ */
CREATE MASKING POLICY IF NOT EXISTS MP_MASK_DATE_OF_BIRTH
    AS (VAL DATE) RETURNS DATE ->
    CASE
        WHEN IS_ROLE_IN_SESSION('FR_F1_ENGINEER') THEN VAL
        -- Everyone else sees birth year only. Age analysis still works;
        -- re-identification does not. Returning NULL would have destroyed a
        -- legitimate analytical use to protect the same field.
        ELSE DATE_FROM_PARTS(YEAR(VAL), 1, 1)
    END
    COMMENT = 'Truncates driver DOB to 1 January of the birth year for non-engineers.';

/* ============================================================================
   3. CONSUMER VIEW

   The policy is applied to a view rather than to DIM_DRIVER directly.

   Reason: DIM_DRIVER is a dynamic table, and a masking policy on a dynamic
   table's source or output interacts awkwardly with refresh — the refresh runs
   as the table's owner, so what gets materialised depends on how the policy
   evaluates for that role. Masking at the view boundary keeps the policy
   evaluated per query, per caller, which is the behaviour anyone reading the
   policy would expect.
   ============================================================================ */
CREATE OR REPLACE VIEW V_DRIVER_PROFILE AS
SELECT
    DRIVER_ID,
    DRIVER_REF,
    DRIVER_CODE,
    FULL_NAME,
    NATIONALITY,
    DATE_OF_BIRTH,
    DATEDIFF('year', DATE_OF_BIRTH, CURRENT_DATE()) AS AGE_YEARS
FROM DIM_DRIVER;

ALTER VIEW V_DRIVER_PROFILE
    MODIFY COLUMN DATE_OF_BIRTH SET MASKING POLICY MP_MASK_DATE_OF_BIRTH;

ALTER VIEW V_DRIVER_PROFILE
    MODIFY COLUMN DATE_OF_BIRTH SET TAG DATA_SENSITIVITY = 'PII';

/* At scale you would invert this: attach the policy to the tag with
   ALTER TAG DATA_SENSITIVITY SET MASKING POLICY MP_MASK_DATE_OF_BIRTH, so
   every column tagged PII is protected on tagging rather than on remembering.
   That requires ACCOUNTADMIN and applies account-wide, so it is described
   rather than executed here. */

/* ============================================================================
   4. STREAMLIT ACCESS

   The app role can read ANALYTICS and nothing else. Future grants from script
   00 already cover the views created above; this makes the app's own grants
   explicit and re-runnable.
   ============================================================================ */
GRANT USAGE ON SCHEMA F1_DB.ANALYTICS TO ROLE AR_F1_ANALYTICS_RO;
GRANT SELECT ON ALL VIEWS          IN SCHEMA F1_DB.ANALYTICS TO ROLE AR_F1_ANALYTICS_RO;
GRANT SELECT ON ALL DYNAMIC TABLES IN SCHEMA F1_DB.ANALYTICS TO ROLE AR_F1_ANALYTICS_RO;

/* Streamlit in Snowflake runs with owner's rights. Creating the app under a
   role that holds only AR_F1_ANALYTICS_RO means the dashboard is structurally
   incapable of reading RAW or STAGING — a misconfigured query fails rather
   than leaking. */
GRANT CREATE STREAMLIT ON SCHEMA F1_DB.ANALYTICS TO ROLE FR_F1_APP;
GRANT USAGE ON WAREHOUSE WH_F1_BI TO ROLE FR_F1_APP;

/* ============================================================================
   5. DEV ENVIRONMENT — ZERO-COPY CLONE

   A full copy of the model that consumes no additional storage until modified.
   This is the answer to "how do you test a schema change safely", and it costs
   one statement.
   ============================================================================ */
/* CREATE DATABASE is an account-level privilege that FR_F1_ENGINEER does not
   hold, so this one statement escalates and hands the result back. Granting
   CREATE DATABASE to the engineer instead would widen the role permanently for
   the sake of a disposable test fixture. */
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE DATABASE F1_DB_DEV CLONE F1_DB
    COMMENT = 'Zero-copy clone for schema-change testing. Disposable.';

GRANT OWNERSHIP ON DATABASE F1_DB_DEV TO ROLE FR_F1_ENGINEER;

/* CREATE DATABASE implicitly switches the session onto the new database, so the
   context set at the top of this script is now pointing at F1_DB_DEV. Restore it
   before the verification queries, which reference V_DRIVER_PROFILE unqualified. */
USE ROLE FR_F1_ENGINEER;
USE DATABASE F1_DB;
USE SCHEMA ANALYTICS;

/* Two caveats worth knowing before relying on this:
     - Dynamic tables clone in a suspended state and need resuming.
     - The clone diverges from the moment it is created; it is a test fixture,
       not a replica. */

/* ============================================================================
   VERIFICATION
   ============================================================================ */

-- As engineer: full date visible.
SELECT DRIVER_CODE, FULL_NAME, DATE_OF_BIRTH FROM V_DRIVER_PROFILE
WHERE DRIVER_CODE IS NOT NULL LIMIT 5;

/* USE SECONDARY ROLES NONE is load-bearing, not tidiness. USE ROLE changes only
   the primary role; every other role granted to the user stays active in the
   session. A user who holds FR_F1_ENGINEER alongside FR_F1_APP therefore still
   satisfies IS_ROLE_IN_SESSION('FR_F1_ENGINEER') and sees the unmasked date, so
   without this line the test silently proves nothing. Separate users would not
   need it; one user wearing every role does. */
-- As the app role: date truncated to 1 January. Screenshot both.
USE ROLE FR_F1_APP;
USE SECONDARY ROLES NONE;
/* WH_F1_TRANSFORM is the engineer's warehouse. With secondary roles dropped the
   app role can no longer see it, and the session would fail with "no active
   warehouse" rather than with anything about masking. */
USE WAREHOUSE WH_F1_BI;
SELECT DRIVER_CODE, FULL_NAME, DATE_OF_BIRTH FROM F1_DB.ANALYTICS.V_DRIVER_PROFILE
WHERE DRIVER_CODE IS NOT NULL LIMIT 5;

USE ROLE FR_F1_ENGINEER;
USE SECONDARY ROLES ALL;
USE WAREHOUSE WH_F1_TRANSFORM;

-- Where is the PII.
/* OBJECT_TYPE must be 'TABLE' here. Snowflake rejects 'VIEW' and asks for
   'TABLE' for all table-like objects, views included. */
SELECT * FROM TABLE(F1_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS(
    'F1_DB.ANALYTICS.V_DRIVER_PROFILE', 'TABLE'
));
