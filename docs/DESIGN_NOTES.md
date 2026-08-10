# Design notes

## 1. Dataset rationale

**Chosen:** the Ergast Formula 1 archive (Kaggle:
`rohanrao/formula-1-world-championship-1950-2020`). Seven of its fourteen files
are used: `circuits`, `constructors`, `drivers`, `status`, `races`, `results`,
`pit_stops`. Roughly 20 MB, ~30k result rows across 74 seasons.

The dataset was chosen for **shape, not size**. Three properties mattered:

**It is already a star.** A results fact with clean integer foreign keys to
four dimensions plus a status lookup. That allowed the modelling effort to go
into how the layers relate rather than into inventing relationships that
weren't there. Several candidate datasets — the ARC-AGI task corpus, most
public API dumps — offer three or more files that share no keys at all, which
makes joins and dimensional modelling impossible to demonstrate honestly.

**It has a real event-time axis.** Every fact rolls up to a season and a round.
That is what makes the incremental claim testable: fact files are partitioned
by season, so loading 2024 on top of 2010–2023 exercises the incremental path
for real rather than describing it in a diagram. A dataset without a natural
time key can only ever be full-loaded, and any statement about incrementality
becomes untestable.

**Its messiness is representative rather than punishing.** Nulls arrive as the
literal token `\N`; durations appear as both `1:27.452` and `22.879`;
`position` is null for retirements while `positionText` carries a code;
`grid = 0` means a pit-lane start, not pole. Each of those is a genuine
transformation decision with a right and a wrong answer — enough to show
judgment, not so much that the work becomes string parsing.

**Complexity budget.** Roughly eight hours, allocated deliberately: about two
on ingestion and RBAC, three on the transformation and merge logic, one on
quality and governance, one on the dashboard, one on documentation. The dataset
is small enough that no time went on waiting for loads, which is the correct
trade for an exercise assessing design rather than throughput. Two files were
deliberately left out: `lap_times` (~570k rows) and the qualifying and
standings files. `lap_times` would have demonstrated volume handling but adds
no new structural pattern — the same fact-table shape, more rows — and
`driver_standings` is a pre-aggregate that would have made the window-function
work redundant by shipping the answer in the source data.

---

## 2. Pipeline design

### Flow

Source CSVs → local partitioning → internal stage → `RAW` → `STAGING` →
`ANALYTICS` → Streamlit.

Layer contracts, which are what the design actually rests on:

| Layer | Contract | Maintained by |
|---|---|---|
| `RAW` | Every value `VARCHAR`. Nothing rejected. Every row carries its source filename, row number and file modification time. Append-only. | `COPY INTO` with a transformation `SELECT` |
| `STAGING` | Typed via `TRY_*` only. One row per business key. `ROW_HASH` for change detection, `DW_UPDATED_AT` meaningful. | `MERGE` |
| `ANALYTICS` | Conformed star. Facts hold keys and measures; dimensions hold attributes. | Dynamic tables + views |

### Three decisions worth defending

**Dynamic tables are single-source projections.** Every dynamic table has one
`FROM` clause, no joins, no window functions, no non-deterministic expressions,
and declares `REFRESH_MODE = INCREMENTAL` explicitly.

The default `AUTO` mode silently degrades to full refresh when a query contains
constructs Snowflake cannot maintain incrementally. A full refresh recomputes
the entire table on every schedule tick — the pipeline still produces correct
results, so nothing alerts, while the cost profile quietly becomes that of a
polling loop. Declaring `INCREMENTAL` means an unsupported construct fails at
`CREATE` time, in front of the person who introduced it. Joins and window
functions live in views underneath, where they cost nothing to maintain and
carry no refresh constraint.

**Incrementality comes from `COPY INTO`'s own load metadata**, not from a
watermark table. Snowflake records every file already ingested per table, so
re-running an identical `COPY` loads nothing and adding a season loads only
that season. Building a watermark table on top would have been redundant
machinery reimplementing a guarantee the platform already provides. The limit
is documented rather than hidden: load metadata expires after 64 days, at which
point a re-run would reload old files. Past that horizon the answer is Snowpipe
or an explicit manifest.

**Two-tier RBAC.** Access roles (`AR_*`) hold object privileges and are never
granted to users; functional roles (`FR_*`) represent people and workloads and
are composed from access roles. Adding a persona means granting existing access
roles into a new functional role, not reissuing object grants. `FUTURE` grants
mean objects created next month inherit today's policy.

The concrete payoff: the Streamlit app runs with owner's rights under a role
holding only `AR_F1_ANALYTICS_RO`. It cannot read `RAW` or `STAGING` — a query
that reached for them would fail rather than leak. The commented block at the
end of `07_analysis_queries.sql` asserts exactly this.

### Quality and governance

Data metric functions are attached to `STAGING`, scheduled `TRIGGER_ON_CHANGES`
so a table that did not change is not re-measured. System metrics cover
uniqueness, completeness and volume; three custom metrics cover domain rules
(grid range, points range, implausible pit durations). Referential integrity
needs a cross-table query, which a DMF body cannot express, so it lives in
`V_REFERENTIAL_INTEGRITY_CHECK` instead — knowing where the tool stops is part
of using it.

Driver date of birth is tagged `PII` and masked to birth-year for every role
except the engineer. The policy uses `IS_ROLE_IN_SESSION` rather than
`CURRENT_ROLE`, which only sees the primary role and therefore masks
incorrectly for users whose access arrives through a secondary role.

---

## 3. Trade-offs

**Measured but not enforced.** Quality metrics record breaches; they do not
halt the pipeline. Wiring a breach to a task that blocks promotion into
`ANALYTICS` is roughly an hour's work and was cut because deciding *which*
breaches should stop a load is a production conversation, not a default. As
built, a null foreign key would be recorded and visible, and the dashboard
would still serve.

