-- v34b: coach resets a team kid's PIN (only kids no parent has claimed). Kid sets a new one next time she joins with the team code.
create or replace function public.sfc_coach_reset_pin(p_player uuid, p_program text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.sfc_is_coach(p_program) then raise exception 'not_coach'; end if;
  if not exists (select 1 from public.sfc_players pl join public.sfc_families f on f.id = pl.family_id
    where pl.id = p_player and f.owner is null and pl.programs @> jsonb_build_array(jsonb_build_object('id', p_program))) then raise exception 'parent_owned'; end if;
  delete from public.sfc_player_pins where player_id = p_player;
  delete from public.sfc_pin_attempts where player_id = p_player;
end $$;
revoke execute on function public.sfc_coach_reset_pin(uuid, text) from public, anon;
grant execute on function public.sfc_coach_reset_pin(uuid, text) to authenticated;
