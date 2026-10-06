-- StreakFC v6: programs (EPA beta). Safe to re-run.
-- Enrollment per kid: [{"id":"epa","group":"younger","focus":"technical","note":"..."}]
alter table public.sfc_players add column if not exists programs jsonb not null default '[]';
