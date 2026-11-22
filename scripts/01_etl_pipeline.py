import pandas as pd
import numpy as np
from sqlalchemy import create_engine

# 1. CONFIGURATION
CSV_PATH = "../data/raw_bank_churn.csv"
DB_USER = "root"
DB_PASSWORD = "Data_Analyst2026"  
DB_HOST = "localhost"
DB_PORT = "3306"
DB_NAME = "retail_bank_dw"

# 2. EXTRACT
print("Loading raw dataset...")
df = pd.read_csv(CSV_PATH)
print(f"Initial shape: {df.shape}")

# 3. TRANSFORM & CLEAN
if "RowNumber" in df.columns:
    df.drop(columns=["RowNumber"], inplace=True)

# Remove exact duplicates based on CustomerId
df.drop_duplicates(subset=["CustomerId"], keep="first", inplace=True)

# Standardize text fields (trim whitespace & title-case)
df["Geography"] = df["Geography"].str.strip().str.title()
df["Gender"] = df["Gender"].str.strip().str.title()
df["Surname"] = df["Surname"].str.strip().str.title()

# Handle any unexpected nulls safely
df["CreditScore"] = df["CreditScore"].fillna(df["CreditScore"].median())
df["Age"] = df["Age"].fillna(df["Age"].median())
df["Balance"] = df["Balance"].fillna(0.0)
df["EstimatedSalary"] = df["EstimatedSalary"].fillna(df["EstimatedSalary"].median())

# Enforce clean data types
int_cols = ["CustomerId", "CreditScore", "Age", "Tenure", "NumOfProducts", "HasCrCard", "IsActiveMember", "Exited"]
for col in int_cols:
    df[col] = df[col].astype(int)

# 4. FEATURE ENGINEERING (Adding business context for SQL & Power BI)
# Age brackets
df["Age_Group"] = pd.cut(
    df["Age"],
    bins=[17, 29, 44, 59, 100],
    labels=["18-29 (Young Adult)", "30-44 (Early Career)", "45-59 (Mid-Late Career)", "60+ (Senior)"]
).astype(str)

# Credit score tiers
df["Credit_Tier"] = pd.cut(
    df["CreditScore"],
    bins=[0, 579, 669, 739, 850],
    labels=["Poor (<580)", "Fair (580-669)", "Good (670-739)", "Excellent (740+)"]
).astype(str)

# Tenure segments
df["Tenure_Group"] = pd.cut(
    df["Tenure"],
    bins=[-1, 2, 5, 10],
    labels=["New (0-2 yrs)", "Established (3-5 yrs)", "Loyal (6-10 yrs)"]
).astype(str)

# Balance-to-Salary Ratio (Financial leverage / wallet share indicator)
df["Balance_Salary_Ratio"] = np.where(
    df["EstimatedSalary"] > 0,
    np.round(df["Balance"] / df["EstimatedSalary"], 2),
    0.0
)

# Zero-balance flag (Common banking churn indicator)
df["Is_Zero_Balance"] = np.where(df["Balance"] == 0, 1, 0)

df.rename(columns={
    "CustomerId": "customer_id",
    "Surname": "surname",
    "CreditScore": "credit_score",
    "Geography": "geography",
    "Gender": "gender",
    "Age": "age",
    "Tenure": "tenure",
    "Balance": "balance",
    "NumOfProducts": "num_of_products",
    "HasCrCard": "has_credit_card",
    "IsActiveMember": "is_active_member",
    "EstimatedSalary": "estimated_salary",
    "Exited": "is_churned",
    "Age_Group": "age_group",
    "Credit_Tier": "credit_tier",
    "Tenure_Group": "tenure_group",
    "Balance_Salary_Ratio": "balance_salary_ratio",
    "Is_Zero_Balance": "is_zero_balance"
}, inplace=True)

df.to_csv("../data/cleaned_bank_churn.csv", index=False)

print("Connecting to MySQL and loading staging table...")
connection_string = f"mysql+mysqlconnector://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
engine = create_engine(connection_string)

df.to_sql(name="stg_bank_churn", con=engine, if_exists="replace", index=False)
print(f"Success! Loaded {len(df)} cleaned rows into 'retail_bank_dw.stg_bank_churn'.")