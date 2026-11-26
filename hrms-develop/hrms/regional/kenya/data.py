# Copyright (c) 2026, Medware Solutions Ltd and Contributors
# License: GNU General Public License v3. See license.txt

"""Kenyan statutory payroll figures.

EVERYTHING that changes when the law changes lives in this file. The salary components and
their formulas are generated from these values, so to apply a rate change:

	1. edit the value below,
	2. run `bench --site <site> execute hrms.regional.kenya.setup.setup`
	   (existing components are updated in place; Salary Structures pick the new
	   formula up when they are next saved / new Salary Structure Assignments are made).

All amounts are KES per month. The figures below were entered from the published rules
and MUST be verified by your accountant / payroll lead before the first live payroll run.
Sources to check against: KRA (PAYE), NSSF Act 2013 rates schedule, Social Health Insurance
Act 2023 (SHIF), Affordable Housing Act 2024 (AHL), NITA Act.
"""

# --- PAYE (Income Tax Act, 5th schedule; bands effective since 1 Jul 2023) -------------------
# (width of band in KES per month, rate). `None` width = everything above the previous bands.
PAYE_BANDS = [
	(24_000, 0.10),  # first 24,000
	(8_333, 0.25),  # next 8,333   (24,001 - 32,333)
	(467_667, 0.30),  # next 467,667 (32,334 - 500,000)
	(300_000, 0.325),  # next 300,000 (500,001 - 800,000)
	(None, 0.35),  # above 800,000
]

# Monthly personal relief, deducted from the tax computed on the bands.
PERSONAL_RELIEF = 2_400

# --- NSSF (NSSF Act 2013, tiered contributions) --------------------------------------------
# Employee and employer each pay `rate` of pensionable pay up to the Upper Earnings Limit.
# Tier I covers pay up to the Lower Earnings Limit, Tier II covers pay between the limits.
# Limits step up each February under the Act - UPDATE EACH FEBRUARY.
NSSF_RATE = 0.06
NSSF_LOWER_EARNINGS_LIMIT = 9_000  # Feb 2026 onwards (Year 3)
NSSF_UPPER_EARNINGS_LIMIT = 108_000  # Feb 2026 onwards (Year 3)

# --- SHIF (Social Health Insurance Act 2023; replaced NHIF in Oct 2024) -------------------
# Employee-only contribution on gross pay, with a monthly minimum and no cap.
SHIF_RATE = 0.0275
SHIF_MINIMUM = 300

# --- Affordable Housing Levy (Affordable Housing Act 2024) ---------------------------------
# 1.5% of gross pay from the employee and a matching 1.5% from the employer.
AHL_EMPLOYEE_RATE = 0.015
AHL_EMPLOYER_RATE = 0.015

# --- NITA levy (employer only, flat per employee per month) --------------------------------
NITA_LEVY = 50

# --- Statutory leave (Employment Act 2007) -------------------------------------------------
# (name, days per year, extra Leave Type options)
LEAVE_TYPES = [
	("Annual Leave", 21, {"is_carry_forward": 1, "include_holiday": 0}),
	("Sick Leave (Full Pay)", 7, {"include_holiday": 0}),
	("Sick Leave (Half Pay)", 7, {"include_holiday": 0, "is_ppl": 1, "fraction_of_daily_salary_per_leave": 0.5}),
	("Maternity Leave", 90, {"include_holiday": 1, "max_continuous_days_allowed": 90}),
	("Paternity Leave", 14, {"include_holiday": 1, "max_continuous_days_allowed": 14}),
]
