-- ============================================================
-- StreakFC database setup (v1)
-- Paste into Supabase > SQL Editor > New query > Run.
-- Safe to re-run. Does NOT touch your existing tables.
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- TABLES ----------
create table if not exists public.sfc_families (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null unique default auth.uid() references auth.users(id) on delete cascade,
  parent_name text,
  consent_at  timestamptz,
  created_at  timestamptz not null default now()
);

-- Parent passcode (hashed). No direct access; functions only.
create table if not exists public.sfc_family_secrets (
  family_id     uuid primary key references public.sfc_families(id) on delete cascade,
  passcode_hash text
);

create table if not exists public.sfc_players (
  id            uuid primary key default gen_random_uuid(),
  family_id     uuid not null references public.sfc_families(id) on delete cascade,
  nickname      text not null check (char_length(nickname) between 1 and 20),
  age_group     text,
  color         text default '#4fc3f7',
  skill_level   text default 'beginner',
  juggle_min    int  not null default 150,
  xp            int  not null default 0,
  streak        int  not null default 0,
  best_streak   int  not null default 0,
  last_log      date,
  total_touches int  not null default 0,
  sessions      int  not null default 0,
  juggle_pb     int  not null default 0,
  avatar        jsonb,
  unlocks       jsonb not null default '[]',
  badges        jsonb not null default '[]',
  reward        jsonb,
  archived      boolean not null default false,
  created_at    timestamptz not null default now()
);
create index if not exists sfc_players_family on public.sfc_players(family_id);

-- Kid PINs (bcrypt hashed). No direct access; functions only.
create table if not exists public.sfc_player_pins (
  player_id uuid primary key references public.sfc_players(id) on delete cascade,
  pin_hash  text not null
);

create table if not exists public.sfc_sessions (
  id           bigserial primary key,
  family_id    uuid not null references public.sfc_families(id) on delete cascade,
  player_id    uuid not null references public.sfc_players(id) on delete cascade,
  date         date not null,
  touches      int  not null default 0,
  juggle_high  int  default 0,
  juggle_total int  default 0,
  bm_skills    text[] default '{}',
  mv_skills    text[] default '{}',
  difficulty   text,
  full_session boolean default false,
  xp_earned    int default 0,
  source       text default 'kid',
  created_at   timestamptz not null default now()
);
create index if not exists sfc_sessions_player_date on public.sfc_sessions(player_id, date);

-- Paired kid devices (token stored hashed)
create table if not exists public.sfc_devices (
  id         uuid primary key default gen_random_uuid(),
  family_id  uuid not null references public.sfc_families(id) on delete cascade,
  token_hash text not null unique,
  label      text,
  created_at timestamptz not null default now(),
  last_seen  timestamptz
);

create table if not exists public.sfc_pair_codes (
  code       text primary key,
  family_id  uuid not null references public.sfc_families(id) on delete cascade,
  expires_at timestamptz not null
);

create table if not exists public.sfc_pin_attempts (
  id        bigserial primary key,
  device_id uuid not null references public.sfc_devices(id) on delete cascade,
  player_id uuid not null,
  at        timestamptz not null default now()
);

-- ---------- ROW LEVEL SECURITY ----------
alter table public.sfc_families       enable row level security;
alter table public.sfc_family_secrets enable row level security;
alter table public.sfc_players        enable row level security;
alter table public.sfc_player_pins    enable row level security;
alter table public.sfc_sessions       enable row level security;
alter table public.sfc_devices        enable row level security;
alter table public.sfc_pair_codes     enable row level security;
alter table public.sfc_pin_attempts   enable row level security;

create or replace function public.sfc_my_family() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.sfc_families where owner = auth.uid()
$$;

drop policy if exists sfc_families_owner on public.sfc_families;
create policy sfc_families_owner on public.sfc_families for all to authenticated
  using (owner = auth.uid()) with check (owner = auth.uid());

drop policy if exists sfc_players_family on public.sfc_players;
create policy sfc_players_family on public.sfc_players for all to authenticated
  using (family_id = public.sfc_my_family()) with check (family_id = public.sfc_my_family());

