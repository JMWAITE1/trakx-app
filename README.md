# TrakX

Project costing system for NGL site-maintenance jobs. Rebuilds the Smartsheet TrakX workspace as a Supabase + static HTML web app, matching the IMR / PPR / TCDC stack.

**Status:** v1 — Fonterra Maungaturoto '26 only. Other projects (Chorus, BNZ, MOE) stay in Smartsheet for now.

## What it does

- **Subbies** submit their daily hours / materials / accom & travel via a public smartform (no login, like the current Smartsheet form).
- **PMs** approve entries on a desktop page.
- **Office staff** view AP (what we owe contractors) and AR (what to invoice the customer) reports.
- **Admins** set up projects, zones, people, and rates.
- **Customer** dashboard with KPIs, GP by zone, drill-down. Same vibe as the IMR dashboard. (Stage 2.)

## Architecture

- Supabase Postgres backend — see `supabase/migrations/`
- Static HTML frontend (deploy TBD)
- **Auth handled by Richard** for PM/office/admin pages — TrakX doesn't ship its own login flow. Subbies don't log in (smartform is anonymous, validated server-side by `trakx-submit` edge function).
- Every calculation lives in **one readable SQL view** (`v_trakx_lines`). No hidden formulas.

## Pages

| URL | Audience | What |
|---|---|---|
| `/trakx/submit?p=fonterra-m26` | Subbies (public) | Combined Hours/Materials/Accom smartform |
| `/trakx/login` | Everyone else | (handled by Richard) |
| `/trakx/p/fonterra-m26` | All logged-in | Project dashboard |
| `/trakx/p/fonterra-m26/approve` | PM | Approval queue |
| `/trakx/p/fonterra-m26/ap` | Office | Accounts payable |
| `/trakx/p/fonterra-m26/ar` | Office | Accounts receivable |
| `/trakx/admin` | Admin | Projects, zones, people, rates |

## Spec

Full spec + design history lives at `../fonterra-snapshot/TRAKX_SPEC.md`. Read that for context on the formulas and the migration from Smartsheet.

## Project data

- Supabase project: `uhodycdbkwocvptiffks`
- GitHub Pages deploy: TBD
- Domain mapping: `apps.nationalgroupltd.com/trakx` (handled outside this repo)
