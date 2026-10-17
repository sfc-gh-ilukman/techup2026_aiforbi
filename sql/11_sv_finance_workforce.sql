-- 11_sv_finance_workforce.sql — deploy SV2 (source: cortex_project/FINANCE_WORKFORCE_ANALYST.sv.yaml)
USE ROLE {{ROLE}};
USE WAREHOUSE {{WH}};
CALL SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML('{{DB}}.ANALYTICS', $$
name: FINANCE_WORKFORCE_ANALYST
description: >-
  PeakFit Australia finance and workforce analytics: annual budgets vs actual approved PO spend by centre,
  GL account and financial year, plus monthly headcount/FTE and staff pay costs by centre and role.
  Data is as at 31 October 2026.
tables:
  - name: budget_actuals
    description: Budget vs actual approved PO spend, one row per centre x GL account x financial year.
    synonyms: [budgets, budget vs actual, budget lines]
    base_table:
      database: {{DB}}
      schema: ANALYTICS
      table: BUDGET_ACTUALS_VW
    primary_key:
      columns: [BUDGET_ID]
    dimensions:
      - name: budget_id
        description: Budget line identifier.
        expr: BUDGET_ID
        data_type: VARCHAR
      - name: profit_centre_id
        description: Centre the budget belongs to.
        expr: PROFIT_CENTRE_ID
        data_type: VARCHAR
      - name: gl_account_id
        description: GL account budgeted.
        expr: GL_ACCOUNT_ID
        data_type: VARCHAR
      - name: budget_gl_category
        description: GL category of the budget line.
        expr: GL_CATEGORY
        data_type: VARCHAR
        is_enum: true
        sample_values: [Operations, Technology, Marketing, Admin, Capital]
      - name: financial_year
        synonyms: [FY, fiscal year, budget year]
        description: Financial year (July to June) of the budget. FY2027 is in progress (Jul-Oct 2026 actuals only).
        expr: FINANCIAL_YEAR
        data_type: VARCHAR
        is_enum: true
        sample_values: [FY2023, FY2024, FY2025, FY2026, FY2027]
      - name: budget_status
        description: "Over Budget: actual > 110% of budget. Slightly Over: 100-110%. On Track: 90-100%. Under Budget: < 90%."
        expr: BUDGET_STATUS
        data_type: VARCHAR
        is_enum: true
        sample_values: [Over Budget, Slightly Over, On Track, Under Budget]
    facts:
      - name: budget_amount
        description: Annual budget for the line in AUD.
        expr: BUDGET_AMOUNT
        data_type: NUMBER
      - name: actual_spend_amount
        description: Actual approved PO spend for the line in AUD.
        expr: ACTUAL_SPEND
        data_type: NUMBER
      - name: variance_amount
        description: Budget minus actual in AUD. Negative = overspend.
        expr: VARIANCE
        data_type: NUMBER
    metrics:
      - name: total_budget
        synonyms: [budget, budgeted amount]
        description: Total budget in AUD.
        expr: SUM(BUDGET_AMOUNT)
      - name: total_actual_spend
        synonyms: [actual spend, actuals]
        description: Total actual approved PO spend in AUD.
        expr: SUM(ACTUAL_SPEND)
      - name: total_variance
        synonyms: [variance, budget variance]
        description: Total budget minus actual spend in AUD. Negative = overspend.
        expr: SUM(VARIANCE)
      - name: variance_pct
        synonyms: [variance percentage]
        description: Total variance as a share of total budget. Negative = overspend.
        expr: SUM(VARIANCE) / NULLIF(SUM(BUDGET_AMOUNT), 0)

  - name: staff_roster
    description: Monthly headcount snapshot, one row per centre x role type x month.
    synonyms: [roster, workforce snapshot]
    base_table:
      database: {{DB}}
      schema: PUBLIC
      table: STAFF_ROSTER
    primary_key:
      columns: [ROSTER_ID]
    dimensions:
      - name: roster_id
        description: Roster row identifier.
        expr: ROSTER_ID
        data_type: VARCHAR
      - name: profit_centre_id
        description: Centre.
        expr: PROFIT_CENTRE_ID
        data_type: VARCHAR
      - name: role_type
        synonyms: [role, job role, staff role]
        description: Staff role type.
        expr: ROLE_TYPE
        data_type: VARCHAR
        is_enum: true
        sample_values: [Personal Trainer, Group Fitness Instructor, Reception Staff, Cleaning & Maintenance, Centre Manager, Sales Consultant, Pool Lifeguard, Admin & Finance]
      - name: roster_financial_year
        description: Financial year (July to June) of the roster month.
        expr: "'FY' || (YEAR(MONTH) + IFF(MONTH(MONTH) >= 7, 1, 0))"
        data_type: VARCHAR
    time_dimensions:
      - name: roster_month
        description: Snapshot month (first day of month).
        expr: MONTH
        data_type: DATE
    facts:
      - name: headcount_value
        description: Staff on the roster that month. Do not sum across months.
        expr: HEADCOUNT
        data_type: NUMBER
      - name: fte_value
        description: Full-time equivalent that month. Do not sum across months.
        expr: FTE_EQUIVALENT
        data_type: NUMBER
    metrics:
      - name: avg_monthly_headcount
        synonyms: [headcount, staff numbers, number of staff]
        description: Average monthly headcount over the months selected (total headcount per month, averaged across months).
        expr: SUM(HEADCOUNT) / NULLIF(COUNT(DISTINCT MONTH), 0)
      - name: avg_monthly_fte
        synonyms: [FTE, full time equivalent]
        description: Average monthly FTE over the months selected (total FTE per month, averaged across months).
        expr: SUM(FTE_EQUIVALENT) / NULLIF(COUNT(DISTINCT MONTH), 0)

  - name: staff_costs
    description: Individual staff pay records, one row per staff member per semi-monthly pay period.
    synonyms: [payroll, wages, labour cost]
    base_table:
      database: {{DB}}
      schema: PUBLIC
      table: STAFF_COSTS
    primary_key:
      columns: [COST_ID]
    dimensions:
      - name: cost_id
        description: Pay record identifier.
        expr: COST_ID
        data_type: VARCHAR
      - name: profit_centre_id
        description: Centre the staff member works at.
        expr: PROFIT_CENTRE_ID
        data_type: VARCHAR
      - name: staff_id
        description: Individual staff identifier.
        expr: STAFF_ID
        data_type: VARCHAR
      - name: cost_role_type
        description: Staff role type.
        expr: ROLE_TYPE
        data_type: VARCHAR
        is_enum: true
        sample_values: [Personal Trainer, Group Fitness Instructor, Reception Staff, Cleaning & Maintenance, Centre Manager, Sales Consultant, Pool Lifeguard, Admin & Finance]
      - name: pay_period
        description: "Semi-monthly pay period: 1 = 1st-15th, 2 = 16th-end of month."
        expr: PAY_PERIOD
        data_type: NUMBER
      - name: cost_financial_year
        description: Financial year (July to June) of the pay month.
        expr: "'FY' || (YEAR(MONTH) + IFF(MONTH(MONTH) >= 7, 1, 0))"
        data_type: VARCHAR
    time_dimensions:
      - name: pay_month
        description: Pay month (first day of month).
        expr: MONTH
        data_type: DATE
    facts:
      - name: hours_worked
        description: Hours worked in the pay period.
        expr: HOURS_WORKED
        data_type: NUMBER
      - name: hourly_rate
        description: Hourly pay rate in AUD.
        expr: HOURLY_RATE
        data_type: NUMBER
      - name: pay_cost
        description: Pay cost for the period in AUD (hours x rate).
        expr: TOTAL_COST
        data_type: NUMBER
    metrics:
      - name: total_staff_cost
        synonyms: [staff cost, wage cost, payroll cost]
        description: Total staff pay cost in AUD.
        expr: SUM(TOTAL_COST)
      - name: total_hours_worked
        description: Total hours worked.
        expr: SUM(HOURS_WORKED)
      - name: average_hourly_rate
        description: Average hourly rate weighted by hours.
        expr: SUM(TOTAL_COST) / NULLIF(SUM(HOURS_WORKED), 0)

  - name: profit_centres
    description: PeakFit fitness centres (also called cost centres), 23 centres across 6 states.
    synonyms: [centres, centers, gyms, cost centres, locations, clubs]
    base_table:
      database: {{DB}}
      schema: PUBLIC
      table: PROFIT_CENTRES
    primary_key:
      columns: [PROFIT_CENTRE_ID]
    dimensions:
      - name: profit_centre_id
        description: Unique centre identifier, e.g. PC001.
        expr: PROFIT_CENTRE_ID
        data_type: VARCHAR
      - name: centre_name
        synonyms: [centre, center, gym, club]
        description: Centre name.
        expr: CENTRE_NAME
        data_type: VARCHAR
        sample_values: [PeakFit Bondi, PeakFit Parramatta, PeakFit Southbank, PeakFit Richmond, PeakFit Fortitude Valley, PeakFit Perth CBD, PeakFit Adelaide CBD, PeakFit Canberra Civic]
      - name: state
        synonyms: [region]
        description: Australian state of the centre.
        expr: STATE
        data_type: VARCHAR
        is_enum: true
        sample_values: [NSW, VIC, QLD, WA, SA, ACT]
      - name: centre_size
        description: Centre size band.
        expr: CENTRE_SIZE
        data_type: VARCHAR
        is_enum: true
        sample_values: [large, medium, small]
      - name: has_pool
        description: TRUE if the centre has a pool.
        expr: HAS_POOL
        data_type: BOOLEAN

  - name: gl_accounts
    description: General ledger chart of accounts used for budgets.
    synonyms: [GL, general ledger, accounts]
    base_table:
      database: {{DB}}
      schema: PUBLIC
      table: GL_HIERARCHY
    primary_key:
      columns: [GL_ACCOUNT_ID]
    dimensions:
      - name: gl_account_id
        description: GL account code, e.g. GL6110.
        expr: GL_ACCOUNT_ID
        data_type: VARCHAR
      - name: gl_account_name
        description: GL account name.
        expr: GL_ACCOUNT_NAME
        data_type: VARCHAR
      - name: gl_category
        description: GL category.
        expr: GL_CATEGORY
        data_type: VARCHAR
        is_enum: true
        sample_values: [Operations, Technology, Marketing, Admin, Capital]
      - name: parent_gl_id
        description: Parent GL account (NULL for top-level accounts).
        expr: PARENT_GL_ID
        data_type: VARCHAR

relationships:
  - name: budget_to_centre
    left_table: budget_actuals
    right_table: profit_centres
    relationship_columns:
      - left_column: PROFIT_CENTRE_ID
        right_column: PROFIT_CENTRE_ID
  - name: budget_to_gl
    left_table: budget_actuals
    right_table: gl_accounts
    relationship_columns:
      - left_column: GL_ACCOUNT_ID
        right_column: GL_ACCOUNT_ID
  - name: roster_to_centre
    left_table: staff_roster
    right_table: profit_centres
    relationship_columns:
      - left_column: PROFIT_CENTRE_ID
        right_column: PROFIT_CENTRE_ID
  - name: costs_to_centre
    left_table: staff_costs
    right_table: profit_centres
    relationship_columns:
      - left_column: PROFIT_CENTRE_ID
        right_column: PROFIT_CENTRE_ID

module_custom_instructions:
  sql_generation: |
    PeakFit's financial year runs July to June: FY2026 = 1 July 2025 to 30 June 2026. FY2027 is in progress.
    If the user gives no time period, use FY2026 (the latest complete financial year) and state that assumption.
    Variance = budget minus actual. A negative variance means overspend.
    Headcount and FTE are monthly snapshots: never sum them across months. Use avg_monthly_headcount / avg_monthly_fte.
    For spend per FTE, divide actual spend by the average monthly FTE for the same centres and financial year.
    Data is as at 31 October 2026. Round currency to 2 decimal places.

verified_queries:
  - name: budget_vs_actual_by_state_fy2026
    question: How did each state track against budget in FY2026?
    verified_by: PeakFit Analytics
    use_as_onboarding_question: true
    sql: |
      SELECT pc.state,
             ROUND(SUM(b.budget_amount), 2) AS budget,
             ROUND(SUM(b.actual_spend_amount), 2) AS actual_spend,
             ROUND(SUM(b.variance_amount), 2) AS variance,
             ROUND(SUM(b.variance_amount) / NULLIF(SUM(b.budget_amount), 0), 4) AS variance_pct
      FROM __budget_actuals AS b
      JOIN __profit_centres AS pc ON b.profit_centre_id = pc.profit_centre_id
      WHERE b.financial_year = 'FY2026'
      GROUP BY pc.state
      ORDER BY variance
  - name: staff_cost_by_role_fy2026
    question: What was total staff cost by role in FY2026?
    verified_by: PeakFit Analytics
    use_as_onboarding_question: true
    sql: |
      SELECT c.cost_role_type, ROUND(SUM(c.pay_cost), 2) AS staff_cost, ROUND(SUM(c.hours_worked), 1) AS hours
      FROM __staff_costs AS c
      WHERE c.cost_financial_year = 'FY2026'
      GROUP BY c.cost_role_type
      ORDER BY staff_cost DESC
  - name: spend_per_fte_by_centre_size_fy2026
    question: What was procurement spend per FTE by centre size in FY2026?
    verified_by: PeakFit Analytics
    sql: |
      WITH spend AS (
        SELECT pc.centre_size, SUM(b.actual_spend_amount) AS actual_spend
        FROM __budget_actuals AS b
        JOIN __profit_centres AS pc ON b.profit_centre_id = pc.profit_centre_id
        WHERE b.financial_year = 'FY2026'
        GROUP BY pc.centre_size
      ), fte AS (
        SELECT pc.centre_size, SUM(r.fte_value) / COUNT(DISTINCT r.roster_month) AS avg_fte
        FROM __staff_roster AS r
        JOIN __profit_centres AS pc ON r.profit_centre_id = pc.profit_centre_id
        WHERE r.roster_financial_year = 'FY2026'
        GROUP BY pc.centre_size
      )
      SELECT s.centre_size, ROUND(s.actual_spend, 2) AS actual_spend, ROUND(f.avg_fte, 1) AS avg_monthly_fte,
             ROUND(s.actual_spend / NULLIF(f.avg_fte, 0), 2) AS spend_per_fte
      FROM spend AS s
      JOIN fte AS f ON s.centre_size = f.centre_size
      ORDER BY spend_per_fte DESC
  - name: headcount_by_state_oct_2026
    question: What is the current headcount by state?
    verified_by: PeakFit Analytics
    sql: |
      SELECT pc.state, SUM(r.headcount_value) AS headcount, ROUND(SUM(r.fte_value), 1) AS fte
      FROM __staff_roster AS r
      JOIN __profit_centres AS pc ON r.profit_centre_id = pc.profit_centre_id
      WHERE r.roster_month = '2026-10-01'
      GROUP BY pc.state
      ORDER BY headcount DESC
$$);
