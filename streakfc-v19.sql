-- StreakFC v19: organizations (academy | club | trainer), staff roles, programs per org, roster-only players. Safe to re-run.
-- Model: org -> programs -> players. Staff belong to an org with a role. Records (IDPs, plans, notes) are keyed by program,
-- programs belong to the org, so records stay with the org when a coach leaves. A player can be in programs from many orgs.

create table if not exists public.sfc_orgs (
  id text primary key, name text not null, short text, kind text not null default 'academy' check (kind in ('academy','club','trainer')),
  brand jsonb not null default '{}', created_at timestamptz not null default now());
create table if not exists public.sfc_org_programs (
  id text primary key, org text not null references public.sfc_orgs(id) on delete cascade, name text not null,
  kind text not null default 'group' check (kind in ('cohort','group','clinic','private','team')),
  info jsonb not null default '{}', active boolean not null default true, sort int not null default 0, created_at timestamptz not null default now());
create table if not exists public.sfc_staff (
  org text not null references public.sfc_orgs(id) on delete cascade, user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'coach' check (role in ('owner','co_owner','manager','coach')), name text,
  programs text[] not null default '{}', active boolean not null default true, created_at timestamptz not null default now(),
  primary key (org, user_id));
create table if not exists public.sfc_org_roster (
  id uuid primary key default gen_random_uuid(), org text not null references public.sfc_orgs(id) on delete cascade,
  program text not null references public.sfc_org_programs(id) on delete cascade,
  nickname text not null check (char_length(nickname) between 1 and 20), age_group text,
  notes jsonb not null default '[]', claim_code text unique not null, player_id uuid references public.sfc_players(id) on delete set null,
  created_by uuid, created_at timestamptz not null default now());
alter table public.sfc_coach_invites add column if not exists org text;
alter table public.sfc_coach_invites add column if not exists programs text[];
alter table public.sfc_coach_invites add column if not exists label text;
do $$ declare t text; begin foreach t in array array['sfc_orgs','sfc_org_programs','sfc_staff','sfc_org_roster'] loop
  execute format('alter table public.%I enable row level security', t);
  execute format('revoke all on public.%I from public, anon, authenticated', t); end loop; end $$;

-- Seed: McGhee Soccer Academy. EPA keeps its id so every existing record carries over.
insert into public.sfc_orgs(id, name, short, kind, brand) values ('msa', 'McGhee Soccer Academy', 'MSA', 'academy',
  '{"accent":"#0caab5","deep":"#052c2d","logo":"/brand/msa-shield.png","lockup":"/brand/msa-logo-light.png"}') on conflict (id) do nothing;
insert into public.sfc_org_programs(id, org, name, kind, sort, info) values
  ('epa', 'msa', 'MSA East EPA', 'cohort', 1, '{"days":[2,3,4]}'),
  ('msa-group', 'msa', 'Group Training', 'group', 2, '{}'),
  ('msa-clinic', 'msa', 'Friday Shooting Clinic', 'clinic', 3, '{"days":[5]}'),
  ('msa-private', 'msa', 'Private Training', 'private', 4, '{}') on conflict (id) do nothing;
insert into public.sfc_program_codes(program, code)
  select p.id, upper(left(p.org, 3)) || '-' || upper(substr(md5(random()::text || p.id), 1, 4)) from public.sfc_org_programs p on conflict do nothing;
insert into public.sfc_staff(org, user_id, role, name, programs)
  select p.org, c.user_id, case when c.role = 'owner' then 'owner' else 'coach' end, c.name, array[c.program]
  from public.sfc_coaches c join public.sfc_org_programs p on p.id = c.program on conflict do nothing;
update public.sfc_coach_invites i set org = p.org, programs = array[i.program] from public.sfc_org_programs p where p.id = i.program and i.org is null;

-- Helpers
create or replace function public.sfc_role_rank(r text) returns int language sql immutable as $$
  select case r when 'owner' then 4 when 'co_owner' then 3 when 'manager' then 2 when 'coach' then 1 else 0 end $$;
