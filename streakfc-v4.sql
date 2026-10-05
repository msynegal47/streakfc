-- ============================================================
-- StreakFC database update v4 (parent: reset a kid's day)
-- Paste into Supabase > SQL Editor > New query > Run. Safe to re-run.
-- ============================================================

alter table public.sfc_players add column if not exists reset_at timestamptz;

-- Parent-only: wipe one kid's sessions for a day and roll back XP, touches, sessions and streak
create or replace function public.sfc_reset_day(p_player uuid, p_date date) returns json
language plpgsql security definer set search_path = public as $$
declare pl public.sfc_players; x int; t int; n int; prev date;
begin
  select * into pl from public.sfc_players where id = p_player and family_id = public.sfc_my_family();
  if pl.id is null then raise exception 'not_your_player'; end if;
  select coalesce(sum(xp_earned),0), coalesce(sum(touches),0), count(*) into x, t, n
    from public.sfc_sessions where player_id = p_player and date = p_date;
  delete from public.sfc_sessions where player_id = p_player and date = p_date;
  select max(date) into prev from public.sfc_sessions where player_id = p_player and date < p_date;
  update public.sfc_players set
    xp = greatest(0, xp - x),
    total_touches = greatest(0, total_touches - t),
    sessions = greatest(0, sessions - n),
    last_log = case when last_log = p_date then prev else last_log end,
    streak = case when last_log = p_date then (case when prev = p_date - 1 then greatest(0, streak - 1) else 0 end) else streak end,
    reset_at = now()
  where id = p_player;
  return json_build_object('xp', x, 'touches', t, 'sessions', n);
end $$;

revoke execute on function public.sfc_reset_day(uuid, date) from public, anon;
grant  execute on function public.sfc_reset_day(uuid, date) to authenticated;

-- Done.
