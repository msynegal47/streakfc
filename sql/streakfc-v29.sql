-- v29: Squads. Friends join with a code; a parent approves every join (kid asks, parent says yes).
create table if not exists public.sfc_squads (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  created_by uuid references public.sfc_players(id) on delete set null,
  created_at timestamptz not null default now()
);
create table if not exists public.sfc_squad_members (
  squad_id uuid not null references public.sfc_squads(id) on delete cascade,
  player_id uuid not null references public.sfc_players(id) on delete cascade,
  status text not null default 'requested' check (status in ('requested','joined','declined')),
  requested_at timestamptz default now(),
  joined_at timestamptz,
  primary key (squad_id, player_id)
);
alter table public.sfc_squads enable row level security;
alter table public.sfc_squad_members enable row level security;
revoke all on public.sfc_squads, public.sfc_squad_members from anon, authenticated;

create or replace function public.sfc_kid_ok(p_token text, p_player uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.sfc_players where id = p_player and family_id = public.sfc_caller_family(p_token) and public.sfc_caller_family(p_token) is not null)
$$;

-- Kid starts a squad: squad exists right away, kid's own membership waits for a parent
create or replace function public.sfc_squad_create(p_token text, p_player uuid, p_name text)
returns json language plpgsql security definer set search_path to 'public' as $$
declare c text; sid uuid; n int := 0;
begin
  if not public.sfc_kid_ok(p_token, p_player) then raise exception 'not_your_player'; end if;
  if length(trim(coalesce(p_name,''))) < 2 then raise exception 'name_required'; end if;
  if (select count(*) from public.sfc_squads where created_by = p_player and created_at > now() - interval '1 day') >= 3 then raise exception 'too_many'; end if;
  loop
    c := 'SQ-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4)); n := n + 1;
    exit when not exists (select 1 from public.sfc_squads where code = c) or n > 20;
  end loop;
  insert into public.sfc_squads(code, name, created_by) values (c, left(trim(p_name), 24), p_player) returning id into sid;
  insert into public.sfc_squad_members(squad_id, player_id, status) values (sid, p_player, 'requested');
  return json_build_object('id', sid, 'code', c);
end $$;

-- Kid enters a friend's code
create or replace function public.sfc_squad_request(p_token text, p_player uuid, p_code text)
returns json language plpgsql security definer set search_path to 'public' as $$
declare s public.sfc_squads;
begin
  if not public.sfc_kid_ok(p_token, p_player) then raise exception 'not_your_player'; end if;
  select * into s from public.sfc_squads where code = upper(trim(p_code));
  if s.id is null then raise exception 'code_invalid'; end if;
  if (select count(*) from public.sfc_squad_members where squad_id = s.id and status = 'joined') >= 30 then raise exception 'squad_full'; end if;
  insert into public.sfc_squad_members(squad_id, player_id, status) values (s.id, p_player, 'requested')
  on conflict (squad_id, player_id) do update set status = case when sfc_squad_members.status = 'joined' then 'joined' else 'requested' end, requested_at = now();
  return json_build_object('id', s.id, 'name', s.name, 'code', s.code);
end $$;

-- Kid leaves a squad (no approval needed to leave)
create or replace function public.sfc_squad_leave(p_token text, p_player uuid, p_squad uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.sfc_kid_ok(p_token, p_player) then raise exception 'not_your_player'; end if;
  delete from public.sfc_squad_members where squad_id = p_squad and player_id = p_player;
end $$;

-- Kid's squads
create or replace function public.sfc_squads_for(p_token text, p_player uuid)
returns json language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.sfc_kid_ok(p_token, p_player) then raise exception 'not_your_player'; end if;
  return coalesce((select json_agg(json_build_object('id', s.id, 'name', s.name, 'code', s.code, 'status', m.status,
      'members', (select count(*) from public.sfc_squad_members x where x.squad_id = s.id and x.status = 'joined')) order by s.created_at)
    from public.sfc_squad_members m join public.sfc_squads s on s.id = m.squad_id where m.player_id = p_player and m.status <> 'declined'), '[]'::json);
end $$;

-- Squad board: this week's XP + days trained, joined members only
create or replace function public.sfc_squad_board(p_token text, p_player uuid, p_squad uuid, p_week date)
returns json language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.sfc_kid_ok(p_token, p_player) then raise exception 'not_your_player'; end if;
  if not exists (select 1 from public.sfc_squad_members where squad_id = p_squad and player_id = p_player and status = 'joined') then raise exception 'not_joined'; end if;
  if p_week not between current_date - 7 and current_date + 1 then raise exception 'bad_date'; end if;
  return coalesce((select json_agg(r order by r.week_xp desc, r.days desc) from (
    select p.id, p.nickname, p.color, p.avatar, p.unlocks @> '["avatar"]'::jsonb as has_avatar, p.streak, p.last_log, p.age_group, p.id = p_player as me,
      (select count(distinct s.date) from public.sfc_sessions s where s.player_id = p.id and s.date between p_week and p_week + 6 and coalesce(s.mode,'') <> 'speed') as days,
      (select coalesce(sum(s.xp_earned), 0) from public.sfc_sessions s where s.player_id = p.id and s.date between p_week and p_week + 6) as week_xp
    from public.sfc_squad_members m join public.sfc_players p on p.id = m.player_id
    where m.squad_id = p_squad and m.status = 'joined' and not p.archived) r), '[]'::json);
end $$;

-- Parent: every squad request/membership for the family's kids
create or replace function public.sfc_family_squads()
returns json language sql stable security definer set search_path to 'public' as $$
  select coalesce(json_agg(json_build_object('squad', s.id, 'name', s.name, 'code', s.code, 'player', p.id, 'kid', p.nickname, 'status', m.status,
    'mine', s.created_by = p.id,
    'members', (select coalesce(json_agg(x.nickname order by x.nickname), '[]'::json) from public.sfc_squad_members y join public.sfc_players x on x.id = y.player_id where y.squad_id = s.id and y.status = 'joined'))
    order by m.status desc, s.created_at), '[]'::json)
  from public.sfc_squad_members m join public.sfc_squads s on s.id = m.squad_id join public.sfc_players p on p.id = m.player_id
  where p.family_id = public.sfc_my_family() and m.status <> 'declined'
$$;

-- Parent: approve, decline, or remove
create or replace function public.sfc_squad_set(p_player uuid, p_squad uuid, p_join boolean)
returns text language plpgsql security definer set search_path to 'public' as $$
begin
  if not exists (select 1 from public.sfc_players where id = p_player and family_id = public.sfc_my_family()) then raise exception 'not_your_player'; end if;
  if p_join then
    update public.sfc_squad_members set status = 'joined', joined_at = now() where squad_id = p_squad and player_id = p_player;
  else
    delete from public.sfc_squad_members where squad_id = p_squad and player_id = p_player;
  end if;
  return case when p_join then 'joined' else 'removed' end;
end $$;

grant execute on function public.sfc_squad_create(text, uuid, text), public.sfc_squad_request(text, uuid, text), public.sfc_squad_leave(text, uuid, uuid),
  public.sfc_squads_for(text, uuid), public.sfc_squad_board(text, uuid, uuid, date) to anon, authenticated;
grant execute on function public.sfc_family_squads(), public.sfc_squad_set(uuid, uuid, boolean) to authenticated;
revoke execute on function public.sfc_kid_ok(text, uuid) from public, anon, authenticated;