create or replace function public.sfc_org_role(p_org text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select role from public.sfc_staff where org = p_org and user_id = auth.uid() and active), case when public.sfc_is_admin() then 'platform' end)
$$;
create or replace function public.sfc_org_can_manage(p_org text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.sfc_is_admin() or coalesce(public.sfc_role_rank(public.sfc_org_role(p_org)) >= 2, false)
$$;
-- The one scoping function every coach RPC already uses. Owners/co-owners/admins see all org programs; coaches see assigned ones.
create or replace function public.sfc_coach_programs() returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct x), '{}') from (
    select p.id x from public.sfc_staff s join public.sfc_org_programs p on p.org = s.org
      where s.user_id = auth.uid() and s.active and (public.sfc_role_rank(s.role) >= 2 or p.id = any(s.programs))
    union select c.program from public.sfc_coaches c where c.user_id = auth.uid()
      and not exists (select 1 from public.sfc_org_programs p where p.id = c.program)) q
$$;
create or replace function public.sfc_program_org(p_program text) returns text
language sql stable security definer set search_path = public as $$ select org from public.sfc_org_programs where id = p_program $$;

create or replace function public.sfc_my_roles() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('admin', public.sfc_is_admin(),
    'coach', coalesce((select json_agg(json_build_object('program', x, 'role', 'coach')) from unnest(public.sfc_coach_programs()) x), '[]'::json),
    'orgs', coalesce((select json_agg(json_build_object('id', o.id, 'name', o.name, 'short', o.short, 'kind', o.kind, 'brand', o.brand,
        'role', public.sfc_org_role(o.id), 'me', (select name from public.sfc_staff where org = o.id and user_id = auth.uid()),
        'programs', coalesce((select json_agg(json_build_object('id', p.id, 'name', p.name, 'kind', p.kind, 'info', p.info, 'code', pc.code) order by p.sort, p.name)
          from public.sfc_org_programs p left join public.sfc_program_codes pc on pc.program = p.id
          where p.org = o.id and p.active and (public.sfc_is_admin() or p.id = any(public.sfc_coach_programs()))), '[]'::json)) order by o.name)
      from public.sfc_orgs o where public.sfc_org_role(o.id) is not null), '[]'::json))
$$;

-- Staff + invites for one org. Emails only for owner/co-owner/admin.
create or replace function public.sfc_org_staff(p_org text) returns json
language plpgsql stable security definer set search_path = public as $$
declare m boolean := public.sfc_org_can_manage(p_org);
begin
  if public.sfc_org_role(p_org) is null then raise exception 'not_staff'; end if;
  return json_build_object('manage', m,
    'staff', coalesce((select json_agg(json_build_object('user_id', s.user_id, 'name', s.name, 'role', s.role, 'programs', s.programs, 'active', s.active,
        'created_at', s.created_at, 'email', case when m then u.email end, 'me', s.user_id = auth.uid())
      order by s.active desc, public.sfc_role_rank(s.role) desc, s.name) from public.sfc_staff s left join auth.users u on u.id = s.user_id where s.org = p_org), '[]'::json),
    'invites', case when m then coalesce((select json_agg(json_build_object('code', i.code, 'role', i.role, 'programs', i.programs, 'label', i.label, 'created_at', i.created_at) order by i.created_at desc)
      from public.sfc_coach_invites i where i.org = p_org and i.used_by is null and i.created_at > now() - interval '14 days'), '[]'::json) else '[]'::json end,
    'programs', coalesce((select json_agg(json_build_object('id', p.id, 'name', p.name, 'kind', p.kind, 'active', p.active, 'code', pc.code,
        'players', (select count(*) from public.sfc_players pl where not pl.archived and pl.programs @> jsonb_build_array(jsonb_build_object('id', p.id))),
        'roster', (select count(*) from public.sfc_org_roster r where r.program = p.id and r.player_id is null)) order by p.sort, p.name)
      from public.sfc_org_programs p left join public.sfc_program_codes pc on pc.program = p.id where p.org = p_org and (m or p.id = any(public.sfc_coach_programs()))), '[]'::json));
end $$;

