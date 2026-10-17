-- 10_sv_procurement.sql — deploy SV1 (source: cortex_project/PROCUREMENT_ANALYST.sv.yaml)
USE ROLE {{ROLE}};
USE WAREHOUSE {{WH}};
CALL SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML('{{DB}}.ANALYTICS', $$
name: PROCUREMENT_ANALYST
description: >-
  PeakFit Australia procurement analytics: purchase orders, supplier invoices, suppliers, buyers,
  centres (profit centres), GL accounts and spend codes across 23 fitness centres, FY2023-FY2027.
  Data is as at 31 October 2026.
tables:
  - name: po_transactions
    description: Purchase orders raised by PeakFit buyers (header level, one row per PO).
    synonyms: [purchase orders, POs, orders]
    base_table:
      database: {{DB}}
      schema: PUBLIC
      table: PO_TRANSACTIONS
    primary_key:
      columns: [PO_ID]
    dimensions:
      - name: po_id
        description: Unique purchase order identifier.
        expr: PO_ID
        data_type: VARCHAR
      - name: po_number
        synonyms: [PO reference, PO number]
        description: Human-readable PO reference, PF-YYMM-nnnnn.
        expr: PO_NUMBER
        data_type: VARCHAR
      - name: financial_year
        synonyms: [FY, fiscal year]
        description: PeakFit financial year (July to June). FY2026 = 1 Jul 2025 to 30 Jun 2026. FY2027 is in progress.
        expr: FINANCIAL_YEAR
        data_type: VARCHAR
        is_enum: true
        sample_values: [FY2023, FY2024, FY2025, FY2026, FY2027]
      - name: buyer_id
        description: Buyer who raised the PO.
        expr: BUYER_ID
        data_type: VARCHAR
      - name: supplier_id
        description: Supplier on the PO.
        expr: SUPPLIER_ID
        data_type: VARCHAR
      - name: profit_centre_id
        description: Centre the PO is charged to.
        expr: PROFIT_CENTRE_ID
        data_type: VARCHAR
      - name: spend_code_id
        description: Spend code of the PO.
        expr: SPEND_CODE_ID
        data_type: VARCHAR
      - name: gl_account_id
        description: General ledger account the PO is coded to.
        expr: GL_ACCOUNT_ID
        data_type: VARCHAR
      - name: po_description
        synonyms: [description, line description]
        description: Free-text description of the goods or services ordered.
        expr: DESCRIPTION
        data_type: VARCHAR
      - name: po_status
        synonyms: [status, approval status]
        description: PO status. Only Approved POs count as spend.
        expr: STATUS
        data_type: VARCHAR
        is_enum: true
        sample_values: [Approved, Pending, Rejected]
      - name: approval_level
        synonyms: [approval tier, delegation level]
        description: Approval tier required by the PO amount.
        expr: APPROVAL_LEVEL
        data_type: VARCHAR
        is_enum: true
        sample_values: [Self, Manager, Executive, LT Panel]
    time_dimensions:
      - name: po_date
        synonyms: [order date, raised date]
        description: Date the PO was raised.
        expr: PO_DATE
        data_type: DATE
    facts:
      - name: po_amount
        synonyms: [PO value, amount]
        description: PO value in AUD ex GST.
        expr: AMOUNT
        data_type: NUMBER
    metrics:
      - name: total_spend
        synonyms: [spend, approved spend, procurement spend, total approved spend]
        description: Approved PO value in AUD. This is the definition of "spend".
        expr: SUM(CASE WHEN STATUS = 'Approved' THEN AMOUNT ELSE 0 END)
      - name: total_po_value_all_statuses
        description: Total PO value across all statuses (Approved, Pending, Rejected). Use only when explicitly asked.
        expr: SUM(AMOUNT)
      - name: po_count
        synonyms: [number of POs, number of purchase orders]
        description: Number of purchase orders (all statuses).
        expr: COUNT(PO_ID)
      - name: approved_po_count
        description: Number of Approved purchase orders.
        expr: COUNT(CASE WHEN STATUS = 'Approved' THEN PO_ID END)
      - name: average_po_value
        synonyms: [average order value, avg PO value]
        description: Average value of Approved POs in AUD.
        expr: AVG(CASE WHEN STATUS = 'Approved' THEN AMOUNT END)

  - name: po_invoices
    description: Supplier invoices against approved purchase orders (one row per invoice). Payment status is as at 31 Oct 2026.
    synonyms: [invoices, supplier invoices, bills]
    base_table:
      database: {{DB}}
      schema: PUBLIC
      table: PO_INVOICES
    primary_key:
      columns: [INVOICE_ID]
    dimensions:
      - name: invoice_id
        description: Unique invoice identifier.
        expr: INVOICE_ID
        data_type: VARCHAR
      - name: po_id
        description: Purchase order being invoiced.
        expr: PO_ID
        data_type: VARCHAR
      - name: payment_status
        synonyms: [invoice status]
        description: Payment status as at 31 Oct 2026. Overdue = unpaid and past due date.
        expr: PAYMENT_STATUS
        data_type: VARCHAR
        is_enum: true
        sample_values: [Paid, Pending, Overdue, On Hold]
      - name: invoice_description
        description: Invoice line description.
        expr: DESCRIPTION
        data_type: VARCHAR
    time_dimensions:
      - name: invoice_date
        description: Invoice date.
        expr: INVOICE_DATE
        data_type: DATE
      - name: due_date
        description: Payment due date.
        expr: DUE_DATE
        data_type: DATE
    facts:
      - name: invoice_amount
        description: Invoice value in AUD ex GST.
        expr: INVOICE_AMOUNT
        data_type: NUMBER
    metrics:
      - name: total_invoiced
        synonyms: [invoiced amount, invoice value]
        description: Total invoice value in AUD.
        expr: SUM(INVOICE_AMOUNT)
      - name: invoice_count
        synonyms: [number of invoices]
        description: Number of invoices.
        expr: COUNT(INVOICE_ID)
      - name: overdue_amount
        synonyms: [overdue invoices value, amount overdue]
        description: Value of invoices with payment status Overdue.
        expr: SUM(CASE WHEN PAYMENT_STATUS = 'Overdue' THEN INVOICE_AMOUNT ELSE 0 END)

  - name: suppliers
    description: Supplier (vendor) master, 50 suppliers in 14 categories.
    synonyms: [vendors]
    base_table:
      database: {{DB}}
      schema: PUBLIC
      table: SUPPLIERS
    primary_key:
      columns: [SUPPLIER_ID]
    dimensions:
      - name: supplier_id
        description: Unique supplier identifier, e.g. SUP014.
        expr: SUPPLIER_ID
        data_type: VARCHAR
      - name: supplier_name
        synonyms: [vendor, vendor name, supplier]
        description: Registered supplier name.
        expr: SUPPLIER_NAME
        data_type: VARCHAR
        sample_values: [SparkleClean Commercial Pty Ltd, Apex Facility Services, IronForge Fitness Supply, FitTech Service & Repair, GymCare Technical Services, Nexus IT Solutions, Brightside Creative Agency, PowerGrid Energy Retail, Climate Control Australia, CoolBreeze HVAC Solutions]
      - name: supplier_category
        synonyms: [category, supplier type, vendor category]
        description: Supplier category. Category spend is grouped by this column.
        expr: CATEGORY
        data_type: VARCHAR
        is_enum: true
        sample_values: [Cleaning Services, Facilities Maintenance, Fitness Equipment, Equipment Servicing, IT Services, Software & SaaS, Marketing & Advertising, Security Services, Utilities & Energy, Pool & Aquatic Services, HVAC Services, Professional Services, Office Supplies, Catering & Nutrition]
      - name: compliance_status
        description: Supplier compliance status (insurance, ABN, safety documentation).
        expr: COMPLIANCE_STATUS
        data_type: VARCHAR
        is_enum: true
        sample_values: [Compliant, Under Review, Non-Compliant]
      - name: abn
        description: Australian Business Number.
        expr: ABN
        data_type: VARCHAR

  - name: buyers
    description: PeakFit staff who raise purchase orders.
    base_table:
      database: {{DB}}
      schema: PUBLIC
      table: BUYERS
    primary_key:
      columns: [BUYER_ID]
    dimensions:
      - name: buyer_id
        description: Unique buyer identifier.
        expr: BUYER_ID
        data_type: VARCHAR
      - name: buyer_name
        synonyms: [buyer, requester, purchaser]
        description: Buyer full name.
        expr: BUYER_NAME
        data_type: VARCHAR
      - name: buyer_email
        description: Buyer work email.
        expr: EMAIL
        data_type: VARCHAR
      - name: role_title
        description: Buyer role.
        expr: ROLE_TITLE
        data_type: VARCHAR
        is_enum: true
        sample_values: [Senior Buyer, Procurement Officer, Centre Procurement Coordinator]
      - name: home_centre_id
        description: The buyer's home centre identifier.
        expr: HOME_CENTRE_ID
        data_type: VARCHAR

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
    description: General ledger chart of accounts used for POs.
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

  - name: spend_codes
    description: Procurement spend codes (126 codes rolling up to 20 spend code names).
    base_table:
      database: {{DB}}
      schema: PUBLIC
      table: SPEND_CODES
    primary_key:
      columns: [SPEND_CODE_ID]
    dimensions:
      - name: spend_code_id
        description: Spend code identifier.
        expr: SPEND_CODE_ID
        data_type: VARCHAR
      - name: spend_code_name
        synonyms: [spend code, spend type]
        description: Spend code name. Several codes share a name; group by name, not code.
        expr: SPEND_CODE_NAME
        data_type: VARCHAR

relationships:
  - name: po_to_supplier
    left_table: po_transactions
    right_table: suppliers
    relationship_columns:
      - left_column: SUPPLIER_ID
        right_column: SUPPLIER_ID
  - name: po_to_buyer
    left_table: po_transactions
    right_table: buyers
    relationship_columns:
      - left_column: BUYER_ID
        right_column: BUYER_ID
  - name: po_to_centre
    left_table: po_transactions
    right_table: profit_centres
    relationship_columns:
      - left_column: PROFIT_CENTRE_ID
        right_column: PROFIT_CENTRE_ID
  - name: po_to_gl
    left_table: po_transactions
    right_table: gl_accounts
    relationship_columns:
      - left_column: GL_ACCOUNT_ID
        right_column: GL_ACCOUNT_ID
  - name: po_to_spend_code
    left_table: po_transactions
    right_table: spend_codes
    relationship_columns:
      - left_column: SPEND_CODE_ID
        right_column: SPEND_CODE_ID
  - name: invoice_to_po
    left_table: po_invoices
    right_table: po_transactions
    relationship_columns:
      - left_column: PO_ID
        right_column: PO_ID

module_custom_instructions:
  sql_generation: |
    PeakFit's financial year runs July to June: FY2026 = 1 July 2025 to 30 June 2026. Use the financial_year column for FY filters.
    "Spend" always means Approved purchase orders (the total_spend metric). Include Pending or Rejected POs only when the user explicitly asks.
    If the user gives no time period, use FY2026 (the latest complete financial year) and state that assumption.
    "Category spend" means spend grouped by suppliers.supplier_category, not by spend code.
    Group spend codes by spend_code_name (several codes share a name).
    Data is as at 31 October 2026. Round currency to 2 decimal places.

verified_queries:
  - name: q1_approved_spend_by_state_fy2026
    question: What was total approved spend in FY2026 by state?
    verified_by: PeakFit Analytics
    use_as_onboarding_question: true
    sql: |
      SELECT pc.state, ROUND(SUM(po.po_amount), 2) AS approved_spend
      FROM __po_transactions AS po
      JOIN __profit_centres AS pc ON po.profit_centre_id = pc.profit_centre_id
      WHERE po.po_status = 'Approved' AND po.financial_year = 'FY2026'
      GROUP BY pc.state
      ORDER BY approved_spend DESC
  - name: total_approved_spend_fy2026
    question: What was our total approved spend in FY2026?
    verified_by: PeakFit Analytics
    use_as_onboarding_question: true
    sql: |
      SELECT ROUND(SUM(po.po_amount), 2) AS approved_spend
      FROM __po_transactions AS po
      WHERE po.po_status = 'Approved' AND po.financial_year = 'FY2026'
  - name: overdue_invoices_by_state
    question: What is the value of overdue invoices by state?
    verified_by: PeakFit Analytics
    use_as_onboarding_question: true
    sql: |
      SELECT pc.state, COUNT(i.invoice_id) AS overdue_invoices, ROUND(SUM(i.invoice_amount), 2) AS overdue_amount
      FROM __po_invoices AS i
      JOIN __po_transactions AS po ON i.po_id = po.po_id
      JOIN __profit_centres AS pc ON po.profit_centre_id = pc.profit_centre_id
      WHERE i.payment_status = 'Overdue'
      GROUP BY pc.state
      ORDER BY overdue_amount DESC
  - name: invoiced_by_supplier_fy2026
    question: How much has each supplier invoiced us in FY2026?
    verified_by: PeakFit Analytics
    sql: |
      SELECT s.supplier_name, COUNT(i.invoice_id) AS invoices, ROUND(SUM(i.invoice_amount), 2) AS total_invoiced
      FROM __po_invoices AS i
      JOIN __po_transactions AS po ON i.po_id = po.po_id
      JOIN __suppliers AS s ON po.supplier_id = s.supplier_id
      WHERE i.invoice_date BETWEEN '2025-07-01' AND '2026-06-30'
      GROUP BY s.supplier_name
      ORDER BY total_invoiced DESC
  - name: approval_level_distribution_fy2026
    question: How are FY2026 purchase orders distributed across approval levels?
    verified_by: PeakFit Analytics
    sql: |
      SELECT po.approval_level, COUNT(po.po_id) AS po_count, ROUND(SUM(po.po_amount), 2) AS total_value
      FROM __po_transactions AS po
      WHERE po.financial_year = 'FY2026'
      GROUP BY po.approval_level
      ORDER BY total_value DESC
  - name: category_spend_fy2026
    question: What was approved spend by supplier category in FY2026?
    verified_by: PeakFit Analytics
    sql: |
      SELECT s.supplier_category, ROUND(SUM(po.po_amount), 2) AS approved_spend
      FROM __po_transactions AS po
      JOIN __suppliers AS s ON po.supplier_id = s.supplier_id
      WHERE po.po_status = 'Approved' AND po.financial_year = 'FY2026'
      GROUP BY s.supplier_category
      ORDER BY approved_spend DESC
$$);
