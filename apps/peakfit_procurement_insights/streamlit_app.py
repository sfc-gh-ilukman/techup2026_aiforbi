"""
PeakFit Procurement Insights

Procurement dashboard for PeakFit Australia (23 fitness centres, 6 states).
Pages:
  - Spend Overview      approved PO spend by financial year, state, category and supplier
  - Budget Tracker      budget vs actual approved spend by state and GL category
  - Supplier Scorecard  supplier performance with the PeakFit Supplier Risk Score

All figures are as at 31 October 2026. Financial years run July to June.
"""

from datetime import date
from decimal import Decimal

import altair as alt
import pandas as pd
import streamlit as st

st.set_page_config(
    page_title="PeakFit Procurement Insights",
    page_icon=":material/fitness_center:",
    layout="wide",
)

# =============================================================================
# Constants
# =============================================================================

AS_AT = date(2026, 10, 31)
DB = "{{DB}}"
FINANCIAL_YEARS = ["FY2026", "FY2025", "FY2024", "FY2023", "FY2027"]
CHART_HEIGHT = 320

# Supplier Risk Score (0-100, higher = riskier). Weights are set by Procurement
# and reviewed annually; see risk_score() for how the components are combined.
RISK_WEIGHT_PERFORMANCE = 0.40  # (5 - average overall assessment score) / 4
RISK_WEIGHT_OVERDUE = 0.30      # overdue invoice value / invoice value
RISK_WEIGHT_INCIDENTS = 0.30    # High/Critical PO-linked incidents in 12 months / 5, capped at 1
RISK_INCIDENT_CAP = 5
RISK_BANDS = [(40, "High"), (25, "Elevated"), (0, "Low")]


# =============================================================================
# Snowflake connection and data loading
# =============================================================================


def get_snowflake_connection():
    """Get the Snowflake connection; stop the app with a message if it fails."""
    try:
        return st.connection("snowflake")
    except Exception as e:
        st.error(f"Failed to connect to Snowflake: {e}")
        st.stop()


def run_query(sql: str, params: list | None = None) -> pd.DataFrame:
    df = get_snowflake_connection().query(sql, params=params or [], ttl=3600)
    df.columns = df.columns.str.lower()
    # Snowflake NUMBER columns arrive as Decimal objects; convert them to floats
    # so pandas arithmetic and Altair encodings work.
    for col in df.select_dtypes(include="object").columns:
        if df[col].map(lambda v: isinstance(v, Decimal)).any():
            df[col] = pd.to_numeric(df[col], errors="coerce")
    return df


@st.cache_data(ttl=3600, show_spinner="Loading spend...")
def load_spend(financial_year: str) -> pd.DataFrame:
    return run_query(
        f"""
        SELECT pc.state, pc.centre_name, s.category, s.supplier_name,
               SUM(po.amount) AS approved_spend, COUNT(*) AS po_count
        FROM {DB}.PUBLIC.PO_TRANSACTIONS po
        JOIN {DB}.PUBLIC.PROFIT_CENTRES pc ON pc.profit_centre_id = po.profit_centre_id
        JOIN {DB}.PUBLIC.SUPPLIERS s ON s.supplier_id = po.supplier_id
        WHERE po.status = 'Approved' AND po.financial_year = ?
        GROUP BY 1, 2, 3, 4
        """,
        [financial_year],
    )


@st.cache_data(ttl=3600, show_spinner="Loading spend trend...")
def load_spend_trend() -> pd.DataFrame:
    return run_query(
        f"""
        SELECT DATE_TRUNC('month', po.po_date) AS month, pc.state, SUM(po.amount) AS approved_spend
        FROM {DB}.PUBLIC.PO_TRANSACTIONS po
        JOIN {DB}.PUBLIC.PROFIT_CENTRES pc ON pc.profit_centre_id = po.profit_centre_id
        WHERE po.status = 'Approved' AND po.po_date <= ?
        GROUP BY 1, 2
        ORDER BY 1
        """,
        [AS_AT],
    )


