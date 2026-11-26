# Medware HR: technical documentation

This repository is a customised copy of [Frappe HR (frappe/hrms)](https://github.com/frappe/hrms), `develop` branch (version 17.0.0-dev), adapted for Medware Solutions Ltd in Kenya. The app name stays `hrms` internally so upstream updates remain mergeable.

Customisations so far:

1. [Branding](#1-branding)
2. [Kenya payroll localisation](#2-kenya-payroll-localisation)
3. [Local development environment](#3-local-development-environment)

Integrations are planned but not built yet. See [Roadmap](#5-roadmap-and-known-gaps).

---

## 1. Branding

The visible product name is **Medware HR**. Brand colours come from the company logo: blue `#1A66AE`, navy `#0B2A4A`.

| Area | File(s) | Change |
|---|---|---|
| App name, publisher, logo | `hrms/hooks.py` | `app_title`, `app_publisher`, `app_logo_url`, and the `add_to_apps_screen` entry |
| Desk icons | `hrms/desktop_icon/*.json` | Parent icon renamed to "Medware HR". **Every child icon's `parent_icon` must match the parent's name exactly** |
| Navbar logo on install | `hrms/subscription_utils.py` | Points at the Medware logo |
| Logos | `hrms/public/images/medware-logo.png` (for light backgrounds), `medware-logo-dark.png` (original, for dark backgrounds) | The original logo has white text. The light version recolours the white to navy `#0B2A4A` |
| PWA / mobile icons | `hrms/public/manifest/manifest-icon-{192,512}.maskable.png`, `apple-icon-180.png`, `frontend/public/favicon.png` | Generated from the "M" mark |
| Mobile app text and theme | `frontend/index.html`, `frontend/vite.config.js`, `frontend/src/components/{BaseLayout,InstallPrompt}.vue`, `frontend/src/views/Login.vue` | "Frappe HR" replaced by "Medware HR". Theme colour is `#1A66AE` |

Not rebranded yet:

- the 35 iOS splash screens in `hrms/public/manifest/`
- `app_email` and `source_link` in `hooks.py`
- the README header and logo
- the install messages in `hrms/install.py`
- licence headers, which should stay as they are

After changing frontend files, rebuild with `bench build --app hrms`.

## 2. Kenya payroll localisation

Location: `hrms/regional/kenya/`. It follows the same pattern as the existing `india` and `united_arab_emirates` modules. HRMS calls `hrms.regional.kenya.setup.setup()` automatically when a company with country = Kenya is created. `get_custom_fields()` is read by `hrms/setup.py`.

### Files

| File | Purpose |
|---|---|
| `data.py` | **All statutory rates and limits.** The only file to edit when the law changes |
| `setup.py` | Builds custom fields, salary components (and their formulas), leave types and the salary structure from `data.py` |
| `data/salary_components.json` | Intentionally empty (`[]`). The generic loader in `hrms/overrides/company.py` expects the file to exist |
| `test_kenya_payroll.py` | Unit tests for the formulas |

### What `setup()` creates

It is idempotent. Re-running it updates components in place.

- **Employee fields** (section "Statutory IDs (Kenya)"): `kra_pin`, `national_id_number`, `nssf_number`, `sha_number`.
- **Deductions**, calculated in this order (a formula can only use components calculated before it):

  | Order | Component | Abbr | Formula (current rates) |
  |---|---|---|---|
  | 1 | NSSF (Employee) | `NSSF` | `0.06 * min(gross_pay, 108000)` |
  | 2 | SHIF | `SHIF` | `max(300, 0.0275 * gross_pay)` |
  | 3 | Affordable Housing Levy (Employee) | `AHL` | `0.015 * gross_pay` |
  | 4 | Taxable Pay (statistical, not in total deductions) | `TXP` | `max(0, gross_pay - NSSF - SHIF - AHL)` |
  | 5 | PAYE | `PAYE` | banded tax on `TXP`, less KES 2,400 relief, minimum 0 |

- **Employer contributions**: NSSF (Employer) `NSSF_ER`, Affordable Housing Levy (Employer) `AHL_ER`, NITA Levy `NITA` (flat KES 50).
- **Leave types** (Employment Act 2007): Annual 21 days (carry forward), Sick (Full Pay) 7, Sick (Half Pay) 7 at 50% pay, Maternity 90, Paternity 14.
- **Salary Structure** `Kenya Standard - <company abbr>` per Kenyan company. It has Basic as `base`, the deductions above and the employer contributions. It is submitted on creation.

### Rates currently in `data.py`

**These were entered from published rules and have not been verified by a Kenyan payroll or tax professional. Verify every figure before the first live payroll run.**

| Item | Value | Check against |
|---|---|---|
| PAYE bands (monthly) | 0–24,000 at 10%; next 8,333 at 25%; next 467,667 at 30%; next 300,000 at 32.5%; above 800,000 at 35% | KRA PAYE rates |
| Personal relief | KES 2,400 per month | KRA |
| NSSF | 6% employee + 6% employer, Lower Earnings Limit 9,000, Upper Earnings Limit 108,000 (Feb 2026 limits) | NSSF Act 2013 schedule. **Limits change every February** |
| SHIF | 2.75% of gross, minimum KES 300, no cap | Social Health Insurance Act 2023 |
| Affordable Housing Levy | 1.5% employee + 1.5% employer | Affordable Housing Act 2024 |
| NITA | KES 50 per employee per month (employer) | NITA |

Modelling assumptions:

- NSSF, SHIF and the Housing Levy are treated as deductible before PAYE.
- PAYE is computed monthly and non-cumulatively on that month's taxable pay. The built-in HRMS income-tax slab engine projects annual tax instead, which does not match Kenya's monthly method.
- Amounts are not rounded to whole shillings.

Not modelled yet:

- insurance relief
- pension-contribution limits
- benefits in kind
- disability exemption
- PAYE on bonuses or arrears
- loans and SACCO deductions

### Changing a rate

1. Edit `hrms/regional/kenya/data.py`.
2. Run the tests (below).
3. Re-run setup: `bench --site <site> execute hrms.regional.kenya.setup.setup`.
4. Existing Salary Structures keep the formula they were created with. Edit them (or create a new structure and new Salary Structure Assignments) to pick up the new formula.

### Tests

The tests check the generated formulas against an independent reference calculation, including a worked KES 100,000 example (PAYE 19,308.35). They cover the maths only. They do **not** yet cover a real Salary Slip run through HRMS.

```bash
cd /home/frappe/frappe-bench   # inside the container
./env/bin/python -m unittest hrms.regional.kenya.test_kenya_payroll -v
```

## 3. Local development environment

Docker Desktop is required. Files are in `docker/`.

| File | Purpose |
|---|---|
| `docker-compose.yml` | MariaDB 11.8, Redis, and a `frappe/bench` container that mounts this repo (`..`) at `/workspace` |
| `init.sh` | First-run setup: builds the bench from Frappe and ERPNext `develop`, soft-links this repo as the `hrms` app, creates the site. If a bench already exists it just runs `bench start` |
| `finish.sh` | Resumes setup in an existing bench: links HRMS, creates the site if missing, installs ERPNext and HRMS |

```bash
docker compose -f docker/docker-compose.yml up -d
```

- Site: `medware.localhost`, served at <http://localhost:8000>.
- Dev login: `Administrator` / `admin`. **Local use only. Never reuse these credentials in production.**

### Behaviour worth knowing

- **Use `exec bench start`.** It must stay the container's main process. Killing it stops the container, and without `exec` the script fell through into `bench init`, which could rebuild a nested bench.
- **MariaDB 11.8, not 10.8.** The newer client requires TLS, which MariaDB 10.8 does not offer.
- **`bench get-app --soft-link <local path>` fails** with `'App' object has no attribute 'org'`. Scripts link the repo manually (`ln -sfn /workspace apps/hrms` plus `uv pip install -e`).
- **The web server binds to `0.0.0.0`.** The Procfile runs `bench serve --port 8000 --host 0.0.0.0`. Without `--host`, the app is unreachable through Docker's port mapping.
- **GitHub can be flaky on some networks.** `init.sh` retries `bench init` and `get-app` up to 6 times.
- **Shell scripts need LF line endings** (`docker/.gitattributes` enforces this). CRLF breaks them inside the Linux container.
- **Git Bash on Windows rewrites paths** in `docker exec` arguments. Prefix with `MSYS_NO_PATHCONV=1`.
- The frontend and asset build (`bench build --app hrms`) is slow on a poor connection, since it runs `yarn install` and a Vite build.

### Going to production

The dev server is not suitable for production. Production should use a standard Frappe deployment (supervisor/nginx or frappe_docker production images), a managed MariaDB, HTTPS, changed credentials, `developer_mode` off, and backups. None of this is set up yet.

## 4. Upstream merges

Because this is a direct edit of the upstream source, merges from `frappe/hrms` can conflict in these files: `hooks.py`, `desktop_icon/*.json`, the `frontend/` files above, and `docker/`. The Kenya module and the new logo files are additive and will not conflict. Keep customisations small and documented here to ease merging.

## 5. Roadmap and known gaps

- Kenya setup has been written and unit-tested but **not yet applied to the running site** (the run was blocked by a Frappe "Island not on this site" error tied to the unfinished frontend build). It has therefore not been checked end-to-end with a real Salary Slip.
- The mobile app at `/hrms` needs the frontend build to complete.
- Statutory figures need professional verification (see section 2).
- Integrations are not built: M-Pesa salary payments, biometric attendance, accounting. ERPNext is installed and covers accounting. Its Kenya chart of accounts, VAT and KRA settings still need configuring.
- Remaining branding items are listed in section 1.
