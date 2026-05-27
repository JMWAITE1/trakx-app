-- ────────────────────────────────────────────────────────────────────
-- TrakX schema v1 (Fonterra Maungaturoto '26 — first project)
-- Designed for Supabase / Postgres. Calculations live in views, NEVER
-- in formulas hidden inside cells. Every $ figure traces back to a
-- readable SQL expression in v_trakx_lines below.
--
-- All money is stored as integer cents to avoid float drift.
-- All rates are snapshot onto entries at submission so historical lines
-- don't change when an admin edits a rate today.
-- ────────────────────────────────────────────────────────────────────

-- ═══ 1. REFERENCE TABLES ═══════════════════════════════════════════

create table trakx_projects (
  id            uuid primary key default gen_random_uuid(),
  slug          text unique not null,                     -- e.g. 'fonterra-m26' (used in URLs)
  customer_name text not null,                            -- 'Fonterra'
  display_name  text not null,                            -- 'Fonterra Maungaturoto 26'
  start_date    date,
  end_date      date,
  status        text not null default 'active' check (status in ('active','paused','completed','archived')),
  notes         text,
  created_at    timestamptz not null default now()
);

create table trakx_zones (
  id                    uuid primary key default gen_random_uuid(),
  project_id            uuid not null references trakx_projects(id) on delete cascade,
  name                  text not null,                    -- 'Whey Plant'
  display_order         int  not null default 0,
  netsuite_project_id   text,                             -- e.g. 'PRO1915' (manual entry for v1)
  po_number             text,
  revenue_target_cents  bigint not null default 0,        -- the PO cap
  status                text   not null default 'active',
  created_at            timestamptz not null default now(),
  unique (project_id, name)
);

create table trakx_companies (
  id           uuid primary key default gen_random_uuid(),
  name         text unique not null,                      -- 'Bellissimo Ltd', 'Rezende Ltd', 'NGL'
  is_internal  boolean not null default false,            -- NGL = true; subbies = false
  created_at   timestamptz not null default now()
);

create table trakx_people (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references trakx_companies(id),
  name         text not null,                             -- 'Diego Montoya', 'Project Manager - Dave'
  email        text,
  is_internal  boolean not null default false,            -- per-person override of company default
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);

create table trakx_project_people (
  -- Which people are assigned to which project (drives the smartform dropdown)
  project_id  uuid not null references trakx_projects(id) on delete cascade,
  person_id   uuid not null references trakx_people(id)   on delete cascade,
  primary key (project_id, person_id)
);

-- ═══ 2. RATES ══════════════════════════════════════════════════════

create table trakx_person_rates (
  -- Per-person pay rates, time-scoped. Old entries keep their original rate.
  id                    uuid primary key default gen_random_uuid(),
  person_id             uuid not null references trakx_people(id) on delete cascade,
  effective_from        date not null,
  day_pay_rate_cents    int  not null,                    -- e.g. 6700 = $67/h
  night_pay_rate_cents  int  not null,                    -- e.g. 7000 = $70/h
  created_at            timestamptz not null default now()
);
create index ix_trakx_person_rates_lookup on trakx_person_rates(person_id, effective_from desc);

create table trakx_project_rates (
  -- One row per project. ALL rates EDITABLE so admins can tweak without code change.
  project_id                   uuid primary key references trakx_projects(id) on delete cascade,

  -- Sell rates (what we charge the customer)
  day_sell_rate_cents          int     not null default 11700,   -- $117/h day
  night_sell_rate_cents        int     not null default 12200,   -- $122/h night

  -- Travel
  travel_cost_per_km_cents     int     not null default 50,      -- $0.50/km we pay
  travel_sell_per_km_cents     int     not null default 70,      -- $0.70/km we charge

  -- Accommodation (fixed per-night charge/cost per Johnny's Q22)
  accom_cost_per_night_cents   int     not null default 0,       -- what we pay
  accom_sell_per_night_cents   int     not null default 0,       -- what we charge

  -- Materials & Equipment (0% default but editable so margin can be added later)
  materials_markup_pct         numeric(5,2) not null default 0.00,
  equipment_markup_pct         numeric(5,2) not null default 0.00,

  -- Productivity bonus (5% on every hour by default, applies to subbie pay only)
  bonus_pct                    numeric(5,2) not null default 5.00,

  -- NZ Employment Law break defaults (editable per project)
  -- Workers >5h get 2×10min paid rest breaks + 30min unpaid lunch (Holidays & Pay Acts)
  lunch_break_minutes          int     not null default 30,
  lunch_break_threshold_hours  numeric(4,2) not null default 5.00,
  lunch_break_paid             boolean not null default false,
  rest_break_minutes_per       int     not null default 10,      -- per break
  rest_break_count             int     not null default 2,
  rest_break_paid              boolean not null default true,

  -- Day/night split window
  day_start_hour               int     not null default 6,        -- 06:00
  day_end_hour                 int     not null default 18,       -- 18:00

  updated_at                   timestamptz not null default now()
);

-- ═══ 3. THE BIG TABLE — every entry lives here ═════════════════════

create type trakx_entry_type as enum ('hours', 'materials', 'accom');

create table trakx_entries (
  id                          uuid primary key default gen_random_uuid(),
  type                        trakx_entry_type not null,
  project_id                  uuid not null references trakx_projects(id),
  zone_id                     uuid not null references trakx_zones(id),
  person_id                   uuid not null references trakx_people(id),
  date                        date not null,

  -- hours-type fields
  start_time                  time,
  finish_time                 time,
  finish_next_day             boolean default false,     -- ticks "ends after midnight" on the form

  -- accom-type field
  accom_nights                int default 0,

  -- travel — applies to any row (subbie ticks travel km on a shift, OR on an accom row)
  travel_kms                  numeric(8,2),

  -- materials-type fields
  materials_description       text,
  materials_cost_cents        int,
  equipment_hire_cents        int,
  po_number                   text,                       -- NetSuite supplier PO (manual entry for v1)
  receipt_url                 text,                       -- photo of receipt (Supabase storage)

  -- common fields
  work_description            text,
  comments                    text,

  -- ❄️ RATE SNAPSHOTS — frozen at entry time so editing rates today doesn't change history
  day_pay_rate_snapshot_cents     int,
  night_pay_rate_snapshot_cents   int,
  day_sell_rate_snapshot_cents    int,
  night_sell_rate_snapshot_cents  int,
  travel_cost_per_km_snapshot     int,
  travel_sell_per_km_snapshot     int,
  accom_cost_snapshot_cents       int,
  accom_sell_snapshot_cents       int,
  bonus_pct_snapshot              numeric(5,2),

  -- workflow
  approved                    boolean not null default false,
  approved_by                 text,
  approved_at                 timestamptz,
  marked_paid                 boolean not null default false,  -- informational only — payment lives in NetSuite

  -- audit
  submitted_by_name           text,                       -- free-text on the anonymous smartform
  created_at                  timestamptz not null default now(),
  modified_at                 timestamptz not null default now(),

  -- guards
  check (type <> 'hours'     or (start_time is not null and finish_time is not null)),
  check (type <> 'accom'     or accom_nights > 0),
  check (type <> 'materials' or (materials_description is not null and materials_cost_cents is not null))
);

create index ix_trakx_entries_zone on trakx_entries(zone_id);
create index ix_trakx_entries_date on trakx_entries(date);
create index ix_trakx_entries_person on trakx_entries(person_id);
create index ix_trakx_entries_approved on trakx_entries(approved) where approved = false;

-- ═══ 4. THE CALCULATION VIEW — every formula readable in one place ═════

create or replace view v_trakx_lines as
with
hours_decimal as (
  -- Convert start/finish times to decimal hours (e.g. 05:30 → 5.5)
  select
    e.*,
    extract(hour from e.start_time)  + extract(minute from e.start_time)  / 60.0  as s_hr,
    extract(hour from e.finish_time) + extract(minute from e.finish_time) / 60.0
      + case when e.finish_next_day then 24 else 0 end as f_hr_adj
  from trakx_entries e
),
hours_split as (
  -- Split into day-window (configured project_rates.day_start_hour..day_end_hour) and night
  select
    h.*,
    pr.day_start_hour::numeric  as day_start,
    pr.day_end_hour::numeric    as day_end,
    greatest(0, least(h.f_hr_adj, pr.day_end_hour)   - greatest(h.s_hr, pr.day_start_hour))                       as day_hours_raw,
    greatest(0, least(h.f_hr_adj, 24)                - greatest(h.s_hr, pr.day_end_hour))
      + greatest(0, least(h.f_hr_adj, pr.day_start_hour) - h.s_hr)                                                as night_hours_raw,
    (h.f_hr_adj - h.s_hr)                                                                                          as gross_hours,
    case
      when (h.f_hr_adj - h.s_hr) > pr.lunch_break_threshold_hours and not pr.lunch_break_paid
        then pr.lunch_break_minutes / 60.0
      else 0
    end                                                                                                            as lunch_deduction_hours,
    pr.bonus_pct,
    pr.materials_markup_pct,
    pr.equipment_markup_pct
  from hours_decimal h
  join trakx_project_rates pr on pr.project_id = h.project_id
)
select
  e.id,
  e.type,
  e.project_id,
  e.zone_id,
  z.name        as zone_name,
  e.person_id,
  p.name        as person_name,
  c.name        as company_name,
  c.is_internal or p.is_internal as is_internal,
  e.date,
  e.start_time,
  e.finish_time,
  e.finish_next_day,
  e.work_description,
  e.po_number,
  e.approved,
  e.marked_paid,

  -- ── Hours math ─────────────────────────────────────────────────
  case when e.type = 'hours' then hs.day_hours_raw   else 0 end as day_hours,
  case when e.type = 'hours' then hs.night_hours_raw else 0 end as night_hours,
  case when e.type = 'hours' then hs.gross_hours - hs.lunch_deduction_hours else 0 end as total_hours,
  case when e.type = 'hours' then hs.lunch_deduction_hours else 0 end as lunch_deduction_hours,

  -- ── Labour cost (what we pay the subbie) ──────────────────────
  case when e.type = 'hours'
    then round(
      hs.day_hours_raw   * e.day_pay_rate_snapshot_cents
    + hs.night_hours_raw * e.night_pay_rate_snapshot_cents
    + ((hs.gross_hours - hs.lunch_deduction_hours) * e.day_pay_rate_snapshot_cents * hs.bonus_pct / 100)
    )::int
    else 0
  end as labour_cost_cents,

  -- ── Labour sell (what we charge customer) ─────────────────────
  case when e.type = 'hours'
    then round(
      hs.day_hours_raw   * e.day_sell_rate_snapshot_cents
    + hs.night_hours_raw * e.night_sell_rate_snapshot_cents
    )::int
    else 0
  end as labour_sell_cents,

  -- ── Travel ────────────────────────────────────────────────────
  coalesce(round(e.travel_kms * e.travel_cost_per_km_snapshot)::int, 0) as travel_cost_cents,
  coalesce(round(e.travel_kms * e.travel_sell_per_km_snapshot)::int, 0) as travel_sell_cents,

  -- ── Accom ─────────────────────────────────────────────────────
  case when e.type = 'accom' then coalesce(e.accom_nights, 0) * e.accom_cost_snapshot_cents else 0 end as accom_cost_cents,
  case when e.type = 'accom' then coalesce(e.accom_nights, 0) * e.accom_sell_snapshot_cents else 0 end as accom_sell_cents,

  -- ── Materials ─────────────────────────────────────────────────
  case when e.type = 'materials' then coalesce(e.materials_cost_cents, 0) else 0 end as materials_cost_cents,
  case when e.type = 'materials'
    then round(coalesce(e.materials_cost_cents, 0) * (1 + hs.materials_markup_pct / 100))::int
    else 0
  end as materials_sell_cents,

  -- ── Equipment ─────────────────────────────────────────────────
  coalesce(e.equipment_hire_cents, 0) as equipment_cost_cents,
  case when e.equipment_hire_cents is not null
    then round(e.equipment_hire_cents * (1 + hs.equipment_markup_pct / 100))::int
    else 0
  end as equipment_sell_cents,

  -- ── Totals per line ───────────────────────────────────────────
  e.created_at,
  e.modified_at
from trakx_entries e
join trakx_zones    z on z.id = e.zone_id
join trakx_people   p on p.id = e.person_id
join trakx_companies c on c.id = p.company_id
left join hours_split hs on hs.id = e.id
;

-- ═══ 5. ROLL-UP VIEWS ═════════════════════════════════════════════

create or replace view v_trakx_line_totals as
-- Per-line totals using the special rule: internal staff = 100% GP (sell only, no cost on P&L)
select
  l.*,
  (labour_cost_cents + travel_cost_cents + accom_cost_cents + materials_cost_cents + equipment_cost_cents)
    as total_cost_cents,
  case when is_internal
    then labour_sell_cents
    else labour_sell_cents + travel_sell_cents + accom_sell_cents + materials_sell_cents + equipment_sell_cents
  end as sell_price_cents,
  case when is_internal
    then labour_sell_cents
    else (labour_sell_cents + travel_sell_cents + accom_sell_cents + materials_sell_cents + equipment_sell_cents)
       - (labour_cost_cents + travel_cost_cents + accom_cost_cents + materials_cost_cents + equipment_cost_cents)
  end as profit_cents
from v_trakx_lines l
;

create or replace view v_trakx_zone_rollup as
select
  z.project_id,
  z.id              as zone_id,
  z.name            as zone_name,
  z.revenue_target_cents,
  count(*) filter (where l.type = 'hours')                              as hours_entries,
  coalesce(sum(l.total_hours) filter (where l.type = 'hours'), 0)       as total_hours,
  coalesce(sum(l.total_cost_cents), 0)                                  as total_cost_cents,
  coalesce(sum(l.sell_price_cents), 0)                                  as revenue_actual_cents,
  coalesce(sum(l.profit_cents), 0)                                      as gp_cents,
  case when sum(l.sell_price_cents) > 0
    then round(100.0 * sum(l.profit_cents) / sum(l.sell_price_cents), 1)
    else 0
  end                                                                   as gp_pct,
  case when z.revenue_target_cents > 0
    then round(100.0 * sum(l.sell_price_cents) / z.revenue_target_cents, 1)
    else 0
  end                                                                   as pct_complete,
  z.revenue_target_cents - coalesce(sum(l.sell_price_cents), 0)         as budget_remaining_cents
from trakx_zones z
left join v_trakx_line_totals l on l.zone_id = z.id and l.approved = true
group by z.id
;

create or replace view v_trakx_ap as
-- Accounts payable: what we owe contractors (excludes internal)
select
  l.project_id,
  l.company_name,
  l.person_name,
  l.zone_name,
  l.date,
  l.type,
  l.total_hours,
  l.labour_cost_cents,
  l.travel_cost_cents,
  l.accom_cost_cents,
  l.materials_cost_cents,
  l.equipment_cost_cents,
  l.total_cost_cents,
  l.approved,
  l.marked_paid
from v_trakx_line_totals l
where not l.is_internal
  and l.total_cost_cents > 0
order by l.date, l.company_name, l.person_name
;

create or replace view v_trakx_ar as
-- Accounts receivable: what we invoice the customer (includes internal)
select
  l.project_id,
  l.zone_name,
  l.person_name,
  l.company_name,
  l.date,
  l.type,
  l.labour_sell_cents,
  l.travel_sell_cents,
  l.accom_sell_cents,
  l.materials_sell_cents,
  l.equipment_sell_cents,
  l.sell_price_cents,
  l.approved
from v_trakx_line_totals l
where l.approved = true
  and l.sell_price_cents > 0
order by l.date, l.zone_name, l.person_name
;

-- ═══ 6. RLS POLICIES (placeholder — wire up Access Manager same as IMR) ═

alter table trakx_projects        enable row level security;
alter table trakx_zones           enable row level security;
alter table trakx_companies       enable row level security;
alter table trakx_people          enable row level security;
alter table trakx_project_people  enable row level security;
alter table trakx_person_rates    enable row level security;
alter table trakx_project_rates   enable row level security;
alter table trakx_entries         enable row level security;

-- Anonymous smartform: can INSERT a 'hours'/'accom'/'materials' entry on an active project,
-- but cannot SELECT/UPDATE/DELETE. Implemented via edge function or RLS policy.
-- (To be added in a follow-up migration alongside Access Manager wiring.)