@st.cache_data(ttl=3600, show_spinner="Loading budgets...")
def load_budget(financial_year: str) -> pd.DataFrame:
    return run_query(
        f"""
        SELECT pc.state, pc.centre_name, b.gl_category, g.gl_account_name,
               b.budget_amount, b.actual_spend, b.variance, b.budget_status
        FROM {DB}.ANALYTICS.BUDGET_ACTUALS_VW b
        JOIN {DB}.PUBLIC.PROFIT_CENTRES pc ON pc.profit_centre_id = b.profit_centre_id
        JOIN {DB}.PUBLIC.GL_HIERARCHY g ON g.gl_account_id = b.gl_account_id
        WHERE b.financial_year = ?
        """,
        [financial_year],
    )


@st.cache_data(ttl=3600, show_spinner="Scoring suppliers...")
def load_supplier_scorecard() -> pd.DataFrame:
    # Performance uses the last two completed half-year assessment periods
    # (H1-FY2026 and H2-FY2026 as at 31 Oct 2026); overdue and incident
    # components use the 12 months to the as-at date.
    return run_query(
        f"""
        WITH perf AS (
            SELECT supplier_id, AVG(overall_score) AS avg_overall_score, COUNT(*) AS assessments
            FROM {DB}.PUBLIC.SUPPLIER_ASSESSMENTS
            WHERE assessment_period IN ('H1-FY2026', 'H2-FY2026')
            GROUP BY 1
        ), inv AS (
            SELECT supplier_id,
                   SUM(invoice_amount) AS invoiced,
                   SUM(IFF(payment_status = 'Overdue', invoice_amount, 0)) AS overdue
            FROM {DB}.PUBLIC.PO_INVOICES
            WHERE invoice_date > DATEADD(month, -12, ?::DATE) AND invoice_date <= ?::DATE
            GROUP BY 1
        ), inc AS (
            SELECT po.supplier_id, COUNT(*) AS serious_incidents
            FROM {DB}.PUBLIC.INCIDENT_LOG i
            JOIN {DB}.PUBLIC.PO_TRANSACTIONS po ON po.po_id = i.related_po_id
            WHERE i.severity IN ('High', 'Critical')
              AND i.incident_date > DATEADD(month, -12, ?::DATE) AND i.incident_date <= ?::DATE
            GROUP BY 1
        )
        SELECT s.supplier_id, s.supplier_name, s.category, s.compliance_status,
               p.avg_overall_score, p.assessments,
               COALESCE(inv.invoiced, 0) AS invoiced_12m,
               COALESCE(inv.overdue, 0) AS overdue_12m,
               COALESCE(inc.serious_incidents, 0) AS serious_incidents_12m
        FROM {DB}.PUBLIC.SUPPLIERS s
        LEFT JOIN perf p ON p.supplier_id = s.supplier_id
        LEFT JOIN inv ON inv.supplier_id = s.supplier_id
        LEFT JOIN inc ON inc.supplier_id = s.supplier_id
        """,
        [AS_AT, AS_AT, AS_AT, AS_AT],
    )


# =============================================================================
# Supplier Risk Score
# =============================================================================


def risk_score(avg_overall_score: float, overdue_ratio: float, serious_incidents: int) -> float:
    """PeakFit Supplier Risk Score, 0 (no risk) to 100 (highest risk).

    risk = 100 * (0.40 * (5 - average overall score) / 4
                + 0.30 * overdue invoice ratio
                + 0.30 * min(High/Critical PO-linked incidents in 12 months / 5, 1))

    Suppliers without assessments in the last two completed periods are scored
    on a neutral 3.00 average.
    """
    score = 3.0 if pd.isna(avg_overall_score) else float(avg_overall_score)
    performance = (5.0 - score) / 4.0
    incidents = min(serious_incidents / RISK_INCIDENT_CAP, 1.0)
    return round(
        100
        * (
            RISK_WEIGHT_PERFORMANCE * performance
            + RISK_WEIGHT_OVERDUE * float(overdue_ratio)
            + RISK_WEIGHT_INCIDENTS * incidents
        ),
        1,
    )


