-- Add a project-level alert threshold for zones approaching revenue target.
--
-- Semantics: if a zone's actual revenue is within `zone_alert_within_pct` percent
-- of its target (i.e. pct_complete >= 100 - zone_alert_within_pct), the dashboard
-- shows a banner flagging that zone. Default 10 (warn at 90% complete).

alter table trakx_project_rates
  add column if not exists zone_alert_within_pct numeric(5,2) not null default 10;

comment on column trakx_project_rates.zone_alert_within_pct is
  'Dashboard banner triggers when actual revenue is within this % of target. e.g. 10 means warn at >=90% complete.';
