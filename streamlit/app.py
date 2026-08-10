"""Formula 1 season dashboard — Streamlit in Snowflake.

Two questions, answered properly rather than six answered thinly:

  1. How did the championship actually unfold across the season?
  2. Which pit crews were fastest, and were they consistently fast?

The app reads only from F1_DB.ANALYTICS. It runs with owner's rights under a
role holding AR_F1_ANALYTICS_RO, so it has no path to RAW or STAGING even if a
query were written to reach for one.

Deploy: Snowsight -> Projects -> Streamlit -> + Streamlit App
        Database F1_DB, Schema ANALYTICS, Warehouse WH_F1_BI.
        No extra packages required.
"""

from __future__ import annotations

import altair as alt
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

SCHEMA = "F1_DB.ANALYTICS"
DRIVERS_ON_CHART = 6
CACHE_SECONDS = 600  # Matches the dynamic tables' 60-minute lag closely enough.

# Team liveries. Colour is doing real work on the progression chart: readers who
# know the sport identify a team faster by colour than by reading a legend, and
# team-mates sharing a hue makes intra-team order legible at a glance.
CONSTRUCTOR_COLOURS: dict[str, str] = {
    "Red Bull": "#3671C6",
    "Ferrari": "#E8002D",
    "Mercedes": "#27F4D2",
    "McLaren": "#FF8000",
    "Aston Martin": "#229971",
    "Alpine F1 Team": "#FF87BC",
    "Williams": "#64C4FF",
    "AlphaTauri": "#5E8FAA",
    "RB F1 Team": "#6692FF",
    "Alfa Romeo": "#C92D4B",
    "Haas F1 Team": "#B6BABD",
    "Racing Point": "#F596C8",
    "Renault": "#FFF500",
    "Toro Rosso": "#469BFF",
    "Force India": "#F596C8",
    "Sauber": "#52E252",
    "Lotus F1": "#FFB800",
}
FALLBACK_COLOUR = "#9AA0A6"


# --------------------------------------------------------------------------
# Data access
# --------------------------------------------------------------------------

session = get_active_session()


@st.cache_data(ttl=CACHE_SECONDS, show_spinner=False)
def run_query(statement: str) -> pd.DataFrame:
    """Execute one statement and return it as a pandas frame.

    Every query in this app goes through here, so caching, error handling and
    logging have exactly one place to live.
    """
    return session.sql(statement).to_pandas()


def load_seasons() -> pd.DataFrame:
    return run_query(
        f"""
        SELECT SEASON_YEAR, ROUNDS, DRIVERS, CONSTRUCTORS
        FROM {SCHEMA}.V_SEASON_SUMMARY
        WHERE ROUNDS > 0
        ORDER BY SEASON_YEAR DESC
        """
    )


def load_progression(season: int) -> pd.DataFrame:
    return run_query(
        f"""
        SELECT ROUND_NUMBER, RACE_NAME, DRIVER_NAME, DRIVER_CODE,
               CONSTRUCTOR_NAME, ROUND_POINTS, CUMULATIVE_POINTS,
               CHAMPIONSHIP_POSITION
        FROM {SCHEMA}.V_DRIVER_SEASON_PROGRESSION
        WHERE SEASON_YEAR = {season}
        ORDER BY ROUND_NUMBER, CHAMPIONSHIP_POSITION
        """
    )


def load_pit_performance(season: int) -> pd.DataFrame:
    return run_query(
        f"""
        SELECT CONSTRUCTOR_NAME, STOP_COUNT, MEDIAN_STOP_SECONDS,
               P90_STOP_SECONDS, FASTEST_STOP_SECONDS, SEASON_RANK,
               SECONDS_VS_FIELD_MEDIAN
        FROM {SCHEMA}.V_CONSTRUCTOR_PIT_PERFORMANCE
        WHERE SEASON_YEAR = {season}
        ORDER BY SEASON_RANK
        """
    )


