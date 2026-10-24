-- v28: Challenges (Founders Challenge first). Kid asks, parent approves, weekly board ranked by days trained, XP tiebreak.
create table if not exists public.sfc_challenges (
  id text primary key,
  name text not null,
  blurb text,
  starts date not null,
  ends date,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.sfc_challenge_members (
  challenge_id text not null references public.sfc_challenges(id) on delete cascade,
  player_id uuid not null references public.sfc_players(id) on delete cascade,
  status text not null default 'requested' check (status in ('requested','joined','declined')),
  requested_at timestamptz,
  joined_at timestamptz,
  primary key (challenge_id, player_id)
);
alter table public.sfc_challenges enable row level security;
alter table public.sfc_challenge_members enable row level security;
revoke all on public.sfc_challenges, public.sfc_challenge_members from anon, authenticated;

insert into public.sfc_challenges(id, name, blurb, starts)
values ('founders', 'Founders Challenge', 'Every founding StreakFC kid, battling week by week. Most days trained wins. Resets every Monday.', '2026-11-01')
on conflict (id) do nothing;

-- Challenges this kid can see + their status. Kid device token or parent session.
create or replace function public.sfc_challenges_for(p_token text, p_player uuid)
returns json language plpgsql security definer set search_path to 'public' as $$
declare fam uuid := public.sfc_caller_family(p_token);
begin
  if fam is null or not exists (select 1 from public.sfc_players where id = p_player and family_id = fam) then raise exception 'not_your_player'; end if;
  return coalesce((select json_agg(json_build_object('id', c.id, 'name', c.name, 'blurb', c.blurb, 'starts', c.starts, 'ends', c.ends,
      'status', m.status, 'members', (select count(*) from public.sfc_challenge_members x where x.challenge_id = c.id and x.status = 'joined')) order by c.starts)
    from public.sfc_challenges c left join public.sfc_challenge_members m on m.challenge_id = c.id and m.player_id = p_player
    where c.active and (c.ends is null or c.ends >= current_date)), '[]'::json);
end $$;

-- Kid taps "Ask my parent"
create or replace function public.sfc_challenge_request(p_token text, p_player uuid, p_challenge text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare fam uuid := public.sfc_caller_family(p_token);
begin
  if fam is null or not exists (select 1 from public.sfc_players where id = p_player and family_id = fam) then raise exception 'not_your_player'; end if;
  insert into public.sfc_challenge_members(challenge_id, player_id, status, requested_at) values (p_challenge, p_player, 'requested', now())
  on conflict (challenge_id, player_id) do update set status = case when sfc_challenge_members.status = 'joined' then 'joined' else 'requested' end, requested_at = now();
  return (select status from public.sfc_challenge_members where challenge_id = p_challenge and player_id = p_player);
end $$;

-- Parent approves (join) or declines / removes
create or replace function public.sfc_challenge_set(p_player uuid, p_challenge text, p_join boolean)
returns text language plpgsql security definer set search_path to 'public' as $$
begin
  if not exists (select 1 from public.sfc_players where id = p_player and family_id = public.sfc_my_family()) then raise exception 'not_your_player'; end if;
  insert into public.sfc_challenge_members(challenge_id, player_id, status, joined_at) values (p_challenge, p_player, case when p_join then 'joined' else 'declined' end, case when p_join then now() end)
  on conflict (challenge_id, player_id) do update set status = excluded.status, joined_at = coalesce(excluded.joined_at, sfc_challenge_members.joined_at);
  return case when p_join then 'joined' else 'declined' end;
end $$;

-- Family view for the parent dashboard: each kid's status per active challenge
create or replace function public.sfc_family_challenges()
returns json language sql stable security definer set search_path to 'public' as $$
  select coalesce(json_agg(json_build_object('id', c.id, 'name', c.name, 'blurb', c.blurb, 'starts', c.starts,
    'kids', (select coalesce(json_object_agg(p.id, coalesce(m.status, 'none')), '{}'::json) from public.sfc_players p
             left join public.sfc_challenge_members m on m.player_id = p.id and m.challenge_id = c.id
             where p.family_id = public.sfc_my_family() and not p.archived))), '[]'::json)
  from public.sfc_challenges c where c.active and (c.ends is null or c.ends >= current_date) and public.sfc_my_family() is not null
$$;

-- The board: this week ranked by days trained then XP; last week's champ; titles won so far.
create or replace function public.sfc_challenge_board(p_token text, p_player uuid, p_challenge text, p_week date)
returns json language plpgsql security definer set search_path to 'public' as $$
declare fam uuid := public.sfc_caller_family(p_token); c public.sfc_challenges;
begin
  if fam is null or not exists (select 1 from public.sfc_players where id = p_player and family_id = fam) then raise exception 'not_your_player'; end if;
  if not exists (select 1 from public.sfc_challenge_members where challenge_id = p_challenge and player_id = p_player and status = 'joined') then raise exception 'not_joined'; end if;
  if p_week not between current_date - 7 and current_date + 1 then raise exception 'bad_date'; end if;
  select * into c from public.sfc_challenges where id = p_challenge;
  return json_build_object('starts', c.starts, 'name', c.name,
    'rows', coalesce((select json_agg(r order by r.days desc, r.week_xp desc) from (
      select p.id, p.nickname, p.color, p.avatar, p.unlocks @> '["avatar"]'::jsonb as has_avatar, p.streak, p.last_log, p.age_group, p.id = p_player as me,
        (select count(distinct s.date) from public.sfc_sessions s where s.player_id = p.id and s.date between greatest(p_week, c.starts) and p_week + 6 and coalesce(s.mode,'') <> 'speed') as days,
        (select coalesce(sum(s.xp_earned), 0) from public.sfc_sessions s where s.player_id = p.id and s.date between greatest(p_week, c.starts) and p_week + 6) as week_xp,
        (select count(*) from (
          select w.wk, (select x.player_id from public.sfc_challenge_members x
             where x.challenge_id = c.id and x.status = 'joined' and exists (select 1 from public.sfc_sessions s where s.player_id = x.player_id and s.date between w.wk and w.wk + 6 and coalesce(s.mode,'') <> 'speed')
             order by (select count(distinct s.date) from public.sfc_sessions s where s.player_id = x.player_id and s.date between w.wk and w.wk + 6 and coalesce(s.mode,'') <> 'speed') desc,
                      (select coalesce(sum(s.xp_earned), 0) from public.sfc_sessions s where s.player_id = x.player_id and s.date between w.wk and w.wk + 6) desc limit 1) as champ
          from (select g::date as wk from generate_series(c.starts + ((8 - extract(isodow from c.starts)::int) % 7), p_week - 7, interval '7 days') g) w) t where t.champ = p.id) as titles
      from public.sfc_challenge_members m join public.sfc_players p on p.id = m.player_id
      where m.challenge_id = c.id and m.status = 'joined' and not p.archived) r), '[]'::json),
    'last', (select json_build_object('id', p.id, 'nickname', p.nickname, 'me', p.id = p_player,
              'days', (select count(distinct s.date) from public.sfc_sessions s where s.player_id = p.id and s.date between p_week - 7 and p_week - 1 and coalesce(s.mode,'') <> 'speed'),
              'xp', (select coalesce(sum(s.xp_earned), 0) from public.sfc_sessions s where s.player_id = p.id and s.date between p_week - 7 and p_week - 1))
            from public.sfc_challenge_members m join public.sfc_players p on p.id = m.player_id
            where m.challenge_id = c.id and m.status = 'joined' and p_week - 7 >= c.starts and exists (select 1 from public.sfc_sessions s where s.player_id = p.id and s.date between p_week - 7 and p_week - 1 and coalesce(s.mode,'') <> 'speed')
            order by (select count(distinct s.date) from public.sfc_sessions s where s.player_id = p.id and s.date between p_week - 7 and p_week - 1 and coalesce(s.mode,'') <> 'speed') desc,
                     (select coalesce(sum(s.xp_earned), 0) from public.sfc_sessions s where s.player_id = p.id and s.date between p_week - 7 and p_week - 1) desc limit 1));
end $$;

grant execute on function public.sfc_challenges_for(text, uuid), public.sfc_challenge_request(text, uuid, text), public.sfc_challenge_board(text, uuid, text, date) to anon, authenticated;
grant execute on function public.sfc_challenge_set(uuid, text, boolean), public.sfc_family_challenges() to authenticated;
