-- v36: coach-assigned group on pre-loaded roster names (EPA older/younger)
alter table public.sfc_org_roster add column if not exists grp text;
create or replace function public.sfc_team_join(p_code text, p_roster uuid, p_nickname text, p_age text, p_pin text, p_label text default null) returns json
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare prog text; r public.sfc_org_roster; fam uuid; pid uuid; tok text; h text; fails int;
begin
  if coalesce(p_pin,'') !~ '^[0-9]{4}$' then raise exception 'pin_must_be_4_digits'; end if;
  select program into prog from public.sfc_program_codes where code = upper(trim(coalesce(p_code,'')));
  if prog is null then raise exception 'code_invalid'; end if;
  if p_roster is not null then
    select * into r from public.sfc_org_roster where id = p_roster and program = prog;
    if r.id is null then raise exception 'not_on_team'; end if;
  else
    if coalesce(trim(p_nickname),'') = '' then raise exception 'name_required'; end if;
    insert into public.sfc_org_roster(org, program, nickname, age_group, claim_code)
      values (public.sfc_program_org(prog), prog, left(trim(p_nickname), 20), left(coalesce(p_age,''), 8), 'P-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6)))
      returning * into r;
  end if;
  if r.player_id is not null then
    pid := r.player_id;
    select pin_hash into h from public.sfc_player_pins where player_id = pid;
    if h is not null then
      select count(*) into fails from public.sfc_pin_attempts where player_id = pid and device_id is null and at > now() - interval '10 minutes';
      if fails >= 5 then return json_build_object('ok', false, 'error', 'locked'); end if;
      if extensions.crypt(p_pin, h) <> h then
        insert into public.sfc_pin_attempts(device_id, player_id) values (null, pid);
        return json_build_object('ok', false, 'error', 'wrong_pin', 'remaining', 4 - fails);
      end if;
      delete from public.sfc_pin_attempts where player_id = pid and device_id is null;
    else
      insert into public.sfc_player_pins(player_id, pin_hash) values (pid, extensions.crypt(p_pin, extensions.gen_salt('bf', 8)));
    end if;
    select family_id into fam from public.sfc_players where id = pid;
    update public.sfc_players set archived = false,
      programs = case when programs @> jsonb_build_array(jsonb_build_object('id', prog)) then programs else programs || jsonb_build_array(public.sfc_prog_entry(prog, age_group)) end
      where id = pid;
  else
    insert into public.sfc_families(owner, parent_name, flags, parent_code)
      values (null, null, jsonb_build_object('team', prog), 'G-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8)))
      returning id into fam;
    insert into public.sfc_players(family_id, nickname, age_group, juggle_min, programs)
      values (fam, r.nickname, nullif(r.age_group, ''), case when coalesce(nullif(regexp_replace(coalesce(r.age_group,''), '\D', '', 'g'), '')::int, 12) <= 8 then 50 when coalesce(nullif(regexp_replace(coalesce(r.age_group,''), '\D', '', 'g'), '')::int, 12) <= 10 then 100 else 150 end,
              jsonb_build_array(public.sfc_prog_entry(prog, r.age_group)))
      returning id into pid;
    update public.sfc_org_roster set player_id = pid where id = r.id;
    insert into public.sfc_player_pins(player_id, pin_hash) values (pid, extensions.crypt(p_pin, extensions.gen_salt('bf', 8)));
  end if;
  if r.grp in ('older','younger') then
    update public.sfc_players set programs = (select jsonb_agg(case when e->>'id' = prog then e || jsonb_build_object('group', r.grp) else e end) from jsonb_array_elements(programs) e) where id = pid;
  end if;
  tok := encode(extensions.gen_random_bytes(24), 'hex');
  insert into public.sfc_devices(family_id, token_hash, label) values (fam, public.sfc_hash(tok), left(coalesce(p_label, 'Team phone'), 40));
  return json_build_object('ok', true, 'token', tok, 'player', pid, 'players', public.sfc_roster_json(fam));
end $$;
