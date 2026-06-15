-- ================================================================
-- DataForRisk SQL — OPTIMISED
-- Source: dbo.Fulcrum_Infrastructure_Pipeline
-- Replicates: ConsolidatedData + DataForRisk Power Query steps
-- Run → right-click results → Save Results As → CSV
-- ================================================================
--
-- FIXES APPLIED 2026-06-15:
--   Boolean flag columns (_isprogram, chmp, conservation, drystonewalls,
--   native_veg_2005, 100yr_flood_waterways, risk_bushfire, dcpicp_land)
--   are stored as varchar 'TRUE'/'FALSE' in Fulcrum exports, not bit/int.
--   Replaced ISNULL([col], 0) = 1 with UPPER(ISNULL([col],'')) = 'TRUE'
--   to prevent implicit cast failure (Msg 245).
--
-- OPTIMISATIONS APPLIED 2026-06-15:
--   1. FilteredSource replaced by PreparedSource (SELECT * + computed cols):
--      All per-row scalar expressions (boolean flags, project ID null-fix,
--      child_program_test, ytd null-safe wrappers) are evaluated ONCE per
--      source row instead of ×217 (one per unpivoted financial column).
--   2. WithDerivedFields eliminated: FY label and CapitlizedBudgetCategory
--      are derived directly inside Unpivoted — one fewer full CTE pass.
--   3. Zero-budget filter pushed into Unpivoted (WHERE v.[Value] > 0)
--      so the final SELECT only processes funded rows rather than
--      filtering after a full 217-column expansion.
--
--   Net result: 4 steps → 2 CTEs + final SELECT.
--   ~10 CASE expressions evaluated 1× per row rather than 217× per row.
--
-- INDEX TIP (for larger datasets):
--   CREATE INDEX IX_FulcrumPipeline_NotCompleted
--   ON dbo.Fulcrum_Infrastructure_Pipeline (project_completed)
--   WHERE project_completed <> 'yes';
-- ================================================================

WITH

-- ================================================================
-- STEP 1: Filter completed projects + pre-compute all per-row
--         scalar expressions BEFORE the unpivot expansion.
--         SELECT * preserves all 217 financial columns for the
--         CROSS APPLY in Step 2 without re-listing them here.
-- ================================================================
PreparedSource AS (
    SELECT
        *,

        -- Null-safe project ID: computed once, not ×217 in the unpivot
        CASE
            WHEN NULLIF(LTRIM(RTRIM(ISNULL([_project_id_forreport], ''))), '') IS NULL
            THEN [fulcrum_id]
            ELSE [_project_id_forreport]
        END AS [_project_id_clean],

        -- Boolean risk flags: varchar 'TRUE'/'FALSE' → 'Yes'/'No'
        -- Resolved once per source row, not repeated per financial column
        CASE WHEN UPPER(ISNULL([chmp],                  '')) = 'TRUE' THEN 'Yes' ELSE 'No' END AS [chmp_yn],
        CASE WHEN UPPER(ISNULL([conservation],          '')) = 'TRUE' THEN 'Yes' ELSE 'No' END AS [conservation_yn],
        CASE WHEN UPPER(ISNULL([drystonewalls],         '')) = 'TRUE' THEN 'Yes' ELSE 'No' END AS [drystonewalls_yn],
        CASE WHEN UPPER(ISNULL([native_veg_2005],       '')) = 'TRUE' THEN 'Yes' ELSE 'No' END AS [native_veg_2005_yn],
        CASE WHEN UPPER(ISNULL([100yr_flood_waterways], '')) = 'TRUE' THEN 'Yes' ELSE 'No' END AS [100yr_flood_waterways_yn],
        CASE WHEN UPPER(ISNULL([risk_bushfire],         '')) = 'TRUE' THEN 'Yes' ELSE 'No' END AS [risk_bushfire_yn],
        CASE WHEN UPPER(ISNULL([dcpicp_land],           '')) = 'TRUE' THEN 'Yes' ELSE 'No' END AS [dcpicp_land_yn],

        -- child_program_test: resolved once per source row
        CASE
            WHEN UPPER(ISNULL([_isprogram], '')) = 'TRUE'
             AND [child_program] IN ('Passive Recreation Reserve', 'Shared Paths Construction Program')
            THEN [program_name]
            ELSE [child_program]
        END AS [child_program_test],

        -- YTD null-safe wrappers: resolved once per source row
        ISNULL([ytd_expenditure], 0) AS [ytd_expenditure_safe],
        ISNULL([ytd_forecast],    0) AS [ytd_forecast_safe],
        ISNULL([ytd_total],       0) AS [ytd_total_safe]

    FROM [dbo].[Fulcrum_Infrastructure_Pipeline]
    WHERE ISNULL([project_completed], '') <> 'yes'
),

