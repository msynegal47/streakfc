-- v31: streak reminders (web push). Kid devices remind the kid, parents get a "who hasn't trained" nudge.
create table if not exists public.sfc_push_subs (
  id uuid primary key default gen_random_uuid(),
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  family_id uuid not null references public.sfc_families(id) on delete cascade,
  player_id uuid references public.sfc_players(id) on delete cascade,
  kind text not null check (kind in ('kid','parent')),
  remind_at time not null default '16:00',
  tz text not null default 'America/Phoenix',
  last_sent date,
  created_at timestamptz not null default now()
);
alter table public.sfc_push_subs enable row level security;
revoke all on public.sfc_push_subs from anon, authenticated;

create or replace function public.sfc_push_save(p_token text, p_player uuid, p_sub jsonb, p_time text, p_tz text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare fam uuid; k text; t time := coalesce(nullif(p_time,'')::time, '16:00'); z text := coalesce(nullif(p_tz,''), 'America/Phoenix');
begin
  if p_sub->>'endpoint' is null or p_sub->'keys'->>'p256dh' is null or p_sub->'keys'->>'auth' is null then raise exception 'bad_sub'; end if;
  if p_player is not null then
    if not public.sfc_kid_ok(p_token, p_player) then raise exception 'not_your_player'; end if;
    select family_id into fam from public.sfc_players where id = p_player; k := 'kid';
  else
    fam := public.sfc_my_family(); if fam is null then raise exception 'not_signed_in'; end if; k := 'parent';
  end if;
  if not exists (select 1 from pg_timezone_names where name = z) then z := 'America/Phoenix'; end if;
  insert into public.sfc_push_subs(endpoint, p256dh, auth, family_id, player_id, kind, remind_at, tz)
  values (p_sub->>'endpoint', p_sub->'keys'->>'p256dh', p_sub->'keys'->>'auth', fam, p_player, k, t, z)
  on conflict (endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth, family_id = excluded.family_id,
    -- one device = one subscription. Parent wins on a shared phone; siblings sharing an iPad get a family-wide reminder.
    player_id = case when sfc_push_subs.kind = 'parent' or excluded.kind = 'parent' then null
                     when sfc_push_subs.player_id is distinct from excluded.player_id then null else excluded.player_id end,
    kind = case when sfc_push_subs.kind = 'parent' or excluded.kind = 'parent' then 'parent' else 'kid' end, remind_at = excluded.remind_at, tz = excluded.tz;
  return k;
end $$;
create or replace function public.sfc_push_off(p_endpoint text) returns void
language sql security definer set search_path to 'public' as $$ delete from public.sfc_push_subs where endpoint = p_endpoint $$;
revoke execute on function public.sfc_push_save(text, uuid, jsonb, text, text), public.sfc_push_off(text) from public;
grant execute on function public.sfc_push_save(text, uuid, jsonb, text, text), public.sfc_push_off(text) to anon, authenticated;

-- Reminder keys live in Vault (values inserted separately, never committed). Only the edge function (service role) can read them.
create or replace function public.sfc_push_config() returns json language sql stable security definer set search_path to 'public', 'vault' as $$
  select json_build_object('vapid_public', (select decrypted_secret from vault.decrypted_secrets where name = 'sfc_vapid_public'),
    'vapid_private', (select decrypted_secret from vault.decrypted_secrets where name = 'sfc_vapid_private'),
    'cron_key', (select decrypted_secret from vault.decrypted_secrets where name = 'sfc_cron_key')) $$;
revoke execute on function public.sfc_push_config() from public, anon, authenticated;
grant execute on function public.sfc_push_config() to service_role;
-- Every 15 min: pg_cron -> pg_net -> push-remind edge function
create extension if not exists pg_cron;
create extension if not exists pg_net;
select cron.unschedule('sfc-push-remind') where exists (select 1 from cron.job where jobname = 'sfc-push-remind');
select cron.schedule('sfc-push-remind', '*/15 * * * *', $c$
  select net.http_post(url := 'https://zrdtwiuekozfteaurrzp.supabase.co/functions/v1/push-remind',
    headers := jsonb_build_object('content-type', 'application/json', 'x-cron-key', (select decrypted_secret from vault.decrypted_secrets where name = 'sfc_cron_key')),
    body := '{}'::jsonb) $c$);
