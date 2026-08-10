/* ============================================================================
   00_account_setup.sql

   Purpose     : Account-level objects only — cost guardrail, warehouses,
                 database + schema shells, and the role hierarchy.
   Run as      : ACCOUNTADMIN
   Idempotent  : Yes. Safe to re-run.
   Depends on  : Nothing.

   Design note : This script creates NO data objects. Separating account
                 administration from data modelling means the rest of the
                 pipeline runs under a least-privilege role and never needs
                 ACCOUNTADMIN again.
   ============================================================================ */

USE ROLE ACCOUNTADMIN;

/* ----------------------------------------------------------------------------
   1. COST GUARDRAIL
   Created before any warehouse exists, so no warehouse can ever run
   unmonitored. A trial account has a fixed credit budget; an accidental
   runaway query on a resized warehouse can consume it in an afternoon.
   ---------------------------------------------------------------------------- */
CREATE RESOURCE MONITOR IF NOT EXISTS RM_F1
    WITH CREDIT_QUOTA        = 20
         FREQUENCY           = MONTHLY
         START_TIMESTAMP     = IMMEDIATELY
         TRIGGERS ON  75 PERCENT DO NOTIFY
                  ON  90 PERCENT DO SUSPEND
                  ON 100 PERCENT DO SUSPEND_IMMEDIATE;

/* ----------------------------------------------------------------------------
   2. WAREHOUSES — one per workload
   Load, transform and serve are isolated so that a backfill cannot slow the
   dashboard, and so credit consumption is attributable to a pipeline stage.
   All XSMALL: this dataset never justifies more, and saying so is the point.
   ---------------------------------------------------------------------------- */
CREATE WAREHOUSE IF NOT EXISTS WH_F1_LOAD
    WAREHOUSE_SIZE      = 'XSMALL'
    AUTO_SUSPEND        = 60
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT             = 'Ingestion. COPY INTO from stage into RAW.';

CREATE WAREHOUSE IF NOT EXISTS WH_F1_TRANSFORM
    WAREHOUSE_SIZE      = 'XSMALL'
    AUTO_SUSPEND        = 60
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT             = 'MERGE into STAGING and dynamic table refresh.';

CREATE WAREHOUSE IF NOT EXISTS WH_F1_BI
    WAREHOUSE_SIZE      = 'XSMALL'
    AUTO_SUSPEND        = 60
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT             = 'Streamlit dashboard and ad hoc analysis.';

ALTER WAREHOUSE WH_F1_LOAD      SET RESOURCE_MONITOR = RM_F1;
ALTER WAREHOUSE WH_F1_TRANSFORM SET RESOURCE_MONITOR = RM_F1;
ALTER WAREHOUSE WH_F1_BI        SET RESOURCE_MONITOR = RM_F1;

/* ----------------------------------------------------------------------------
   3. DATABASE AND SCHEMA SHELLS
   Three layers with distinct contracts:
     RAW       — landing zone. Everything VARCHAR, nothing rejected, plus
                 file lineage. Immutable history of what arrived.
     STAGING   — typed, deduplicated, MERGE-maintained. One row per business
                 key. This is where correctness is enforced.
     ANALYTICS — dimensional model + presentation views. The only layer any
                 consumer is permitted to read.
   ---------------------------------------------------------------------------- */
CREATE DATABASE IF NOT EXISTS F1_DB
    COMMENT = 'Formula 1 championship pipeline — pre-interview assessment.';

CREATE SCHEMA IF NOT EXISTS F1_DB.RAW
    COMMENT = 'Landing zone. Untyped, append-only, file lineage retained.';

CREATE SCHEMA IF NOT EXISTS F1_DB.STAGING
    COMMENT = 'Typed and conformed. MERGE target, one row per business key.';

CREATE SCHEMA IF NOT EXISTS F1_DB.ANALYTICS
    COMMENT = 'Dimensional model and presentation views. Consumer-facing.';

DROP SCHEMA IF EXISTS F1_DB.PUBLIC;

/* ----------------------------------------------------------------------------
   4. ROLE HIERARCHY

   Two tiers, following Snowflake's documented pattern:

     Access roles    (AR_*) hold privileges on objects. Never granted to users.
     Functional roles (FR_*) represent a person or workload. Granted to users,
                      and composed by granting access roles into them.

   Adding a persona later means granting existing access roles into a new
   functional role — not re-issuing object grants. That is the entire reason
   for the indirection.

     FR_F1_ENGINEER  -> AR_RAW_RW, AR_STAGING_RW, AR_ANALYTICS_RW
     FR_F1_ANALYST   -> AR_ANALYTICS_RO
     FR_F1_APP       -> AR_ANALYTICS_RO      (Streamlit owner's-rights role)

   Note FR_F1_APP cannot reach RAW or STAGING at all. The dashboard is
   structurally incapable of reading unvalidated data.
   ---------------------------------------------------------------------------- */
