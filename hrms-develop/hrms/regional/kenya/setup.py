# Copyright (c) 2026, Medware Solutions Ltd and Contributors
# License: GNU General Public License v3. See license.txt

"""Kenya payroll localisation.

`setup()` is called by HRMS when a company with country = Kenya is created. It can also be
run by hand at any time (it is idempotent, and updates components in place):

	bench --site <site> execute hrms.regional.kenya.setup.setup

What it creates
	* Employee fields: KRA PIN, National ID, NSSF No., SHA (SHIF) No.
	* Salary Components: NSSF, SHIF, Affordable Housing Levy and PAYE (deductions) and the
	  employer-side NSSF, Housing Levy and NITA, plus a statistical "Taxable Pay" line.
	* Employment Act 2007 Leave Types.
	* A "Kenya Standard" Salary Structure for each Kenyan company.

All rates and limits come from `hrms/regional/kenya/data.py`.
"""

import frappe
from frappe.custom.doctype.custom_field.custom_field import create_custom_fields

from hrms.regional.kenya import data
from hrms.setup import delete_custom_fields

COUNTRY = "Kenya"

# Abbreviations double as variable names inside formulas, so keep them valid identifiers.
ABBR_NSSF = "NSSF"
ABBR_SHIF = "SHIF"
ABBR_AHL = "AHL"
ABBR_TAXABLE = "TXP"
ABBR_PAYE = "PAYE"
ABBR_NSSF_ER = "NSSF_ER"
ABBR_AHL_ER = "AHL_ER"
ABBR_NITA = "NITA"


def setup():
	make_custom_fields()
	create_salary_components()
	create_leave_types()
	for company in frappe.get_all("Company", filters={"country": COUNTRY}, pluck="name"):
		create_salary_structure(company)


def uninstall():
	delete_custom_fields(get_custom_fields())


# --- custom fields --------------------------------------------------------------------------


def make_custom_fields(update=True):
	create_custom_fields(get_custom_fields(), update=update)


def get_custom_fields():
	return {
		"Employee": [
			{
				"fieldname": "kenya_statutory_section",
				"label": "Statutory IDs (Kenya)",
				"fieldtype": "Section Break",
				"insert_after": "passport_number",
				"collapsible": 1,
			},
			{
				"fieldname": "kra_pin",
				"label": "KRA PIN",
				"fieldtype": "Data",
				"insert_after": "kenya_statutory_section",
				"description": "e.g. A123456789Z",
				"translatable": 0,
			},
			{
				"fieldname": "national_id_number",
				"label": "National ID Number",
				"fieldtype": "Data",
				"insert_after": "kra_pin",
				"translatable": 0,
			},
			{
				"fieldname": "kenya_statutory_column",
				"fieldtype": "Column Break",
				"insert_after": "national_id_number",
			},
			{
				"fieldname": "nssf_number",
				"label": "NSSF Number",
				"fieldtype": "Data",
				"insert_after": "kenya_statutory_column",
				"translatable": 0,
			},
			{
				"fieldname": "sha_number",
				"label": "SHA / SHIF Number",
				"fieldtype": "Data",
				"insert_after": "nssf_number",
				"translatable": 0,
			},
		]
	}


# --- formulas (pure functions of data.py, so they can be unit tested) -------------------------


def _num(value) -> str:
	return repr(value) if isinstance(value, float) else str(value)


def nssf_formula() -> str:
	"""6% of pensionable pay up to the Upper Earnings Limit (Tier I + Tier II combined)."""
	return f"{_num(data.NSSF_RATE)} * min(gross_pay, {_num(data.NSSF_UPPER_EARNINGS_LIMIT)})"


def shif_formula() -> str:
	return f"max({_num(data.SHIF_MINIMUM)}, {_num(data.SHIF_RATE)} * gross_pay)"


def ahl_formula(rate) -> str:
	return f"{_num(rate)} * gross_pay"


def taxable_pay_formula() -> str:
	# NSSF, SHIF and the Housing Levy are all deductible before PAYE is worked out.
	return f"max(0, gross_pay - {ABBR_NSSF} - {ABBR_SHIF} - {ABBR_AHL})"


def paye_formula() -> str:
	"""Progressive monthly PAYE on Taxable Pay, less personal relief, never below zero."""
	terms = []
	lower = 0
	for width, rate in data.PAYE_BANDS:
		if width is None:
			terms.append(f"{_num(rate)} * max(0, {ABBR_TAXABLE} - {lower})")
		else:
			upper = lower + width
			terms.append(f"{_num(rate)} * max(0, min({ABBR_TAXABLE}, {upper}) - {lower})")
			lower = upper
	return f"max(0, {' + '.join(terms)} - {_num(data.PERSONAL_RELIEF)})"


# --- salary components ---------------------------------------------------------------------


