-- v30: close out earned rewards. Parent taps DELIVERED: the challenge is logged to rewards_won and cleared.
alter table public.sfc_players add column if not exists rewards_won jsonb not null default '[]'::jsonb;
grant select (rewards_won) on public.sfc_players to authenticated;
drop function if exists public.sfc_reward_deliver(uuid);
create or replace function public.sfc_reward_deliver(p_player uuid, p_date date default current_date)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r jsonb; out jsonb;
begin
  if not exists (select 1 from public.sfc_players where id = p_player and family_id = public.sfc_my_family()) then raise exception 'not_your_player'; end if;
  select reward into r from public.sfc_players where id = p_player;
  if r is null or coalesce(r->>'target', r->>'days') is null then raise exception 'no_challenge'; end if;
  update public.sfc_players set rewards_won = rewards_won || jsonb_build_array(r || jsonb_build_object('delivered', coalesce(p_date, current_date))), reward = null
   where id = p_player returning rewards_won into out;
  return out;
end $$;
revoke execute on function public.sfc_reward_deliver(uuid, date) from public, anon;
grant execute on function public.sfc_reward_deliver(uuid, date) to authenticated;