def risk_band(score: float) -> str:
    for threshold, label in RISK_BANDS:
        if score >= threshold:
            return label
    return "Low"


# =============================================================================
# Pages
# =============================================================================


def fmt_aud(value: float) -> str:
    return f"${value:,.0f}"


def spend_overview():
    st.subheader("Spend overview")
    st.caption("Approved purchase orders only (AUD, ex GST). Financial year = July to June.")
    fy = st.selectbox("Financial year", FINANCIAL_YEARS, index=0, key="spend_fy")
    df = load_spend(fy)
    if df.empty:
        st.info("No approved spend for this financial year.")
        return

    total = df["approved_spend"].sum()
    with st.container(horizontal=True):
        st.metric("Approved spend", fmt_aud(total), border=True)
        st.metric("Purchase orders", f"{int(df['po_count'].sum()):,}", border=True)
        st.metric("Active suppliers", f"{df['supplier_name'].nunique()}", border=True)

    col1, col2 = st.columns(2)
    with col1:
        by_state = df.groupby("state", as_index=False)["approved_spend"].sum()
        st.altair_chart(
            alt.Chart(by_state, title="By state")
            .mark_bar()
            .encode(
                x=alt.X("approved_spend:Q", title="Approved spend"),
                y=alt.Y("state:N", sort="-x", title=None),
                tooltip=["state", alt.Tooltip("approved_spend:Q", format="$,.0f")],
            )
            .properties(height=CHART_HEIGHT)
        )
    with col2:
        by_cat = df.groupby("category", as_index=False)["approved_spend"].sum()
        st.altair_chart(
            alt.Chart(by_cat, title="By supplier category")
            .mark_bar()
            .encode(
                x=alt.X("approved_spend:Q", title="Approved spend"),
                y=alt.Y("category:N", sort="-x", title=None),
                tooltip=["category", alt.Tooltip("approved_spend:Q", format="$,.0f")],
            )
            .properties(height=CHART_HEIGHT)
        )

    trend = load_spend_trend()
    st.altair_chart(
        alt.Chart(trend, title="Monthly approved spend by state")
        .mark_area()
        .encode(
            x=alt.X("month:T", title=None),
            y=alt.Y("approved_spend:Q", stack=True, title="Approved spend"),
            color=alt.Color("state:N"),
            tooltip=["month:T", "state", alt.Tooltip("approved_spend:Q", format="$,.0f")],
        )
        .properties(height=CHART_HEIGHT)
    )

    top = (
        df.groupby(["supplier_name", "category"], as_index=False)["approved_spend"].sum()
        .sort_values("approved_spend", ascending=False)
        .head(15)
    )
    st.markdown("**Top 15 suppliers**")
    st.dataframe(
        top,
        hide_index=True,
        column_config={"approved_spend": st.column_config.NumberColumn("Approved spend", format="dollar")},
    )


def budget_tracker():
    st.subheader("Budget tracker")
    st.caption("Variance = budget - actual approved spend. Negative variance = overspend.")
    fy = st.selectbox("Financial year", FINANCIAL_YEARS, index=0, key="budget_fy")
    df = load_budget(fy)
    if df.empty:
        st.info("No budget lines for this financial year.")
        return

    with st.container(horizontal=True):
        st.metric("Budget", fmt_aud(df["budget_amount"].sum()), border=True)
        st.metric("Actual", fmt_aud(df["actual_spend"].sum()), border=True)
        st.metric("Variance", fmt_aud(df["variance"].sum()), border=True)
        st.metric("Lines over budget (>110%)", int((df["budget_status"] == "Over Budget").sum()), border=True)

    by_state = df.groupby("state", as_index=False)[["budget_amount", "actual_spend"]].sum()
    long = by_state.melt("state", var_name="measure", value_name="amount")
    st.altair_chart(
        alt.Chart(long, title="Budget vs actual by state")
        .mark_bar()
        .encode(
            x=alt.X("state:N", title=None),
            xOffset="measure:N",
            y=alt.Y("amount:Q", title="AUD"),
            color=alt.Color("measure:N", title=None),
            tooltip=["state", "measure", alt.Tooltip("amount:Q", format="$,.0f")],
        )
        .properties(height=CHART_HEIGHT)
    )

    status_counts = df.groupby(["gl_category", "budget_status"], as_index=False).size()
    st.altair_chart(
        alt.Chart(status_counts, title="Budget status by GL category (lines)")
        .mark_bar()
        .encode(
            x=alt.X("size:Q", stack="normalize", title="Share of lines"),
            y=alt.Y("gl_category:N", title=None),
            color=alt.Color("budget_status:N", title="Status"),
            tooltip=["gl_category", "budget_status", "size"],
        )
        .properties(height=220)
    )

    st.markdown("**Lines over budget**")
    over = df[df["budget_status"] == "Over Budget"].sort_values("variance")
    st.dataframe(
        over[["state", "centre_name", "gl_account_name", "budget_amount", "actual_spend", "variance"]],
        hide_index=True,
        column_config={
            "budget_amount": st.column_config.NumberColumn("Budget", format="dollar"),
            "actual_spend": st.column_config.NumberColumn("Actual", format="dollar"),
            "variance": st.column_config.NumberColumn("Variance", format="dollar"),
        },
    )


