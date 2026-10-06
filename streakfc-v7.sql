-- StreakFC v7: console (admin role, family flags, admin functions). Safe to re-run.

-- Admins: no direct table access, checked only inside functions
create table if not exists public.sfc_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.sfc_admins enable row level security;
revoke all on public.sfc_admins from public, anon, authenticated;

-- Per-family feature flags, e.g. {"programs": true}
alter table public.sfc_families add column if not exists flags jsonb not null default '{}';

create or replace function public.sfc_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.sfc_admins where user_id = auth.uid())
$$;

-- Everything the console needs in one call (last N days of sessions)
create or replace function public.sfc_admin_data(p_days int default 30) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  return json_build_object(
    'families', coalesce((select json_agg(json_build_object('id', f.id, 'parent_name', f.parent_name, 'email', u.email,
        'created_at', f.created_at, 'flags', f.flags) order by f.created_at)
      from public.sfc_families f left join auth.users u on u.id = f.owner), '[]'::json),
    'players', coalesce((select json_agg(to_jsonb(p) order by p.created_at) from public.sfc_players p where not p.archived), '[]'::json),
    'sessions', coalesce((select json_agg(json_build_object('player_id', s.player_id, 'family_id', s.family_id, 'date', s.date,
        'touches', s.touches, 'xp', s.xp_earned, 'mode', s.mode, 'source', s.source, 'rounds', s.rounds, 'created_at', s.created_at)
        order by s.created_at desc)
      from public.sfc_sessions s where s.date >= current_date - least(greatest(p_days, 1), 120)), '[]'::json)
  );
end $$;

create or replace function public.sfc_admin_set_programs(p_player uuid, p_programs jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  if jsonb_typeof(p_programs) <> 'array' or length(p_programs::text) > 4000 then raise exception 'bad_programs'; end if;
  update public.sfc_players set programs = p_programs where id = p_player;
end $$;

-- Set this week's EPA focus + note for every enrolled kid
create or replace function public.sfc_admin_epa_focus(p_focus text, p_note text) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  update public.sfc_players set programs = (
      select jsonb_agg(case when e->>'id' = 'epa'
        then e || jsonb_build_object('focus', left(coalesce(p_focus,''), 20), 'note', left(coalesce(p_note,''), 100)) else e end)
      from jsonb_array_elements(programs) e)
    where programs @> '[{"id":"epa"}]';
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.sfc_admin_set_flags(p_family uuid, p_flags jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  if jsonb_typeof(p_flags) <> 'object' or length(p_flags::text) > 2000 then raise exception 'bad_flags'; end if;
  update public.sfc_families set flags = p_flags where id = p_family;
end $$;

revoke execute on function public.sfc_is_admin(), public.sfc_admin_data(int), public.sfc_admin_set_programs(uuid,jsonb),
  public.sfc_admin_epa_focus(text,text), public.sfc_admin_set_flags(uuid,jsonb) from public, anon;
grant execute on function public.sfc_is_admin(), public.sfc_admin_data(int), public.sfc_admin_set_programs(uuid,jsonb),
  public.sfc_admin_epa_focus(text,text), public.sfc_admin_set_flags(uuid,jsonb) to authenticated;

-- Make Marcus admin (the email you sign in to StreakFC with)
insert into public.sfc_admins(user_id) select id from auth.users where email = 'marcus.synegal@gmail.com' on conflict do nothing;
-- Turn on programs for your family
update public.sfc_families set flags = flags || '{"programs": true}'
  where owner in (select id from auth.users where email = 'marcus.synegal@gmail.com');
select count(*) as admins from public.sfc_admins;
