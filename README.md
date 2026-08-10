# Formula 1 — Snowflake to Streamlit pipeline

An end-to-end pipeline over the Ergast Formula 1 archive: seven source CSVs
land in Snowflake, are typed and quality-checked through a three-layer model,
and surface as a Streamlit dashboard answering two questions about a season.

Design rationale, trade-offs and scaling notes: [`docs/DESIGN_NOTES.md`](docs/DESIGN_NOTES.md).

---

## Pipeline

```
Kaggle CSVs                prepare_data.py          load_to_stage.py
(7 files)      ────────►   partition facts   ────►  PUT to internal stage
                           by season

                                                          │
                                                          ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │  RAW            all VARCHAR · file lineage · append-only         │
   │                 COPY INTO + VALIDATE → LOAD_AUDIT, LOAD_REJECTS  │
   ├──────────────────────────────────────────────────────────────────┤
   │  STAGING        typed · deduplicated · MERGE on hash             │
   │                 data metric functions attached here              │
   ├──────────────────────────────────────────────────────────────────┤
   │  ANALYTICS      5 dimensions + 2 facts as dynamic tables         │
   │                 presentation views carry joins & window funcs    │
   └──────────────────────────────────────────────────────────────────┘
                                                          │
                                                          ▼
                                          Streamlit in Snowflake
                                          (owner's rights, read-only role)
```

## Prerequisites

- Snowflake trial account, **Enterprise Edition** — masking policies and data
  metric functions are not available in Standard.
- Python 3.10+
- The dataset: Kaggle `rohanrao/formula-1-world-championship-1950-2020`.
  Unzip into `data/raw/`. Seven files are used: `circuits`, `constructors`,
  `drivers`, `status`, `races`, `results`, `pit_stops`.

## Running it

```bash
pip install -r requirements.txt
cp .env.example .env          # then fill in account and user
```

**1 — Account setup.** Run `sql/00_account_setup.sql` in a Snowsight worksheet
as `ACCOUNTADMIN`. Creates the resource monitor, three warehouses, the
database, and the role hierarchy. This is the only script needing
`ACCOUNTADMIN`.

**2 — RAW objects.** Run `sql/01_raw_layer.sql` as `FR_F1_ENGINEER`.

**3 — Prepare and upload files.**

```bash
make prepare                  # splits fact files by season into data/staged/
make dry-run                  # prints the PUT statements, no connection made
make stage                    # uploads to @F1_DB.RAW.STG_F1_FILES
```

Use `make prepare MIN_SEASON=2010` for a smaller first pass.

**4 — Load, transform, publish.** Run in order:

| Script | Does |
|---|---|
| `sql/02_copy_into_raw.sql` | `COPY INTO` with lineage, `VALIDATE` rejects, audit |
| `sql/03_staging_merge.sql` | Type, dedupe, hash-diff `MERGE` |
| `sql/04_analytics_dynamic_tables.sql` | Dimensions, facts, presentation views |
| `sql/05_data_quality.sql` | Data metric functions and integrity checks |
| `sql/06_governance.sql` | PII tag, masking policy, dev clone |
| `sql/07_analysis_queries.sql` | Demonstration queries — run as `FR_F1_ANALYST` |

**5 — Dashboard.** Snowsight → Projects → Streamlit → **+ Streamlit App**.
Database `F1_DB`, schema `ANALYTICS`, warehouse `WH_F1_BI`. Paste
`streamlit/app.py`. No extra packages needed.

## Verifying it works

Each SQL script ends with verification queries. Three worth running
deliberately:

- **Idempotency** — re-run `03_staging_merge.sql` immediately. Every `MERGE`
  should report 0 inserted, 0 updated.
- **Incrementality** — `make prepare MIN_SEASON=2020`, stage, load; then
  re-prepare with `MIN_SEASON=2015`, stage, and re-run `02`. Only the new
  season files are ingested. `LOAD_AUDIT` shows which.
- **Least privilege** — the commented block at the end of `07` selects from
  `RAW` and `STAGING` as `FR_F1_ANALYST`. Both must fail.

## Layout

```
sql/          00–07, run in order. Header states role, dependencies, idempotency.
scripts/      prepare_data.py (partition), load_to_stage.py (PUT)
streamlit/    app.py — the dashboard
docs/         DESIGN_NOTES.md — rationale, trade-offs, scaling
screenshots/  environment and dashboard captures
```

## Notes

- `data/` and `.env` are gitignored. The dataset is not redistributed here.
- `RM_F1` caps the account at 20 credits/month and suspends at 90%. Adjust
  before any large backfill.
- Dynamic tables refresh on a 60-minute target lag. After the first load,
  either wait or `ALTER DYNAMIC TABLE ... REFRESH` to populate immediately.