def load_reliability(season: int) -> pd.DataFrame:
    return run_query(
        f"""
        SELECT CONSTRUCTOR_NAME, ENTRIES, FINISH_RATE_PCT,
               MECHANICAL_DNFS, INCIDENT_DNFS, SEASON_POINTS
        FROM {SCHEMA}.V_CONSTRUCTOR_RELIABILITY
        WHERE SEASON_YEAR = {season}
        ORDER BY SEASON_POINTS DESC
        """
    )


# Season comes from a selectbox populated by the query above, and is cast to int
# before interpolation. That cast is the sanitisation — an f-string around
# unvalidated input would be an injection, however trusted the widget looks.


# --------------------------------------------------------------------------
# Derivations
# --------------------------------------------------------------------------

def colour_scale(constructors: list[str]) -> alt.Scale:
    """Build an Altair scale mapping each constructor to its livery colour."""
    ordered = sorted(set(constructors))
    return alt.Scale(
        domain=ordered,
        range=[CONSTRUCTOR_COLOURS.get(name, FALLBACK_COLOUR) for name in ordered],
    )


def top_contenders(progression: pd.DataFrame, limit: int) -> list[str]:
    """Return the drivers with the highest final points total."""
    if progression.empty:
        return []
    finals = (
        progression.sort_values("ROUND_NUMBER")
        .groupby("DRIVER_NAME", as_index=False)
        .last()
        .nlargest(limit, "CUMULATIVE_POINTS")
    )
    return finals["DRIVER_NAME"].tolist()


def title_margin(progression: pd.DataFrame) -> tuple[str, float, float]:
    """Champion, their points, and the margin over second place."""
    finals = (
        progression.sort_values("ROUND_NUMBER")
        .groupby("DRIVER_NAME", as_index=False)
        .last()
        .sort_values("CUMULATIVE_POINTS", ascending=False)
    )
    if finals.empty:
        return "—", 0.0, 0.0
    champion = finals.iloc[0]
    runner_up_points = finals.iloc[1]["CUMULATIVE_POINTS"] if len(finals) > 1 else 0.0
    return (
        champion["DRIVER_NAME"],
        float(champion["CUMULATIVE_POINTS"]),
        float(champion["CUMULATIVE_POINTS"] - runner_up_points),
    )


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------

def render_headline(progression: pd.DataFrame, season: int) -> None:
    champion, points, margin = title_margin(progression)
    rounds = int(progression["ROUND_NUMBER"].max()) if not progression.empty else 0

    left, middle, right = st.columns(3)
    left.metric("Champion", champion)
    middle.metric("Points", f"{points:,.0f}")
    right.metric("Winning margin", f"{margin:,.0f} pts")
    st.caption(f"{season} season · {rounds} rounds")


def render_progression(progression: pd.DataFrame) -> None:
    st.subheader("How the title was won")
    st.write(
        "Running championship total after each round. Where lines cross, the "
        "championship lead changed hands."
    )

    contenders = top_contenders(progression, DRIVERS_ON_CHART)
    subset = progression[progression["DRIVER_NAME"].isin(contenders)]

    if subset.empty:
        st.info("No results recorded for this season.")
        return

    scale = colour_scale(subset["CONSTRUCTOR_NAME"].tolist())

    chart = (
        alt.Chart(subset)
        .mark_line(point=alt.OverlayMarkDef(size=28), strokeWidth=2.5)
        .encode(
            x=alt.X("ROUND_NUMBER:Q", title="Round",
                    axis=alt.Axis(tickMinStep=1, grid=False)),
            y=alt.Y("CUMULATIVE_POINTS:Q", title="Points"),
            color=alt.Color("CONSTRUCTOR_NAME:N", scale=scale, title="Constructor"),
            detail="DRIVER_NAME:N",
            tooltip=[
                alt.Tooltip("DRIVER_NAME:N", title="Driver"),
                alt.Tooltip("CONSTRUCTOR_NAME:N", title="Team"),
                alt.Tooltip("RACE_NAME:N", title="Race"),
                alt.Tooltip("ROUND_POINTS:Q", title="Points this round"),
                alt.Tooltip("CUMULATIVE_POINTS:Q", title="Running total"),
                alt.Tooltip("CHAMPIONSHIP_POSITION:Q", title="Standing"),
            ],
        )
        .properties(height=420)
        .interactive()
    )
    st.altair_chart(chart, use_container_width=True)
    st.caption(
        f"Top {len(contenders)} drivers by final points. Team-mates share a "
        "colour and are separated by line."
    )


