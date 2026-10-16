-- StreakFC v16: coach drill video library + player IDPs. Safe to re-run.
create table if not exists public.sfc_media (
  program text not null default 'epa',
  skill text not null,
  url text not null,
  title text,
  updated_at timestamptz not null default now(),
  primary key (program, skill));
alter table public.sfc_media enable row level security;
revoke all on public.sfc_media from public, anon, authenticated;

create table if not exists public.sfc_idp (
  player_id uuid not null references public.sfc_players(id) on delete cascade,
  program text not null default 'epa',
  data jsonb not null default '{}',
  updated_at timestamptz not null default now(),
  primary key (player_id, program));
alter table public.sfc_idp enable row level security;
revoke all on public.sfc_idp from public, anon, authenticated;

create or replace function public.sfc_media_list(p_program text) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.sfc_is_coach(p_program) then raise exception 'not_coach'; end if;
  return coalesce((select json_object_agg(skill, json_build_object('url', url, 'title', title)) from public.sfc_media where program = p_program), '{}'::json);
end $$;

create or replace function public.sfc_set_media(p_program text, p_skill text, p_url text, p_title text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.sfc_is_coach(p_program) then raise exception 'not_coach'; end if;
  if p_skill !~ '^[a-z0-9_]{1,40}$' then raise exception 'bad_skill'; end if;
  if coalesce(trim(p_url), '') = '' then delete from public.sfc_media where program = p_program and skill = p_skill; return; end if;
  if p_url !~ '^https://' or length(p_url) > 400 then raise exception 'bad_url'; end if;
  insert into public.sfc_media(program, skill, url, title, updated_at) values (p_program, p_skill, trim(p_url), left(p_title, 80), now())
  on conflict (program, skill) do update set url = excluded.url, title = excluded.title, updated_at = now();
end $$;

create or replace function public.sfc_idps(p_program text) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.sfc_is_coach(p_program) then raise exception 'not_coach'; end if;
  return coalesce((select json_object_agg(i.player_id, i.data) from public.sfc_idp i join public.sfc_players p on p.id = i.player_id
    where i.program = p_program and p.programs @> jsonb_build_array(jsonb_build_object('id', p_program))), '{}'::json);
end $$;

create or replace function public.sfc_set_idp(p_player uuid, p_program text, p_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.sfc_is_coach(p_program) or not public.sfc_can_manage(p_player) then raise exception 'not_coach'; end if;
  if not exists (select 1 from public.sfc_players where id = p_player and programs @> jsonb_build_array(jsonb_build_object('id', p_program))) then raise exception 'not_in_program'; end if;
  if jsonb_typeof(p_data) <> 'object' or length(p_data::text) > 8000 then raise exception 'bad_idp'; end if;
  insert into public.sfc_idp(player_id, program, data, updated_at) values (p_player, p_program, p_data, now())
  on conflict (player_id, program) do update set data = excluded.data, updated_at = now();
end $$;

-- What the kid's app pulls: videos for their programs (plus 'all') and their IDPs
create or replace function public.sfc_player_extras(p_token text, p_player uuid) returns json
language plpgsql volatile security definer set search_path = public as $$
declare d public.sfc_devices := public.sfc_device_from_token(p_token); pl public.sfc_players; progs text[];
begin
  select * into pl from public.sfc_players where id = p_player and family_id = d.family_id;
  if pl.id is null then raise exception 'not_on_this_device'; end if;
  select coalesce(array_agg(e->>'id'), '{}') into progs from jsonb_array_elements(coalesce(pl.programs, '[]'::jsonb)) e;
  return json_build_object(
    -- StreakFC library ('all') first, the coach's own version overrides it
    'media', coalesce((select json_object_agg(skill, json_build_object('url', url, 'title', title, 'by', case when program = 'all' then 'StreakFC' else 'coach' end) order by (program = 'all') desc) from public.sfc_media where program = any(progs || 'all'::text)), '{}'::json),
    'idp', coalesce((select json_object_agg(program, data) from public.sfc_idp where player_id = p_player and program = any(progs)), '{}'::json));
end $$;

revoke execute on function public.sfc_media_list(text), public.sfc_set_media(text,text,text,text), public.sfc_idps(text), public.sfc_set_idp(uuid,text,jsonb), public.sfc_player_extras(text,uuid) from public, anon;
grant  execute on function public.sfc_media_list(text), public.sfc_set_media(text,text,text,text), public.sfc_idps(text), public.sfc_set_idp(uuid,text,jsonb) to authenticated;
grant  execute on function public.sfc_player_extras(text,uuid) to anon, authenticated;
select 'v16 ok' as status;