drop policy if exists sfc_sessions_family on public.sfc_sessions;
create policy sfc_sessions_family on public.sfc_sessions for all to authenticated
  using (family_id = public.sfc_my_family()) with check (family_id = public.sfc_my_family());

drop policy if exists sfc_devices_family on public.sfc_devices;
create policy sfc_devices_family on public.sfc_devices for select to authenticated
  using (family_id = public.sfc_my_family());
drop policy if exists sfc_devices_delete on public.sfc_devices;
create policy sfc_devices_delete on public.sfc_devices for delete to authenticated
  using (family_id = public.sfc_my_family());
-- secrets / pins / pair codes / attempts: no policies = no direct access.

revoke all on public.sfc_families, public.sfc_family_secrets, public.sfc_players, public.sfc_player_pins,
  public.sfc_sessions, public.sfc_devices, public.sfc_pair_codes, public.sfc_pin_attempts from anon, authenticated;
grant select, insert, update, delete on public.sfc_families, public.sfc_players, public.sfc_sessions to authenticated;
grant select, delete on public.sfc_devices to authenticated;
grant usage on sequence public.sfc_sessions_id_seq to authenticated;

-- ---------- HELPERS ----------
create or replace function public.sfc_hash(t text) returns text
language sql immutable set search_path = public as $$
  select encode(sha256(convert_to(t, 'UTF8')), 'hex')
$$;

create or replace function public.sfc_device_from_token(p_token text) returns public.sfc_devices
language plpgsql security definer set search_path = public as $$
declare d public.sfc_devices;
begin
  select * into d from public.sfc_devices where token_hash = public.sfc_hash(coalesce(p_token,''));
  if d.id is null then raise exception 'invalid_device'; end if;
  update public.sfc_devices set last_seen = now() where id = d.id;
  return d;
end $$;

create or replace function public.sfc_roster_json(p_family uuid) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object(
    'id', id, 'nickname', nickname, 'color', color, 'age_group', age_group,
    'avatar', avatar, 'unlocks', unlocks, 'xp', xp, 'streak', streak,
    'last_log', last_log, 'best_streak', best_streak, 'created_at', created_at
  ) order by created_at), '[]'::json)
  from public.sfc_players where family_id = p_family and not archived
$$;

create or replace function public.sfc_player_json(p_player uuid) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'player', to_jsonb(p) - 'family_id',
    'history', coalesce((select json_object_agg(d, t) from (
        select date::text d, sum(touches) t from public.sfc_sessions
        where player_id = p.id and date >= current_date - 120 group by date) h), '{}'::json)
  ) from public.sfc_players p where p.id = p_player
$$;

