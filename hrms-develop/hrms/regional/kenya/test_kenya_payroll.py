# Copyright (c) 2026, Medware Solutions Ltd and Contributors
# License: GNU General Public License v3. See license.txt

import unittest

from hrms.payroll.utils import COMPONENT_EVAL_GLOBALS
from hrms.regional.kenya import setup as kenya


def reference_paye(taxable: float) -> float:
	"""Independent, straight-from-the-rules PAYE calculation (monthly)."""
	tax = 0.0
	tax += 0.10 * min(taxable, 24_000)
	if taxable > 24_000:
		tax += 0.25 * (min(taxable, 32_333) - 24_000)
	if taxable > 32_333:
		tax += 0.30 * (min(taxable, 500_000) - 32_333)
	if taxable > 500_000:
		tax += 0.325 * (min(taxable, 800_000) - 500_000)
	if taxable > 800_000:
		tax += 0.35 * (taxable - 800_000)
	return max(0.0, tax - 2_400)


def run_slip(gross: float) -> dict:
	"""Evaluate the generated formulas in the same order a Salary Structure does."""
	ctx = {"gross_pay": gross}
	for spec in kenya.get_salary_components():
		if spec["type"] == "Employer Contribution":
			continue
		ctx[spec["abbr"]] = eval(spec["formula"], dict(COMPONENT_EVAL_GLOBALS), ctx)  # noqa: S307
	for spec in kenya.get_salary_components():
		if spec["type"] == "Employer Contribution":
			ctx[spec["abbr"]] = eval(spec["formula"], dict(COMPONENT_EVAL_GLOBALS), ctx)  # noqa: S307
	return ctx


class TestKenyaPayrollFormulas(unittest.TestCase):
	def test_worked_example_100k(self):
		s = run_slip(100_000)
		self.assertAlmostEqual(s["NSSF"], 6_000)  # 6% of 100,000 (below the 108,000 UEL)
		self.assertAlmostEqual(s["AHL"], 1_500)  # 1.5%
		self.assertAlmostEqual(s["SHIF"], 2_750)  # 2.75%
		self.assertAlmostEqual(s["TXP"], 89_750)  # 100,000 - 6,000 - 1,500 - 2,750
		# 2,400 + 2,083.25 + 17,225.10 = 21,708.35 gross tax, less 2,400 relief
		self.assertAlmostEqual(s["PAYE"], 19_308.35, places=2)

	def test_paye_matches_reference_across_bands(self):
		for gross in (0, 15_000, 24_000, 30_000, 60_000, 150_000, 540_000, 900_000, 1_500_000):
			s = run_slip(gross)
			self.assertAlmostEqual(s["PAYE"], reference_paye(s["TXP"]), places=2, msg=f"gross={gross}")

	def test_low_earner_pays_no_paye(self):
		# relief wipes out tax at this level
		self.assertEqual(run_slip(20_000)["PAYE"], 0)

	def test_nssf_capped_at_upper_earnings_limit(self):
		self.assertAlmostEqual(run_slip(500_000)["NSSF"], 6_480)  # 6% of 108,000
		self.assertAlmostEqual(run_slip(500_000)["NSSF_ER"], 6_480)

	def test_shif_minimum_applies(self):
		self.assertEqual(run_slip(5_000)["SHIF"], 300)  # 2.75% = 137.5, below the 300 minimum

	def test_employer_contributions(self):
		s = run_slip(100_000)
		self.assertAlmostEqual(s["AHL_ER"], 1_500)
		self.assertEqual(s["NITA"], 50)

	def test_deductions_are_calculated_in_dependency_order(self):
		names = [c["abbr"] for c in kenya.get_salary_components() if c["type"] == "Deduction"]
		self.assertLess(names.index("NSSF"), names.index("TXP"))
		self.assertLess(names.index("SHIF"), names.index("TXP"))
		self.assertLess(names.index("AHL"), names.index("TXP"))
		self.assertLess(names.index("TXP"), names.index("PAYE"))


if __name__ == "__main__":
	unittest.main()
