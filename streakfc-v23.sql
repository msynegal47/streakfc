-- StreakFC v23: a kid's idea never overwrites an active challenge (touch or day based). Safe to re-run. Applied live 2026-10-18.
create or replace function public.sfc_player_wish(p_token text, p_player uuid, p_wish text) returns void
language plpgsql security definer set search_path = public as $$
declare fam uuid := public.sfc_caller_family(p_token); w text := left(trim(coalesce(p_wish, '')), 40);
begin
  if fam is null or not exists (select 1 from public.sfc_players where id = p_player and family_id = fam) then raise exception 'not_on_this_device'; end if;
  update public.sfc_players set reward = case when w = '' then null else jsonb_build_object('wish', w, 'at', current_date) end
   where id = p_player and (reward is null or (reward->>'days' is null and reward->>'target' is null));
end $$;