-- ---------- PARENT FUNCTIONS (signed-in parent) ----------
create or replace function public.sfc_set_pin(p_player uuid, p_pin text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_pin !~ '^[0-9]{4}$' then raise exception 'pin_must_be_4_digits'; end if;
  if not exists (select 1 from public.sfc_players where id = p_player and family_id = public.sfc_my_family())
    then raise exception 'not_your_player'; end if;
  insert into public.sfc_player_pins(player_id, pin_hash) values (p_player, extensions.crypt(p_pin, extensions.gen_salt('bf', 8)))
  on conflict (player_id) do update set pin_hash = excluded.pin_hash;
end $$;

create or replace function public.sfc_set_passcode(p_code text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare fam uuid := public.sfc_my_family();
begin
  if fam is null then raise exception 'no_family'; end if;
  if p_code !~ '^[0-9]{6}$' then raise exception 'passcode_must_be_6_digits'; end if;
  insert into public.sfc_family_secrets(family_id, passcode_hash) values (fam, extensions.crypt(p_code, extensions.gen_salt('bf', 8)))
  on conflict (family_id) do update set passcode_hash = excluded.passcode_hash;
end $$;

create or replace function public.sfc_check_passcode(p_code text) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare h text;
begin
  select passcode_hash into h from public.sfc_family_secrets where family_id = public.sfc_my_family();
  if h is null then return true; end if;  -- no passcode set yet
  return extensions.crypt(coalesce(p_code,''), h) = h;
end $$;

create or replace function public.sfc_has_passcode() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.sfc_family_secrets where family_id = public.sfc_my_family() and passcode_hash is not null)
$$;

create or replace function public.sfc_create_pair_code() returns text
language plpgsql security definer set search_path = public, extensions as $$
declare fam uuid := public.sfc_my_family(); alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text; i int;
begin
  if fam is null then raise exception 'no_family'; end if;
  delete from public.sfc_pair_codes where expires_at < now() or family_id = fam;
  loop
    c := '';
    for i in 1..6 loop c := c || substr(alphabet, 1 + (get_byte(extensions.gen_random_bytes(1), 0) % 32), 1); end loop;
    exit when not exists (select 1 from public.sfc_pair_codes where code = c);
  end loop;
  insert into public.sfc_pair_codes(code, family_id, expires_at) values (c, fam, now() + interval '10 minutes');
  return c;
end $$;

-- ---------- KID DEVICE FUNCTIONS (no email login; device token) ----------
create or replace function public.sfc_pair_device(p_code text, p_label text default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare pc public.sfc_pair_codes; tok text;
begin
  select * into pc from public.sfc_pair_codes where code = upper(trim(coalesce(p_code,''))) and expires_at > now();
  if pc.code is null then raise exception 'invalid_or_expired_code'; end if;
  delete from public.sfc_pair_codes where code = pc.code;
  tok := encode(extensions.gen_random_bytes(24), 'hex');
  insert into public.sfc_devices(family_id, token_hash, label) values (pc.family_id, public.sfc_hash(tok), left(p_label, 40));
  return json_build_object('token', tok, 'players', public.sfc_roster_json(pc.family_id));
end $$;

create or replace function public.sfc_device_roster(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare d public.sfc_devices := public.sfc_device_from_token(p_token);
begin
  return public.sfc_roster_json(d.family_id);
end $$;

create or replace function public.sfc_player_login(p_token text, p_player uuid, p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare d public.sfc_devices := public.sfc_device_from_token(p_token); h text; fails int;
begin
  if not exists (select 1 from public.sfc_players where id = p_player and family_id = d.family_id and not archived)
    then raise exception 'not_on_this_device'; end if;
  select count(*) into fails from public.sfc_pin_attempts
    where device_id = d.id and player_id = p_player and at > now() - interval '10 minutes';
  if fails >= 5 then return json_build_object('ok', false, 'error', 'locked'); end if;
  select pin_hash into h from public.sfc_player_pins where player_id = p_player;
  if h is null or extensions.crypt(coalesce(p_pin,''), h) <> h then
    insert into public.sfc_pin_attempts(device_id, player_id) values (d.id, p_player);
    return json_build_object('ok', false, 'error', 'wrong_pin', 'remaining', 4 - fails);
  end if;
  delete from public.sfc_pin_attempts where device_id = d.id and player_id = p_player;
  return json_build_object('ok', true, 'data', public.sfc_player_json(p_player));
end $$;

-- Refresh a player's state on a paired device (after the kid already logged in with PIN)
create or replace function public.sfc_player_state(p_token text, p_player uuid) returns json
language plpgsql security definer set search_path = public as $$
declare d public.sfc_devices := public.sfc_device_from_token(p_token);
begin
  if not exists (select 1 from public.sfc_players where id = p_player and family_id = d.family_id)
    then raise exception 'not_on_this_device'; end if;
  return public.sfc_player_json(p_player);
end $$;

-- Save kid progress (whitelisted fields only, with sanity limits)
create or replace function public.sfc_save_state(p_token text, p_player uuid, p_state jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare d public.sfc_devices := public.sfc_device_from_token(p_token); old public.sfc_players;
begin
  select * into old from public.sfc_players where id = p_player and family_id = d.family_id;
  if old.id is null then raise exception 'not_on_this_device'; end if;
  update public.sfc_players set
    xp            = greatest(0, least(coalesce((p_state->>'xp')::int, xp), xp + 2000)),
    streak        = greatest(0, coalesce((p_state->>'streak')::int, streak)),
    best_streak   = greatest(best_streak, coalesce((p_state->>'best_streak')::int, 0)),
    last_log      = coalesce((p_state->>'last_log')::date, last_log),
    total_touches = greatest(0, least(coalesce((p_state->>'total_touches')::int, total_touches), total_touches + 20000)),
    sessions      = greatest(0, coalesce((p_state->>'sessions')::int, sessions)),
    juggle_pb     = greatest(0, least(coalesce((p_state->>'juggle_pb')::int, juggle_pb), 10000)),
    avatar        = coalesce(p_state->'avatar', avatar),
    unlocks       = coalesce(p_state->'unlocks', unlocks),
    badges        = coalesce(p_state->'badges', badges)
  where id = p_player;
end $$;

create or replace function public.sfc_log_session(p_token text, p_player uuid, p_session jsonb, p_state jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare d public.sfc_devices := public.sfc_device_from_token(p_token);
begin
  if not exists (select 1 from public.sfc_players where id = p_player and family_id = d.family_id)
    then raise exception 'not_on_this_device'; end if;
  insert into public.sfc_sessions(family_id, player_id, date, touches, juggle_high, juggle_total,
    bm_skills, mv_skills, difficulty, full_session, xp_earned, source)
  values (d.family_id, p_player, coalesce((p_session->>'date')::date, current_date),
    least(greatest(coalesce((p_session->>'touches')::int, 0), 0), 20000),
    coalesce((p_session->>'juggle_high')::int, 0), coalesce((p_session->>'juggle_total')::int, 0),
    coalesce(array(select jsonb_array_elements_text(p_session->'bm_skills')), '{}'),
    coalesce(array(select jsonb_array_elements_text(p_session->'mv_skills')), '{}'),
    p_session->>'difficulty', coalesce((p_session->>'full_session')::boolean, false),
    least(greatest(coalesce((p_session->>'xp_earned')::int, 0), 0), 1000), 'kid');
  perform public.sfc_save_state(p_token, p_player, p_state);
end $$;

-- ---------- FUNCTION PERMISSIONS ----------
-- Lock every StreakFC function down first (Supabase auto-grants new functions to anon/authenticated),
-- then open only what each role needs. Other functions in your database are untouched.
do $$ declare f text; begin
  foreach f in array array[
    'sfc_my_family()', 'sfc_hash(text)', 'sfc_device_from_token(text)', 'sfc_roster_json(uuid)', 'sfc_player_json(uuid)',
    'sfc_set_pin(uuid,text)', 'sfc_set_passcode(text)', 'sfc_check_passcode(text)', 'sfc_has_passcode()',
    'sfc_create_pair_code()', 'sfc_pair_device(text,text)', 'sfc_device_roster(text)',
    'sfc_player_login(text,uuid,text)', 'sfc_player_state(text,uuid)', 'sfc_save_state(text,uuid,jsonb)',
    'sfc_log_session(text,uuid,jsonb,jsonb)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
  end loop;
  -- signed-in parents
  foreach f in array array[
    'sfc_my_family()', 'sfc_set_pin(uuid,text)', 'sfc_set_passcode(text)', 'sfc_check_passcode(text)',
    'sfc_has_passcode()', 'sfc_create_pair_code()'] loop
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  -- paired kid devices (token checked inside each function)
  foreach f in array array[
    'sfc_pair_device(text,text)', 'sfc_device_roster(text)', 'sfc_player_login(text,uuid,text)',
    'sfc_player_state(text,uuid)', 'sfc_save_state(text,uuid,jsonb)', 'sfc_log_session(text,uuid,jsonb,jsonb)'] loop
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;

-- Done. Tables: sfc_families, sfc_players, sfc_sessions, sfc_devices (+ private pins/secrets/codes/attempts).