**No SCD Type 2.** Every dimension is Type 1 — a correction overwrites history.
The dataset has a legitimate Type 2 candidate: driver-to-constructor is a
genuinely time-varying relationship. It was skipped because the fact table
already carries `CONSTRUCTOR_ID` per race entry, so "which team did they drive
for at that race" is answerable without it. Adding history would have been
modelling for its own sake.

**No orchestration.** Scripts are run in order by a human. No dbt, no Airflow,
no task DAG. Dynamic tables handle their own scheduling, which covers the
transform layer; only ingestion is manual. Adding an orchestrator would have
introduced a dependency the assignment doesn't need and moved the interesting
logic out of Snowflake, where the exercise is meant to demonstrate it.

**Positional column mapping, not header matching.** `MATCH_BY_COLUMN_NAME`
would survive a source column reorder, but cannot be combined with a
transformation `SELECT`, which is what makes `METADATA$` pseudocolumns
available. Lineage was judged worth more than reorder-tolerance for a static
published dataset. The mitigation is `ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE`
plus taking only the leading columns of `races`, so appended source columns are
a no-op.

**Local pre-processing.** Partitioning facts by season happens in pandas before
upload, because the source ships one flat file per table and the season key for
`results` and `pit_stops` only exists in `races`. In production the source
would emit partitioned files and this step would not exist. It is scaffolding
to make the incremental path demonstrable, and it is the first thing to delete.

**Single-region, single-account, no CI.** No environment promotion beyond the
zero-copy dev clone, no automated tests on the SQL. The clone gives a safe
place to test a schema change; it does not give a pipeline that tests itself.

**Dashboard scope.** Two insights, not eight. Championship progression and pit
crew performance, with reliability as a supporting table. The pit chart shows
median and P90 rather than mean, because one 40-second front-wing change moves
a mean and tells you nothing about crew performance.

---

## 4. Scaling to 100×

100× here means roughly 3M fact rows and thousands of files — still small for
Snowflake. The changes below are ordered by the point at which each starts to
matter.

**Ingestion: replace manual `COPY` with Snowpipe.** Move the stage to external
cloud storage with an auto-ingest notification. Files load within a minute of
arrival, the warehouse-sizing question disappears (Snowpipe is serverless), and
load metadata no longer expires on the 64-day cycle. The `COPY` transformation
logic transfers unchanged — this is a change of trigger, not of statement.

**Transformation: the dynamic table layer already scales.** Because every
dynamic table is genuinely incremental, refresh cost tracks changed rows, not
table size. At 100× the tuning is `TARGET_LAG`, not architecture: relax
dimensions to `24 hours`, keep facts at `60 minutes`, and chain any second-tier
tables with `TARGET_LAG = 'DOWNSTREAM'` so refresh is demand-driven. The
constraint that must be preserved is the one already established — verify
`REFRESH_MODE` resolved to `INCREMENTAL` in `INFORMATION_SCHEMA.DYNAMIC_TABLES`
after every change, and treat a silent switch to `FULL` as a regression.

**Clustering: only where pruning demonstrably fails.** Natural ingestion order
already correlates with season, so micro-partitions prune well on the dominant
filter without help. Before adding a clustering key on `FCT_RACE_RESULT`, check
`SYSTEM$CLUSTERING_INFORMATION` and the query profile's partitions-scanned
ratio. Clustering has ongoing serverless cost and is frequently added on
intuition to tables that were already pruning fine.

**Warehouses: the separation is already in place.** `WH_F1_LOAD`,
`WH_F1_TRANSFORM` and `WH_F1_BI` exist so the scaling response is per-workload:
size up transform for backfills, enable multi-cluster on BI for concurrency,
leave load alone once Snowpipe takes over. Scale *up* for a single slow
transform; scale *out* only for concurrent users — conflating the two is the
common and expensive mistake.

**Quality: sample rather than scan.** `TRIGGER_ON_CHANGES` on a
high-frequency table becomes its own workload. Move volume-sensitive metrics to
a fixed schedule, keep cheap ones on change, and add expectation thresholds
with alerts on `DATA_QUALITY_MONITORING_RESULTS` rather than eyeballing a view.

**Governance: invert the tag relationship.** Attach the masking policy to the
`DATA_SENSITIVITY` tag rather than to individual columns
(`ALTER TAG ... SET MASKING POLICY`). Protection then follows classification
automatically, so a new PII column is covered by tagging it rather than by
someone remembering to apply a policy. This requires `ACCOUNTADMIN` and applies
account-wide, which is why it is described here rather than executed in
`06_governance.sql`.

**Orchestration and testing: the real gap.** Beyond roughly ten sources,
hand-run scripts stop being viable. The path is dbt for the `STAGING` →
`ANALYTICS` transformations (version control, dependency graph, tests as
first-class objects) with dynamic tables kept as the materialisation strategy,
plus CI running the model against the zero-copy clone on every pull request.
That is the change that makes the pipeline maintainable by a team rather than
by its author — and it is a bigger and more valuable investment than any of the
performance items above.

---

## Known gaps

Honest inventory of what is not done:

- Quality breaches are recorded, not enforced. No circuit breaker.
- No automated tests. Verification is a set of queries a human runs.
- Sprint races are excluded, so 2021+ points totals are slightly understated
  relative to the official championship.
- `lap_times` is not loaded, so no stint or degradation analysis is possible.
- Dimensions are Type 1; a driver renamed in source loses their prior value.
- `RM_F1` is set to 20 credits and will suspend warehouses at 18. Deliberate for
  a trial, wrong for anything else.