-- ================================================================
-- STEP 2: Unpivot financial columns + derive FY and budget category.
--         Merges what was previously the separate WithDerivedFields CTE.
--         WHERE v.[Value] > 0 filters zero/null budget rows early,
--         before the final SELECT — equivalent to original MonthlyBudget > 0
--         but applied upstream to reduce rows carried forward.
-- ================================================================
Unpivoted AS (
    SELECT
        p.[_project_id_clean]               AS [_project_id_forreport],
        p.[fulcrum_id],
        p.[latitude],
        p.[longitude],
        p.[public_name],
        p.[public_description],
        p.[project_or_program_origin],
        p.[parent_program],
        p.[child_program],
        p.[child_program_test],
        p.[program_name],
        p.[ward_category],
        p.[suburb],
        p.[chmp_yn]                         AS [chmp],
        p.[conservation_yn]                 AS [conservation],
        p.[drystonewalls_yn]                AS [drystonewalls],
        p.[native_veg_2005_yn]              AS [native_veg_2005],
        p.[100yr_flood_waterways_yn]        AS [100yr_flood_waterways],
        p.[risk_bushfire_yn]                AS [risk_bushfire],
        p.[dcpicp_land_yn]                  AS [dcpicp_land],
        p.[asset_category],
        p.[project_type],
        p.[ytd_expenditure_safe]            AS [ytd_expenditure],
        p.[ytd_forecast_safe]               AS [ytd_forecast],
        p.[ytd_total_safe]                  AS [ytd_total],
        p.[approve_update],
        v.[Value]                           AS [MonthlyBudget],
        -- FY label: e.g. 'rates_24_25' → last 5 chars → '24_25' → '24/25'
        REPLACE(RIGHT(v.[ColName], 5), '_', '/') AS [FY],
        -- Budget category display name (was in WithDerivedFields, now inline)
        CASE LEFT(v.[ColName], CHARINDEX('_', v.[ColName]) - 1)
            WHEN 'rates'   THEN 'Council Rates'
            WHEN 'grant'   THEN 'Grants'
            WHEN 'reserve' THEN 'Council Reserve'
            WHEN 'dcpicp'  THEN 'Developer Contribution'
            WHEN 'loan'    THEN 'Loans'
            WHEN 'cf'      THEN 'Carried Forward'
            WHEN 'labour'  THEN 'Labour'
        END                                 AS [CapitlizedBudgetCategory]

    FROM PreparedSource p
    CROSS APPLY (VALUES
        ('rates_13_14',p.[rates_13_14]),('grant_13_14',p.[grant_13_14]),('reserve_13_14',p.[reserve_13_14]),('dcpicp_13_14',p.[dcpicp_13_14]),('loan_13_14',p.[loan_13_14]),('cf_13_14',p.[cf_13_14]),('labour_13_14',p.[labour_13_14]),
        ('rates_14_15',p.[rates_14_15]),('grant_14_15',p.[grant_14_15]),('reserve_14_15',p.[reserve_14_15]),('dcpicp_14_15',p.[dcpicp_14_15]),('loan_14_15',p.[loan_14_15]),('cf_14_15',p.[cf_14_15]),('labour_14_15',p.[labour_14_15]),
        ('rates_15_16',p.[rates_15_16]),('grant_15_16',p.[grant_15_16]),('reserve_15_16',p.[reserve_15_16]),('dcpicp_15_16',p.[dcpicp_15_16]),('loan_15_16',p.[loan_15_16]),('cf_15_16',p.[cf_15_16]),('labour_15_16',p.[labour_15_16]),
        ('rates_16_17',p.[rates_16_17]),('grant_16_17',p.[grant_16_17]),('reserve_16_17',p.[reserve_16_17]),('dcpicp_16_17',p.[dcpicp_16_17]),('loan_16_17',p.[loan_16_17]),('cf_16_17',p.[cf_16_17]),('labour_16_17',p.[labour_16_17]),
        ('rates_17_18',p.[rates_17_18]),('grant_17_18',p.[grant_17_18]),('reserve_17_18',p.[reserve_17_18]),('dcpicp_17_18',p.[dcpicp_17_18]),('loan_17_18',p.[loan_17_18]),('cf_17_18',p.[cf_17_18]),('labour_17_18',p.[labour_17_18]),
        ('rates_18_19',p.[rates_18_19]),('grant_18_19',p.[grant_18_19]),('reserve_18_19',p.[reserve_18_19]),('dcpicp_18_19',p.[dcpicp_18_19]),('loan_18_19',p.[loan_18_19]),('cf_18_19',p.[cf_18_19]),('labour_18_19',p.[labour_18_19]),
        ('rates_19_20',p.[rates_19_20]),('grant_19_20',p.[grant_19_20]),('reserve_19_20',p.[reserve_19_20]),('dcpicp_19_20',p.[dcpicp_19_20]),('loan_19_20',p.[loan_19_20]),('cf_19_20',p.[cf_19_20]),('labour_19_20',p.[labour_19_20]),
        ('rates_20_21',p.[rates_20_21]),('grant_20_21',p.[grant_20_21]),('reserve_20_21',p.[reserve_20_21]),('dcpicp_20_21',p.[dcpicp_20_21]),('loan_20_21',p.[loan_20_21]),('cf_20_21',p.[cf_20_21]),('labour_20_21',p.[labour_20_21]),
        ('rates_21_22',p.[rates_21_22]),('grant_21_22',p.[grant_21_22]),('reserve_21_22',p.[reserve_21_22]),('dcpicp_21_22',p.[dcpicp_21_22]),('loan_21_22',p.[loan_21_22]),('cf_21_22',p.[cf_21_22]),('labour_21_22',p.[labour_21_22]),
        ('rates_22_23',p.[rates_22_23]),('grant_22_23',p.[grant_22_23]),('reserve_22_23',p.[reserve_22_23]),('dcpicp_22_23',p.[dcpicp_22_23]),('loan_22_23',p.[loan_22_23]),('cf_22_23',p.[cf_22_23]),('labour_22_23',p.[labour_22_23]),
        ('rates_23_24',p.[rates_23_24]),('grant_23_24',p.[grant_23_24]),('reserve_23_24',p.[reserve_23_24]),('dcpicp_23_24',p.[dcpicp_23_24]),('loan_23_24',p.[loan_23_24]),('cf_23_24',p.[cf_23_24]),('labour_23_24',p.[labour_23_24]),
        ('rates_24_25',p.[rates_24_25]),('grant_24_25',p.[grant_24_25]),('reserve_24_25',p.[reserve_24_25]),('dcpicp_24_25',p.[dcpicp_24_25]),('loan_24_25',p.[loan_24_25]),('cf_24_25',p.[cf_24_25]),('labour_24_25',p.[labour_24_25]),
        ('rates_25_26',p.[rates_25_26]),('grant_25_26',p.[grant_25_26]),('reserve_25_26',p.[reserve_25_26]),('dcpicp_25_26',p.[dcpicp_25_26]),('loan_25_26',p.[loan_25_26]),('cf_25_26',p.[cf_25_26]),('labour_25_26',p.[labour_25_26]),
        ('rates_26_27',p.[rates_26_27]),('grant_26_27',p.[grant_26_27]),('reserve_26_27',p.[reserve_26_27]),('dcpicp_26_27',p.[dcpicp_26_27]),('loan_26_27',p.[loan_26_27]),('cf_26_27',p.[cf_26_27]),('labour_26_27',p.[labour_26_27]),
        ('rates_27_28',p.[rates_27_28]),('grant_27_28',p.[grant_27_28]),('reserve_27_28',p.[reserve_27_28]),('dcpicp_27_28',p.[dcpicp_27_28]),('loan_27_28',p.[loan_27_28]),('cf_27_28',p.[cf_27_28]),('labour_27_28',p.[labour_27_28]),
        ('rates_28_29',p.[rates_28_29]),('grant_28_29',p.[grant_28_29]),('reserve_28_29',p.[reserve_28_29]),('dcpicp_28_29',p.[dcpicp_28_29]),('loan_28_29',p.[loan_28_29]),('cf_28_29',p.[cf_28_29]),('labour_28_29',p.[labour_28_29]),
        ('rates_29_30',p.[rates_29_30]),('grant_29_30',p.[grant_29_30]),('reserve_29_30',p.[reserve_29_30]),('dcpicp_29_30',p.[dcpicp_29_30]),('loan_29_30',p.[loan_29_30]),('cf_29_30',p.[cf_29_30]),('labour_29_30',p.[labour_29_30]),
        ('rates_30_31',p.[rates_30_31]),('grant_30_31',p.[grant_30_31]),('reserve_30_31',p.[reserve_30_31]),('dcpicp_30_31',p.[dcpicp_30_31]),('loan_30_31',p.[loan_30_31]),('cf_30_31',p.[cf_30_31]),('labour_30_31',p.[labour_30_31]),
        ('rates_31_32',p.[rates_31_32]),('grant_31_32',p.[grant_31_32]),('reserve_31_32',p.[reserve_31_32]),('dcpicp_31_32',p.[dcpicp_31_32]),('loan_31_32',p.[loan_31_32]),('cf_31_32',p.[cf_31_32]),('labour_31_32',p.[labour_31_32]),
        ('rates_32_33',p.[rates_32_33]),('grant_32_33',p.[grant_32_33]),('reserve_32_33',p.[reserve_32_33]),('dcpicp_32_33',p.[dcpicp_32_33]),('loan_32_33',p.[loan_32_33]),('cf_32_33',p.[cf_32_33]),('labour_32_33',p.[labour_32_33]),
        ('rates_33_34',p.[rates_33_34]),('grant_33_34',p.[grant_33_34]),('reserve_33_34',p.[reserve_33_34]),('dcpicp_33_34',p.[dcpicp_33_34]),('loan_33_34',p.[loan_33_34]),('cf_33_34',p.[cf_33_34]),('labour_33_34',p.[labour_33_34]),
        ('rates_34_35',p.[rates_34_35]),('grant_34_35',p.[grant_34_35]),('reserve_34_35',p.[reserve_34_35]),('dcpicp_34_35',p.[dcpicp_34_35]),('loan_34_35',p.[loan_34_35]),('cf_34_35',p.[cf_34_35]),('labour_34_35',p.[labour_34_35]),
        ('rates_35_36',p.[rates_35_36]),('grant_35_36',p.[grant_35_36]),('reserve_35_36',p.[reserve_35_36]),('dcpicp_35_36',p.[dcpicp_35_36]),('loan_35_36',p.[loan_35_36]),('cf_35_36',p.[cf_35_36]),('labour_35_36',p.[labour_35_36]),
        ('rates_36_37',p.[rates_36_37]),('grant_36_37',p.[grant_36_37]),('reserve_36_37',p.[reserve_36_37]),('dcpicp_36_37',p.[dcpicp_36_37]),('loan_36_37',p.[loan_36_37]),('cf_36_37',p.[cf_36_37]),('labour_36_37',p.[labour_36_37]),
        ('rates_37_38',p.[rates_37_38]),('grant_37_38',p.[grant_37_38]),('reserve_37_38',p.[reserve_37_38]),('dcpicp_37_38',p.[dcpicp_37_38]),('loan_37_38',p.[loan_37_38]),('cf_37_38',p.[cf_37_38]),('labour_37_38',p.[labour_37_38]),
        ('rates_38_39',p.[rates_38_39]),('grant_38_39',p.[grant_38_39]),('reserve_38_39',p.[reserve_38_39]),('dcpicp_38_39',p.[dcpicp_38_39]),('loan_38_39',p.[loan_38_39]),('cf_38_39',p.[cf_38_39]),('labour_38_39',p.[labour_38_39]),
        ('rates_39_40',p.[rates_39_40]),('grant_39_40',p.[grant_39_40]),('reserve_39_40',p.[reserve_39_40]),('dcpicp_39_40',p.[dcpicp_39_40]),('loan_39_40',p.[loan_39_40]),('cf_39_40',p.[cf_39_40]),('labour_39_40',p.[labour_39_40]),
        ('rates_40_41',p.[rates_40_41]),('grant_40_41',p.[grant_40_41]),('reserve_40_41',p.[reserve_40_41]),('dcpicp_40_41',p.[dcpicp_40_41]),('loan_40_41',p.[loan_40_41]),('cf_40_41',p.[cf_40_41]),('labour_40_41',p.[labour_40_41]),
        ('rates_41_42',p.[rates_41_42]),('grant_41_42',p.[grant_41_42]),('reserve_41_42',p.[reserve_41_42]),('dcpicp_41_42',p.[dcpicp_41_42]),('loan_41_42',p.[loan_41_42]),('cf_41_42',p.[cf_41_42]),('labour_41_42',p.[labour_41_42]),
        ('rates_42_43',p.[rates_42_43]),('grant_42_43',p.[grant_42_43]),('reserve_42_43',p.[reserve_42_43]),('dcpicp_42_43',p.[dcpicp_42_43]),('loan_42_43',p.[loan_42_43]),('cf_42_43',p.[cf_42_43]),('labour_42_43',p.[labour_42_43]),
        ('rates_43_44',p.[rates_43_44]),('grant_43_44',p.[grant_43_44]),('reserve_43_44',p.[reserve_43_44]),('dcpicp_43_44',p.[dcpicp_43_44]),('loan_43_44',p.[loan_43_44]),('cf_43_44',p.[cf_43_44]),('labour_43_44',p.[labour_43_44])
    ) AS v([ColName], [Value])
    WHERE v.[Value] > 0   -- NULL and 0 both excluded; equivalent to original ISNULL(v.Value,0) > 0
)

-- ================================================================
-- STEP 3: Final output — clean select from pre-shaped Unpivoted CTE
-- ================================================================
SELECT
    ROW_NUMBER() OVER (ORDER BY (SELECT NULL))  AS [Index],
    [fulcrum_id]                                AS [fulcrum_id_risk],
    [_project_id_forreport],
    [latitude],
    [longitude],
    [public_name]                               AS [public_name_risk],
    [public_description]                        AS [public_description_risk],
    [project_or_program_origin],
    [parent_program],
    [child_program]                             AS [child_programrisk],
    [child_program_test],
    [program_name],
    [ward_category],
    [suburb],
    [chmp],
    [conservation],
    [drystonewalls],
    [native_veg_2005],
    [100yr_flood_waterways],
    [risk_bushfire],
    [dcpicp_land],
    [asset_category],
    [project_type],
    [ytd_expenditure],
    [ytd_forecast],
    [ytd_total],
    [approve_update],
    [MonthlyBudget],
    [FY],
    [CapitlizedBudgetCategory]
FROM Unpivoted
ORDER BY [fulcrum_id], [FY], [CapitlizedBudgetCategory]