CREATE ROLE IF NOT EXISTS AR_F1_RAW_RW        COMMENT = 'Access role: read/write RAW.';
CREATE ROLE IF NOT EXISTS AR_F1_STAGING_RW    COMMENT = 'Access role: read/write STAGING.';
CREATE ROLE IF NOT EXISTS AR_F1_ANALYTICS_RW  COMMENT = 'Access role: read/write ANALYTICS.';
CREATE ROLE IF NOT EXISTS AR_F1_ANALYTICS_RO  COMMENT = 'Access role: read-only ANALYTICS.';

CREATE ROLE IF NOT EXISTS FR_F1_ENGINEER      COMMENT = 'Functional role: data engineer.';
CREATE ROLE IF NOT EXISTS FR_F1_ANALYST       COMMENT = 'Functional role: analyst.';
CREATE ROLE IF NOT EXISTS FR_F1_APP           COMMENT = 'Functional role: Streamlit application.';

-- Compose functional roles from access roles.
GRANT ROLE AR_F1_RAW_RW       TO ROLE FR_F1_ENGINEER;
GRANT ROLE AR_F1_STAGING_RW   TO ROLE FR_F1_ENGINEER;
GRANT ROLE AR_F1_ANALYTICS_RW TO ROLE FR_F1_ENGINEER;
GRANT ROLE AR_F1_ANALYTICS_RO TO ROLE FR_F1_ANALYST;
GRANT ROLE AR_F1_ANALYTICS_RO TO ROLE FR_F1_APP;

-- Every custom role must roll up to SYSADMIN, or objects become unmanageable.
GRANT ROLE FR_F1_ENGINEER TO ROLE SYSADMIN;
GRANT ROLE FR_F1_ANALYST  TO ROLE SYSADMIN;
GRANT ROLE FR_F1_APP      TO ROLE SYSADMIN;

/* ----------------------------------------------------------------------------
   5. OWNERSHIP
   The engineer role owns the database and all schemas. Ownership — not a pile
   of individual grants — is what lets scripts 01..07 run without ACCOUNTADMIN.
   ---------------------------------------------------------------------------- */
GRANT OWNERSHIP ON DATABASE F1_DB           TO ROLE FR_F1_ENGINEER COPY CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA F1_DB.RAW         TO ROLE FR_F1_ENGINEER COPY CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA F1_DB.STAGING     TO ROLE FR_F1_ENGINEER COPY CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA F1_DB.ANALYTICS   TO ROLE FR_F1_ENGINEER COPY CURRENT GRANTS;

/* ----------------------------------------------------------------------------
   6. WAREHOUSE AND DATABASE USAGE
   ---------------------------------------------------------------------------- */
GRANT USAGE ON WAREHOUSE WH_F1_LOAD      TO ROLE AR_F1_RAW_RW;
GRANT USAGE ON WAREHOUSE WH_F1_TRANSFORM TO ROLE AR_F1_STAGING_RW;
GRANT USAGE ON WAREHOUSE WH_F1_TRANSFORM TO ROLE AR_F1_ANALYTICS_RW;
GRANT USAGE ON WAREHOUSE WH_F1_BI        TO ROLE AR_F1_ANALYTICS_RO;

GRANT USAGE ON DATABASE F1_DB TO ROLE AR_F1_RAW_RW;
GRANT USAGE ON DATABASE F1_DB TO ROLE AR_F1_STAGING_RW;
GRANT USAGE ON DATABASE F1_DB TO ROLE AR_F1_ANALYTICS_RW;
GRANT USAGE ON DATABASE F1_DB TO ROLE AR_F1_ANALYTICS_RO;

/* ----------------------------------------------------------------------------
   7. SCHEMA-SCOPED PRIVILEGES, INCLUDING FUTURE GRANTS
   FUTURE grants mean tables created next week are governed by the policy
   written today. Without them, every new object needs a manual grant, which
   is where access control silently rots.
   ---------------------------------------------------------------------------- */

-- RAW ------------------------------------------------------------------------
GRANT USAGE, CREATE TABLE, CREATE STAGE, CREATE FILE FORMAT, CREATE VIEW
    ON SCHEMA F1_DB.RAW TO ROLE AR_F1_RAW_RW;
