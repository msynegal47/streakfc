-- v35: existing players get onto team/cohort name lists; add a program from a logged-in phone; kid changes own PIN
create or replace function public.sfc_roster_sync() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare e jsonb; prog text;
begin
  for e in select * from jsonb_array_elements(coalesce(new.programs, '[]'::jsonb)) loop
    prog := e->>'id';
    if exists (select 1 from public.sfc_org_programs where id = prog and kind in ('team','cohort'))
       and not exists (select 1 from public.sfc_org_roster where program = prog and player_id = new.id) then
      insert into public.sfc_org_roster(org, program, nickname, age_group, claim_code, player_id)
        values (public.sfc_program_org(prog), prog, new.nickname, coalesce(new.age_group,''), 'P-' || upper(substr(md5(random()::text || new.id::text), 1, 6)), new.id);
    end if;
  end loop;
  return new;
end $$;
drop trigger if exists sfc_roster_sync on public.sfc_players;
create trigger sfc_roster_sync after update of programs on public.sfc_players for each row
  when (new.programs is distinct from old.programs) execute function public.sfc_roster_sync();

-- Phone already logged in to StreakFC + team link: add the program to that player instead of making a new one
create or replace function public.sfc_team_add(p_token text, p_code text, p_player uuid) returns json
language plpgsql security definer set search_path to 'public' as $$
declare d public.sfc_devices := public.sfc_device_from_token(p_token); prog text; p public.sfc_players;
begin
  select program into prog from public.sfc_program_codes where code = upper(trim(coalesce(p_code,'')));
  if prog is null then raise exception 'code_invalid'; end if;
  select * into p from public.sfc_players where id = p_player and family_id = d.family_id and not archived;
  if p.id is null then raise exception 'not_on_this_device'; end if;
  if not p.programs @> jsonb_build_array(jsonb_build_object('id', prog)) then
    update public.sfc_players set programs = coalesce(programs,'[]'::jsonb) || jsonb_build_array(public.sfc_prog_entry(prog, p.age_group)) where id = p.id;
  end if;
  return json_build_object('ok', true, 'program', prog, 'name', (select name from public.sfc_org_programs where id = prog));
end $$;

-- Kid changes their own PIN (needs the current one)
create or replace function public.sfc_kid_set_pin(p_token text, p_player uuid, p_old text, p_new text) returns json
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare d public.sfc_devices := public.sfc_device_from_token(p_token); h text; fails int;
begin
  if coalesce(p_new,'') !~ '^[0-9]{4}$' then raise exception 'pin_must_be_4_digits'; end if;
  if not exists (select 1 from public.sfc_players where id = p_player and family_id = d.family_id and not archived) then raise exception 'not_on_this_device'; end if;
  select count(*) into fails from public.sfc_pin_attempts where device_id = d.id and player_id = p_player and at > now() - interval '10 minutes';
  if fails >= 5 then return json_build_object('ok', false, 'error', 'locked'); end if;
  select pin_hash into h from public.sfc_player_pins where player_id = p_player;
  if h is null or extensions.crypt(coalesce(p_old,''), h) <> h then
    insert into public.sfc_pin_attempts(device_id, player_id) values (d.id, p_player);
    return json_build_object('ok', false, 'error', 'wrong_pin', 'remaining', 4 - fails);
  end if;
  update public.sfc_player_pins set pin_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 8)) where player_id = p_player;
  return json_build_object('ok', true);
end $$;
grant execute on function public.sfc_team_add(text, text, uuid), public.sfc_kid_set_pin(text, uuid, text, text) to anon, authenticated;