def render_pit_performance(pit: pd.DataFrame) -> None:
    st.subheader("Pit crew performance")
    st.write(
        "Median stop time per constructor. The bar is the median; the marker "
        "is the 90th percentile — the gap between them is consistency."
    )

    if pit.empty:
        st.info("No pit stop data for this season. Coverage begins in 2011.")
        return

    scale = colour_scale(pit["CONSTRUCTOR_NAME"].tolist())
    order = pit.sort_values("MEDIAN_STOP_SECONDS")["CONSTRUCTOR_NAME"].tolist()

    bars = (
        alt.Chart(pit)
        .mark_bar(cornerRadiusEnd=3, height=18)
        .encode(
            y=alt.Y("CONSTRUCTOR_NAME:N", sort=order, title=None),
            x=alt.X("MEDIAN_STOP_SECONDS:Q", title="Seconds",
                    scale=alt.Scale(zero=False)),
            color=alt.Color("CONSTRUCTOR_NAME:N", scale=scale, legend=None),
            tooltip=[
                alt.Tooltip("CONSTRUCTOR_NAME:N", title="Team"),
                alt.Tooltip("MEDIAN_STOP_SECONDS:Q", title="Median (s)"),
                alt.Tooltip("P90_STOP_SECONDS:Q", title="90th percentile (s)"),
                alt.Tooltip("FASTEST_STOP_SECONDS:Q", title="Fastest (s)"),
                alt.Tooltip("STOP_COUNT:Q", title="Stops"),
            ],
        )
    )

    p90 = (
        alt.Chart(pit)
        .mark_tick(thickness=2.5, size=22, color="#1F1F1F")
        .encode(
            y=alt.Y("CONSTRUCTOR_NAME:N", sort=order, title=None),
            x=alt.X("P90_STOP_SECONDS:Q"),
        )
    )

    st.altair_chart((bars + p90).properties(height=380), use_container_width=True)
    st.caption(
        "Median rather than mean: one 40-second front-wing change would "
        "otherwise swamp a whole season of two-second stops."
    )


def render_reliability(reliability: pd.DataFrame) -> None:
    with st.expander("Reliability detail"):
        st.write(
            "Finishing rate against points scored. Teams high on one and low "
            "on the other are the interesting cases."
        )
        st.dataframe(
            reliability,
            use_container_width=True,
            hide_index=True,
            column_config={
                "CONSTRUCTOR_NAME": st.column_config.TextColumn("Constructor"),
                "ENTRIES": st.column_config.NumberColumn("Entries"),
                "FINISH_RATE_PCT": st.column_config.ProgressColumn(
                    "Finish rate", format="%.1f%%", min_value=0, max_value=100
                ),
                "MECHANICAL_DNFS": st.column_config.NumberColumn("Mechanical DNFs"),
                "INCIDENT_DNFS": st.column_config.NumberColumn("Incident DNFs"),
                "SEASON_POINTS": st.column_config.NumberColumn("Points", format="%.0f"),
            },
        )


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

def main() -> None:
    st.set_page_config(page_title="F1 Season Analysis", layout="wide")
    st.title("Formula 1 — season analysis")

    seasons = load_seasons()
    if seasons.empty:
        st.error(
            "No seasons found in F1_DB.ANALYTICS. Run sql/02 through sql/04, "
            "then confirm the dynamic tables have completed a refresh."
        )
        return

    available = seasons["SEASON_YEAR"].astype(int).tolist()
    season = st.selectbox("Season", available, index=0)

    progression = load_progression(season)
    if progression.empty:
        st.warning(f"No race results loaded for {season}.")
        return

    render_headline(progression, season)
    st.divider()
    render_progression(progression)
    st.divider()
    render_pit_performance(load_pit_performance(season))
    render_reliability(load_reliability(season))

    st.caption(
        "Source: Ergast Developer API archive via Kaggle. Served from "
        "F1_DB.ANALYTICS dynamic tables, 60-minute target lag."
    )


main()