GRANT SELECT, INSERT, UPDATE, DELETE ON FUTURE TABLES IN SCHEMA F1_DB.RAW
    TO ROLE AR_F1_RAW_RW;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA F1_DB.RAW
    TO ROLE AR_F1_RAW_RW;

-- STAGING reads RAW ----------------------------------------------------------
GRANT USAGE ON SCHEMA F1_DB.RAW TO ROLE AR_F1_STAGING_RW;
GRANT SELECT ON FUTURE TABLES IN SCHEMA F1_DB.RAW TO ROLE AR_F1_STAGING_RW;
GRANT SELECT ON ALL TABLES    IN SCHEMA F1_DB.RAW TO ROLE AR_F1_STAGING_RW;

GRANT USAGE, CREATE TABLE, CREATE VIEW, CREATE PROCEDURE, CREATE FUNCTION
    ON SCHEMA F1_DB.STAGING TO ROLE AR_F1_STAGING_RW;
GRANT SELECT, INSERT, UPDATE, DELETE ON FUTURE TABLES IN SCHEMA F1_DB.STAGING
    TO ROLE AR_F1_STAGING_RW;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA F1_DB.STAGING
    TO ROLE AR_F1_STAGING_RW;

-- ANALYTICS reads STAGING ----------------------------------------------------
GRANT USAGE ON SCHEMA F1_DB.STAGING TO ROLE AR_F1_ANALYTICS_RW;
GRANT SELECT ON FUTURE TABLES IN SCHEMA F1_DB.STAGING TO ROLE AR_F1_ANALYTICS_RW;
GRANT SELECT ON ALL TABLES    IN SCHEMA F1_DB.STAGING TO ROLE AR_F1_ANALYTICS_RW;

GRANT USAGE, CREATE TABLE, CREATE VIEW, CREATE DYNAMIC TABLE, CREATE STREAMLIT,
      CREATE STAGE, CREATE MASKING POLICY, CREATE FUNCTION
    ON SCHEMA F1_DB.ANALYTICS TO ROLE AR_F1_ANALYTICS_RW;
GRANT SELECT, INSERT, UPDATE, DELETE ON FUTURE TABLES IN SCHEMA F1_DB.ANALYTICS
    TO ROLE AR_F1_ANALYTICS_RW;

-- Read-only consumers --------------------------------------------------------
GRANT USAGE ON SCHEMA F1_DB.ANALYTICS TO ROLE AR_F1_ANALYTICS_RO;
GRANT SELECT ON FUTURE VIEWS          IN SCHEMA F1_DB.ANALYTICS TO ROLE AR_F1_ANALYTICS_RO;
GRANT SELECT ON FUTURE TABLES         IN SCHEMA F1_DB.ANALYTICS TO ROLE AR_F1_ANALYTICS_RO;
GRANT SELECT ON FUTURE DYNAMIC TABLES IN SCHEMA F1_DB.ANALYTICS TO ROLE AR_F1_ANALYTICS_RO;

/* ----------------------------------------------------------------------------
   8. DATA QUALITY PRIVILEGES  (Enterprise Edition)
   Required before script 05 can create or schedule data metric functions.
   ---------------------------------------------------------------------------- */
GRANT DATABASE ROLE SNOWFLAKE.DATA_METRIC_USER TO ROLE FR_F1_ENGINEER;
GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT  TO ROLE FR_F1_ENGINEER;

/* Lets the engineer read monitoring results in SNOWFLAKE.LOCAL. */
GRANT APPLICATION ROLE SNOWFLAKE.DATA_QUALITY_MONITORING_VIEWER
    TO ROLE FR_F1_ENGINEER;

/* ----------------------------------------------------------------------------
   9. ASSIGN ROLES TO THE CURRENT USER
   ---------------------------------------------------------------------------- */
SET current_user_name = CURRENT_USER();

GRANT ROLE FR_F1_ENGINEER TO USER IDENTIFIER($current_user_name);
GRANT ROLE FR_F1_ANALYST  TO USER IDENTIFIER($current_user_name);
GRANT ROLE FR_F1_APP      TO USER IDENTIFIER($current_user_name);

/* ----------------------------------------------------------------------------
   VERIFICATION
   ---------------------------------------------------------------------------- */
SHOW GRANTS TO ROLE FR_F1_ENGINEER;
SHOW GRANTS TO ROLE FR_F1_APP;
