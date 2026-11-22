CREATE DATABASE IF NOT EXISTS retail_bank_dw;

USE retail_bank_dw;

-- Drop existing tables/views if re-running script
DROP VIEW IF EXISTS vw_executive_churn;
DROP VIEW IF EXISTS vw_retention_targets;
DROP TABLE IF EXISTS fact_account_metrics;
DROP TABLE IF EXISTS dim_customers;
DROP TABLE IF EXISTS dim_geography;

-- 1. DIMENSION TABLE: Geography
CREATE TABLE dim_geography (
    geo_id INT AUTO_INCREMENT PRIMARY KEY,
    geography_name VARCHAR(50) NOT NULL UNIQUE
);

INSERT INTO dim_geography (geography_name)
SELECT DISTINCT geography
FROM stg_bank_churn
ORDER BY geography;

-- 2. DIMENSION TABLE: Customers
CREATE TABLE dim_customers (
    customer_id INT PRIMARY KEY,
    surname VARCHAR(100) NOT NULL,
    gender VARCHAR(20) NOT NULL,
    age INT NOT NULL,
    age_group VARCHAR(30) NOT NULL,
    geo_id INT NOT NULL,
    FOREIGN KEY (geo_id) REFERENCES dim_geography(geo_id)
);

INSERT INTO dim_customers (customer_id, surname, gender, age, age_group, geo_id)
SELECT 
    s.customer_id,
    s.surname,
    s.gender,
    s.age,
    s.age_group,
    g.geo_id
FROM stg_bank_churn s
JOIN dim_geography g ON s.geography = g.geography_name;

-- 3. FACT TABLE: Account Metrics & Churn Outcome
CREATE TABLE fact_account_metrics (
    account_fact_id INT AUTO_INCREMENT PRIMARY KEY,
    customer_id INT NOT NULL,
    credit_score INT NOT NULL,
    credit_tier VARCHAR(30) NOT NULL,
    tenure INT NOT NULL,
    tenure_group VARCHAR(30) NOT NULL,
    balance DECIMAL(15, 2) NOT NULL,
    num_of_products INT NOT NULL,
    has_credit_card TINYINT(1) NOT NULL,
    is_active_member TINYINT(1) NOT NULL,
    estimated_salary DECIMAL(15, 2) NOT NULL,
    balance_salary_ratio DECIMAL(10, 2) NOT NULL,
    is_zero_balance TINYINT(1) NOT NULL,
    is_churned TINYINT(1) NOT NULL,
    FOREIGN KEY (customer_id) REFERENCES dim_customers(customer_id)
);

INSERT INTO fact_account_metrics (
    customer_id, credit_score, credit_tier, tenure, tenure_group,
    balance, num_of_products, has_credit_card, is_active_member,
    estimated_salary, balance_salary_ratio, is_zero_balance, is_churned
)
SELECT 
    customer_id, credit_score, credit_tier, tenure, tenure_group,
    balance, num_of_products, has_credit_card, is_active_member,
    estimated_salary, balance_salary_ratio, is_zero_balance, is_churned
FROM stg_bank_churn;

-- Verify row counts across Star Schema
SELECT 
    (SELECT COUNT(*) FROM dim_geography) AS geo_rows,
    (SELECT COUNT(*) FROM dim_customers) AS customer_rows,
    (SELECT COUNT(*) FROM fact_account_metrics) AS fact_rows;
    
-- Q1: Executive Baseline - Overall Churn Rate & Lost Deposit Balance
SELECT 
    COUNT(*) AS total_customers,
    SUM(is_churned) AS churned_customers,
    ROUND(AVG(is_churned) * 100, 2) AS churn_rate_pct,
    ROUND(SUM(CASE WHEN is_churned = 1 THEN balance ELSE 0 END), 2) AS total_lost_balance,
    ROUND(AVG(CASE WHEN is_churned = 1 THEN balance END), 2) AS avg_churned_balance
FROM fact_account_metrics;