create or replace function public.sfc_org_invite(p_org text, p_role text, p_programs text[], p_label text) returns text
language plpgsql security definer set search_path = public as $$
declare c text := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8)); me text := public.sfc_org_role(p_org);
begin
  if not public.sfc_org_can_manage(p_org) then raise exception 'not_allowed'; end if;
  if public.sfc_role_rank(p_role) = 0 then raise exception 'bad_role'; end if;
  if me <> 'platform' and public.sfc_role_rank(p_role) > public.sfc_role_rank(me) then raise exception 'role_too_high'; end if;
  insert into public.sfc_coach_invites(code, program, role, org, programs, label)
    values (c, coalesce(p_programs[1], 'org:' || p_org), p_role, p_org,
      coalesce((select array_agg(x) from unnest(p_programs) x where public.sfc_program_org(x) = p_org), '{}'), left(p_label, 40));
  return c;
end $$;
create or replace function public.sfc_org_cancel_invite(p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare o text := (select org from public.sfc_coach_invites where code = p_code);
begin
  if o is null or not public.sfc_org_can_manage(o) then raise exception 'not_allowed'; end if;
  delete from public.sfc_coach_invites where code = p_code and used_by is null;
end $$;

create or replace function public.sfc_accept_invite(p_code text, p_name text) returns text
language plpgsql security definer set search_path = public as $$
declare i public.sfc_coach_invites;
begin
  select * into i from public.sfc_coach_invites where code = upper(p_code) and used_by is null and created_at > now() - interval '14 days';
  if i.code is null then raise exception 'invite_invalid'; end if;
  if i.org is not null then
    insert into public.sfc_staff(org, user_id, role, name, programs, active) values (i.org, auth.uid(), i.role, left(p_name, 40), coalesce(i.programs, '{}'), true)
    on conflict (org, user_id) do update set role = excluded.role, name = coalesce(nullif(excluded.name, ''), public.sfc_staff.name),
      programs = excluded.programs, active = true;
  else
    insert into public.sfc_coaches(user_id, program, role, name) values (auth.uid(), i.program, i.role, left(p_name, 40))
    on conflict (user_id, program) do update set role = excluded.role, name = excluded.name;
  end if;
  update public.sfc_coach_invites set used_by = auth.uid(), used_at = now() where code = i.code;
  return coalesce((select id from public.sfc_org_programs where id = any(i.programs) order by sort limit 1), i.program);
end $$;

-- Change role / programs / active. Nobody edits someone ranked at or above them (except owners + platform).
create or replace function public.sfc_org_set_staff(p_org text, p_user uuid, p_role text, p_programs text[], p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
declare me text := public.sfc_org_role(p_org); s public.sfc_staff;
begin
  if not public.sfc_org_can_manage(p_org) then raise exception 'not_allowed'; end if;
  select * into s from public.sfc_staff where org = p_org and user_id = p_user;
  if s.user_id is null then raise exception 'not_found'; end if;
  if me not in ('platform','owner') and (public.sfc_role_rank(s.role) >= public.sfc_role_rank(me) or public.sfc_role_rank(p_role) > public.sfc_role_rank(me)) then raise exception 'role_too_high'; end if;
  if s.role = 'owner' and (p_role <> 'owner' or not p_active)
     and not exists (select 1 from public.sfc_staff where org = p_org and role = 'owner' and active and user_id <> p_user) then raise exception 'last_owner'; end if;
  update public.sfc_staff set role = p_role, active = p_active,
    programs = coalesce((select array_agg(x) from unnest(p_programs) x where public.sfc_program_org(x) = p_org), '{}')
  where org = p_org and user_id = p_user;
end $$;

create or replace function public.sfc_org_save_program(p_org text, p_id text, p_name text, p_kind text, p_active boolean) returns text
language plpgsql security definer set search_path = public as $$
declare pid text := coalesce(nullif(p_id, ''), p_org || '-' || lower(substr(md5(random()::text), 1, 6)));
begin
  if not public.sfc_org_can_manage(p_org) then raise exception 'not_allowed'; end if;
  if exists (select 1 from public.sfc_org_programs where id = pid and org <> p_org) then raise exception 'not_allowed'; end if;
  insert into public.sfc_org_programs(id, org, name, kind, active, sort) values (pid, p_org, left(p_name, 40), p_kind, coalesce(p_active, true),
    (select coalesce(max(sort), 0) + 1 from public.sfc_org_programs where org = p_org))
  on conflict (id) do update set name = excluded.name, kind = excluded.kind, active = excluded.active;
  insert into public.sfc_program_codes(program, code) values (pid, upper(left(p_org, 3)) || '-' || upper(substr(md5(random()::text || pid), 1, 4))) on conflict do nothing;
  return pid;
end $$;

-- Roster-only players: booked outside StreakFC (Acuity etc). Nickname + age group only. Parent claims with the code.
create or replace function public.sfc_roster_list(p_program text) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.sfc_is_coach(p_program) then raise exception 'not_coach'; end if;
  return coalesce((select json_agg(json_build_object('id', id, 'nickname', nickname, 'age_group', age_group, 'notes', notes, 'claim_code', claim_code,
    'player_id', player_id, 'created_at', created_at) order by created_at) from public.sfc_org_roster where program = p_program), '[]'::json);
end $$;
create or replace function public.sfc_roster_add(p_program text, p_nickname text, p_age text) returns json
language plpgsql security definer set search_path = public as $$
declare r public.sfc_org_roster;
begin
  if not public.sfc_is_coach(p_program) then raise exception 'not_coach'; end if;
  insert into public.sfc_org_roster(org, program, nickname, age_group, claim_code, created_by)
    values (public.sfc_program_org(p_program), p_program, left(trim(p_nickname), 20), left(p_age, 8), 'P-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6)), auth.uid())
    returning * into r;
  return to_jsonb(r);
end $$;
create or replace function public.sfc_roster_note(p_id uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare r public.sfc_org_roster;
begin
  select * into r from public.sfc_org_roster where id = p_id;
  if r.id is null or not public.sfc_is_coach(r.program) then raise exception 'not_coach'; end if;
  update public.sfc_org_roster set notes = notes || jsonb_build_array(jsonb_build_object('date', current_date, 'by',
    coalesce((select name from public.sfc_staff where org = r.org and user_id = auth.uid()), 'Coach'), 'text', left(p_text, 1000))) where id = p_id;
end $$;
create or replace function public.sfc_roster_remove(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r public.sfc_org_roster;
begin
  select * into r from public.sfc_org_roster where id = p_id;
  if r.id is null or not public.sfc_is_coach(r.program) then raise exception 'not_coach'; end if;
  delete from public.sfc_org_roster where id = p_id and player_id is null;
end $$;

-- Lesson notes on a StreakFC player: stored on the org roster row so the notes stay with the academy
create or replace function public.sfc_roster_note_player(p_program text, p_player uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare rid uuid; pl public.sfc_players;
begin
  if not public.sfc_is_coach(p_program) then raise exception 'not_coach'; end if;
  select * into pl from public.sfc_players where id = p_player and programs @> jsonb_build_array(jsonb_build_object('id', p_program));
  if pl.id is null then raise exception 'not_in_program'; end if;
  select id into rid from public.sfc_org_roster where program = p_program and player_id = p_player;
  if rid is null then
    insert into public.sfc_org_roster(org, program, nickname, age_group, claim_code, player_id, created_by)
      values (public.sfc_program_org(p_program), p_program, pl.nickname, pl.age_group, 'P-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6)), p_player, auth.uid())
      returning id into rid;
  end if;
  perform public.sfc_roster_note(rid, p_text);
end $$;

-- Parent: join with a program code OR a roster claim code
create or replace function public.sfc_join_program(p_player uuid, p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare prog text; p public.sfc_players; n int; r public.sfc_org_roster;
begin
  select * into p from public.sfc_players where id = p_player and family_id = public.sfc_my_family();
  if p.id is null then raise exception 'not_your_player'; end if;
  select program into prog from public.sfc_program_codes where code = upper(trim(p_code));
  if prog is null then
    select * into r from public.sfc_org_roster where claim_code = upper(trim(p_code)) and player_id is null;
    if r.id is null then raise exception 'code_invalid'; end if;
    prog := r.program;
    update public.sfc_org_roster set player_id = p_player where id = r.id;
  end if;
  if p.programs @> jsonb_build_array(jsonb_build_object('id', prog)) then return prog; end if;
  n := nullif(regexp_replace(coalesce(p.age_group,''), '\D', '', 'g'), '')::int;
  update public.sfc_players set programs = coalesce(programs, '[]'::jsonb) || jsonb_build_array(jsonb_build_object('id', prog,
    'group', case when n >= 13 then 'older' else 'younger' end, 'focus', '', 'note', '', 'share', 'all',
    'name', (select coalesce(o.short, o.name) || ' · ' || p2.name from public.sfc_org_programs p2 join public.sfc_orgs o on o.id = p2.org where p2.id = prog))) where id = p_player;
  return prog;
end $$;

-- Parent: leave a program (records stay with the org, the kid's data stops flowing)
create or replace function public.sfc_leave_program(p_player uuid, p_program text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.sfc_players where id = p_player and family_id = public.sfc_my_family()) then raise exception 'not_your_player'; end if;
  update public.sfc_players set programs = coalesce((select jsonb_agg(e) from jsonb_array_elements(programs) e where e->>'id' <> p_program), '[]'::jsonb) where id = p_player;
end $$;

-- Kid app extras: add org/program labels so the app can show "who coaches me" + IDPs per academy
create or replace function public.sfc_player_extras(p_token text, p_player uuid) returns json
language plpgsql volatile security definer set search_path = public as $$
declare d public.sfc_devices := public.sfc_device_from_token(p_token); pl public.sfc_players; progs text[];
begin
  select * into pl from public.sfc_players where id = p_player and family_id = d.family_id;
  if pl.id is null then raise exception 'not_on_this_device'; end if;
  select coalesce(array_agg(e->>'id'), '{}') into progs from jsonb_array_elements(coalesce(pl.programs, '[]'::jsonb)) e;
  return json_build_object(
    'media', coalesce((select json_object_agg(skill, json_build_object('url', url, 'title', title, 'by', case when program = 'all' then 'StreakFC' else 'coach' end) order by (program = 'all') desc) from public.sfc_media where program = any(progs || 'all'::text)), '{}'::json),
    'idp', coalesce((select json_object_agg(program, data) from public.sfc_idp where player_id = p_player and program = any(progs)), '{}'::json),
    'days', coalesce((select json_agg(json_build_object('program', program, 'day', day, 'theme', data->>'theme', 'title', data->>'title', 'family', data->>'family') order by day)
      from public.sfc_epa_days where program = any(progs) and day between current_date and current_date + 21), '[]'::json),
    'orgs', coalesce((select json_object_agg(p.id, json_build_object('program', p.name, 'kind', p.kind, 'org', o.id, 'org_name', o.name, 'short', o.short, 'org_kind', o.kind, 'brand', o.brand))
      from public.sfc_org_programs p join public.sfc_orgs o on o.id = p.org where p.id = any(progs)), '{}'::json));
end $$;

do $$ declare f text; begin
  foreach f in array array['sfc_role_rank(text)','sfc_org_role(text)','sfc_org_can_manage(text)','sfc_coach_programs()','sfc_program_org(text)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f); end loop;
  foreach f in array array['sfc_my_roles()','sfc_org_staff(text)','sfc_org_invite(text,text,text[],text)','sfc_org_cancel_invite(text)','sfc_accept_invite(text,text)',
      'sfc_org_set_staff(text,uuid,text,text[],boolean)','sfc_org_save_program(text,text,text,text,boolean)','sfc_roster_list(text)','sfc_roster_add(text,text,text)',
      'sfc_roster_note(uuid,text)','sfc_roster_note_player(text,uuid,text)','sfc_roster_remove(uuid)','sfc_join_program(uuid,text)','sfc_leave_program(uuid,text)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f); end loop;
end $$;
grant execute on function public.sfc_player_extras(text,uuid) to anon, authenticated;
select 'v19 ok' as status;