def supplier_scorecard():
    st.subheader("Supplier scorecard")
    st.caption(
        "Supplier Risk Score: 0-100, higher = riskier. Combines assessment performance "
        "(last two completed half-years), overdue invoices and serious incidents (last 12 months)."
    )
    df = load_supplier_scorecard()
    df["overdue_ratio"] = (df["overdue_12m"] / df["invoiced_12m"].where(df["invoiced_12m"] > 0)).fillna(0.0)
    df["risk_score"] = [
        risk_score(s, o, int(i))
        for s, o, i in zip(df["avg_overall_score"], df["overdue_ratio"], df["serious_incidents_12m"])
    ]
    df["risk_band"] = df["risk_score"].map(risk_band)

    categories = ["All"] + sorted(df["category"].unique().tolist())
    category = st.selectbox("Supplier category", categories, index=0)
    if category != "All":
        df = df[df["category"] == category]

    with st.container(horizontal=True):
        st.metric("Suppliers", len(df), border=True)
        st.metric("High risk", int((df["risk_band"] == "High").sum()), border=True)
        st.metric("Average risk score", f"{df['risk_score'].mean():.1f}", border=True)

    st.altair_chart(
        alt.Chart(df, title="Risk score vs assessment score")
        .mark_circle(size=90)
        .encode(
            x=alt.X("avg_overall_score:Q", title="Average overall score", scale=alt.Scale(domain=[1, 5])),
            y=alt.Y("risk_score:Q", title="Risk score", scale=alt.Scale(domain=[0, 100])),
            color=alt.Color("risk_band:N", title="Band"),
            tooltip=["supplier_name", "category", "avg_overall_score", "risk_score", "serious_incidents_12m"],
        )
        .properties(height=CHART_HEIGHT)
    )

    st.dataframe(
        df.sort_values("risk_score", ascending=False)[
            [
                "supplier_name", "category", "risk_score", "risk_band", "avg_overall_score",
                "overdue_ratio", "serious_incidents_12m", "compliance_status",
            ]
        ],
        hide_index=True,
        column_config={
            "risk_score": st.column_config.ProgressColumn("Risk score", min_value=0, max_value=100, format="%.1f"),
            "avg_overall_score": st.column_config.NumberColumn("Avg score", format="%.2f"),
            "overdue_ratio": st.column_config.NumberColumn("Overdue ratio", format="percent"),
            "serious_incidents_12m": st.column_config.NumberColumn("High/Critical incidents (12m)"),
        },
    )


# =============================================================================
# Layout
# =============================================================================

st.title("PeakFit Procurement Insights")
st.caption(f"As at {AS_AT:%d %B %Y}")

spend_tab, budget_tab, supplier_tab = st.tabs(["Spend Overview", "Budget Tracker", "Supplier Scorecard"])
with spend_tab:
    spend_overview()
with budget_tab:
    budget_tracker()
with supplier_tab:
    supplier_scorecard()