-- Q2: Regional & Age Bracket Risk Matrix (CTE + Window Function Share of Churn)
WITH segment_churn AS (
    SELECT 
        g.geography_name,
        c.age_group,
        COUNT(*) AS total_customers,
        SUM(f.is_churned) AS churned_count,
        ROUND(AVG(f.is_churned) * 100, 2) AS churn_rate_pct,
        ROUND(SUM(CASE WHEN f.is_churned = 1 THEN f.balance ELSE 0 END), 2) AS lost_balance
    FROM fact_account_metrics f
    JOIN dim_customers c ON f.customer_id = c.customer_id
    JOIN dim_geography g ON c.geo_id = g.geo_id
    GROUP BY g.geography_name, c.age_group
)
SELECT 
    *,
    ROUND(churned_count * 100.0 / SUM(churned_count) OVER (), 2) AS pct_of_all_churns,
    RANK() OVER (ORDER BY churn_rate_pct DESC) AS risk_rank
FROM segment_churn
ORDER BY risk_rank;

-- Q3: Product Holding & Activity Impact (Identifying the "3+ Products" Anomaly)
SELECT 
    num_of_products,
    CASE WHEN is_active_member = 1 THEN 'Active' ELSE 'Inactive' END AS member_status,
    COUNT(*) AS customer_count,
    SUM(is_churned) AS churned_count,
    ROUND(AVG(is_churned) * 100, 2) AS churn_rate_pct,
    ROUND(AVG(balance), 2) AS avg_balance
FROM fact_account_metrics
GROUP BY num_of_products, is_active_member
ORDER BY num_of_products, is_active_member DESC;

-- Q4: Top 20% High-Value Active Customers at Highest Risk of Leaving (NTILE Window Function)
WITH balance_quartiles AS (
    SELECT 
        c.customer_id,
        c.surname,
        g.geography_name,
        c.age,
        f.balance,
        f.num_of_products,
        f.is_active_member,
        f.is_churned,
        NTILE(5) OVER (ORDER BY f.balance DESC) AS balance_quintile
    FROM fact_account_metrics f
    JOIN dim_customers c ON f.customer_id = c.customer_id
    JOIN dim_geography g ON c.geo_id = g.geo_id
)
SELECT *
FROM balance_quartiles
WHERE balance_quintile = 1 -- Top 20% by balance
  AND is_active_member = 0
  AND is_churned = 0       -- Still retained, prime targets for retention outreach
ORDER BY balance DESC
LIMIT 25;

-- View 1: Full Denormalized Star-Schema View for Power BI Interactive Slicing
CREATE VIEW vw_executive_churn AS
SELECT 
    c.customer_id,
    c.surname,
    c.gender,
    c.age,
    c.age_group,
    g.geography_name AS geography,
    f.credit_score,
    f.credit_tier,
    f.tenure,
    f.tenure_group,
    f.balance,
    f.num_of_products,
    CASE WHEN f.has_credit_card = 1 THEN 'Yes' ELSE 'No' END AS has_credit_card,
    CASE WHEN f.is_active_member = 1 THEN 'Active' ELSE 'Inactive' END AS activity_status,
    f.estimated_salary,
    f.balance_salary_ratio,
    CASE WHEN f.is_zero_balance = 1 THEN 'Zero Balance' ELSE 'Funded Account' END AS account_funding_status,
    f.is_churned,
    CASE WHEN f.is_churned = 1 THEN 'Churned' ELSE 'Retained' END AS churn_status
FROM fact_account_metrics f
JOIN dim_customers c ON f.customer_id = c.customer_id
JOIN dim_geography g ON c.geo_id = g.geo_id;

-- View 2: High-Priority Retention Action List (Active/Funded Retained Customers with High Risk Profile)
CREATE VIEW vw_retention_targets AS
SELECT 
    customer_id,
    surname,
    geography,
    gender,
    age,
    age_group,
    credit_tier,
    balance,
    num_of_products,
    activity_status,
    CASE 
        WHEN age >= 45 AND activity_status = 'Inactive' AND balance > 100000 THEN 'Critical Priority'
        WHEN (age >= 45 OR num_of_products >= 3) AND balance > 50000 THEN 'High Priority'
        ELSE 'Standard Monitor'
    END AS retention_priority
FROM vw_executive_churn
WHERE is_churned = 0
  AND balance > 0;