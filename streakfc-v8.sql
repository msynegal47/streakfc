-- StreakFC v8: positions, season goals, private coach notes. Safe to re-run.
alter table public.sfc_players add column if not exists pos1  text;                          -- preferred position
alter table public.sfc_players add column if not exists pos2  text;                          -- secondary position
alter table public.sfc_players add column if not exists goals jsonb not null default '{}';   -- {"items":[{"t":"..","done":false}],"coach":"comment"}

-- Private coach notes: no direct access for anyone; admin/coach functions only. Kids and parents never see these.
create table if not exists public.sfc_coach_notes (
  player_id  uuid primary key references public.sfc_players(id) on delete cascade,
  focus      text,
  note       text,
  updated_at timestamptz not null default now()
);
alter table public.sfc_coach_notes enable row level security;
revoke all on public.sfc_coach_notes from public, anon, authenticated;

-- Admin: update a few player fields (programs, positions, goals coach comment)
create or replace function public.sfc_admin_update_player(p_player uuid, p_patch jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  if jsonb_typeof(p_patch) <> 'object' or length(p_patch::text) > 4000 then raise exception 'bad_patch'; end if;
  update public.sfc_players set
    programs = case when jsonb_typeof(p_patch->'programs') = 'array' then p_patch->'programs' else programs end,
    pos1     = case when p_patch ? 'pos1' then left(p_patch->>'pos1', 6) else pos1 end,
    pos2     = case when p_patch ? 'pos2' then left(p_patch->>'pos2', 6) else pos2 end,
    goals    = case when p_patch ? 'goal_comment' then jsonb_set(goals, '{coach}', to_jsonb(left(p_patch->>'goal_comment', 300))) else goals end
  where id = p_player;
end $$;

create or replace function public.sfc_admin_notes() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  return coalesce((select json_object_agg(player_id, json_build_object('focus', focus, 'note', note, 'updated_at', updated_at)) from public.sfc_coach_notes), '{}'::json);
end $$;

create or replace function public.sfc_admin_set_note(p_player uuid, p_focus text, p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  insert into public.sfc_coach_notes(player_id, focus, note, updated_at) values (p_player, left(p_focus, 200), left(p_note, 1000), now())
  on conflict (player_id) do update set focus = excluded.focus, note = excluded.note, updated_at = now();
end $$;

revoke execute on function public.sfc_admin_update_player(uuid,jsonb), public.sfc_admin_notes(), public.sfc_admin_set_note(uuid,text,text) from public, anon;
grant  execute on function public.sfc_admin_update_player(uuid,jsonb), public.sfc_admin_notes(), public.sfc_admin_set_note(uuid,text,text) to authenticated;
select 'v8 ok' as status;