def get_salary_components() -> list[dict]:
	return [
		{
			"salary_component": "NSSF (Employee)",
			"abbr": ABBR_NSSF,
			"type": "Deduction",
			"formula": nssf_formula(),
			"description": "NSSF Tier I + Tier II employee contribution",
		},
		{
			"salary_component": "SHIF",
			"abbr": ABBR_SHIF,
			"type": "Deduction",
			"formula": shif_formula(),
			"description": "Social Health Insurance Fund (employee)",
		},
		{
			"salary_component": "Affordable Housing Levy (Employee)",
			"abbr": ABBR_AHL,
			"type": "Deduction",
			"formula": ahl_formula(data.AHL_EMPLOYEE_RATE),
			"description": "Affordable Housing Levy - employee share",
		},
		{
			# Shown on the payslip but not part of total deductions.
			"salary_component": "Taxable Pay",
			"abbr": ABBR_TAXABLE,
			"type": "Deduction",
			"formula": taxable_pay_formula(),
			"statistical_component": 1,
			"do_not_include_in_total": 1,
			"description": "Gross pay less NSSF, SHIF and Housing Levy",
		},
		{
			"salary_component": "PAYE",
			"abbr": ABBR_PAYE,
			"type": "Deduction",
			"formula": paye_formula(),
			"description": "Pay As You Earn income tax, after personal relief",
		},
		{
			"salary_component": "NSSF (Employer)",
			"abbr": ABBR_NSSF_ER,
			"type": "Employer Contribution",
			"formula": nssf_formula(),
			"description": "NSSF employer matching contribution",
		},
		{
			"salary_component": "Affordable Housing Levy (Employer)",
			"abbr": ABBR_AHL_ER,
			"type": "Employer Contribution",
			"formula": ahl_formula(data.AHL_EMPLOYER_RATE),
			"description": "Affordable Housing Levy - employer share",
		},
		{
			"salary_component": "NITA Levy",
			"abbr": ABBR_NITA,
			"type": "Employer Contribution",
			"formula": _num(data.NITA_LEVY),
			"description": "National Industrial Training Authority levy",
		},
	]


def create_salary_components():
	for spec in get_salary_components():
		values = {
			"salary_component_abbr": spec["abbr"],
			"type": spec["type"],
			"description": spec["description"],
			"amount_based_on_formula": 1,
			"formula": spec["formula"],
			"depends_on_payment_days": 0,
			"statistical_component": spec.get("statistical_component", 0),
			"do_not_include_in_total": spec.get("do_not_include_in_total", 0),
			# Statutory deductions come off pay before tax: they must not be re-taxed.
			"is_tax_applicable": 0,
		}
		name = spec["salary_component"]
		if frappe.db.exists("Salary Component", name):
			doc = frappe.get_doc("Salary Component", name)
			doc.update(values)
		else:
			doc = frappe.get_doc({"doctype": "Salary Component", "salary_component": name, **values})
		doc.flags.ignore_permissions = True
		doc.save()


# --- leave ----------------------------------------------------------------------------------


def create_leave_types():
	for name, days, extra in data.LEAVE_TYPES:
		if frappe.db.exists("Leave Type", name):
			continue
		doc = frappe.get_doc(
			{"doctype": "Leave Type", "leave_type_name": name, "max_leaves_allowed": days, **extra}
		)
		doc.flags.ignore_permissions = True
		doc.insert()


# --- salary structure -----------------------------------------------------------------------


def create_salary_structure(company: str) -> str | None:
	"""Create (and submit) the 'Kenya Standard' structure for `company` if it doesn't exist."""
	company_abbr = frappe.get_cached_value("Company", company, "abbr")
	name = f"Kenya Standard - {company_abbr}"
	if frappe.db.exists("Salary Structure", name):
		return name

	basic = _ensure_basic_component()

	def row(component: str, formula: str, **extra) -> dict:
		return {
			"salary_component": component,
			"amount_based_on_formula": 1,
			"formula": formula,
			**extra,
		}

	by_abbr = {s["abbr"]: s for s in get_salary_components()}

	def comp_row(abbr: str) -> dict:
		spec = by_abbr[abbr]
		extra = {k: spec[k] for k in ("statistical_component", "do_not_include_in_total") if k in spec}
		return row(spec["salary_component"], spec["formula"], **extra)

	# Order matters: each formula can only use components calculated before it.
	doc = frappe.get_doc(
		{
			"doctype": "Salary Structure",
			"__newname": name,
			"name": name,
			"company": company,
			"currency": "KES",
			"payroll_frequency": "Monthly",
			"is_active": "Yes",
			"earnings": [row(basic, "base", depends_on_payment_days=1)],
			"deductions": [
				comp_row(ABBR_NSSF),
				comp_row(ABBR_SHIF),
				comp_row(ABBR_AHL),
				comp_row(ABBR_TAXABLE),
				comp_row(ABBR_PAYE),
			],
			"employer_contributions": [
				comp_row(ABBR_NSSF_ER),
				comp_row(ABBR_AHL_ER),
				comp_row(ABBR_NITA),
			],
		}
	)
	doc.flags.ignore_permissions = True
	doc.insert()
	doc.submit()
	return doc.name


def _ensure_basic_component() -> str:
	if frappe.db.exists("Salary Component", "Basic"):
		return "Basic"
	doc = frappe.get_doc(
		{
			"doctype": "Salary Component",
			"salary_component": "Basic",
			"salary_component_abbr": "B",
			"type": "Earning",
			"is_tax_applicable": 1,
			"depends_on_payment_days": 1,
		}
	)
	doc.flags.ignore_permissions = True
	doc.insert()
	return doc.name
