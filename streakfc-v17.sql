-- StreakFC v17: second parent on a family (each with their own login). Safe to re-run.
create table if not exists public.sfc_family_members (
  family_id uuid not null references public.sfc_families(id) on delete cascade,
  user_id uuid not null unique references auth.users(id) on delete cascade,
  added_at timestamptz not null default now(),
  primary key (family_id, user_id));
create table if not exists public.sfc_family_invites (
  code text primary key,
  family_id uuid not null references public.sfc_families(id) on delete cascade,
  created_at timestamptz not null default now(), used_by uuid, used_at timestamptz);
alter table public.sfc_family_members enable row level security;
alter table public.sfc_family_invites enable row level security;
revoke all on public.sfc_family_members, public.sfc_family_invites from public, anon, authenticated;

-- Owner or added parent: everything that uses sfc_my_family() now works for both
create or replace function public.sfc_my_family() returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce((select id from public.sfc_families where owner = auth.uid()),
                  (select family_id from public.sfc_family_members where user_id = auth.uid() limit 1))
$$;

drop policy if exists sfc_families_owner on public.sfc_families;
drop policy if exists sfc_families_read on public.sfc_families;
drop policy if exists sfc_families_update on public.sfc_families;
drop policy if exists sfc_families_insert on public.sfc_families;
drop policy if exists sfc_families_delete on public.sfc_families;
create policy sfc_families_read on public.sfc_families for select to authenticated using (owner = auth.uid() or id = public.sfc_my_family());
create policy sfc_families_update on public.sfc_families for update to authenticated using (owner = auth.uid() or id = public.sfc_my_family()) with check (owner = auth.uid() or id = public.sfc_my_family());
create policy sfc_families_insert on public.sfc_families for insert to authenticated with check (owner = auth.uid() and public.sfc_my_family() is null);
create policy sfc_families_delete on public.sfc_families for delete to authenticated using (owner = auth.uid());

create or replace function public.sfc_create_family_invite() returns text
language plpgsql security definer set search_path = public as $$
declare fam uuid := public.sfc_my_family(); c text;
begin
  if fam is null then raise exception 'no_family'; end if;
  c := 'FAM-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
  insert into public.sfc_family_invites(code, family_id) values (c, fam);
  return c;
end $$;

create or replace function public.sfc_join_family(p_code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare i public.sfc_family_invites;
begin
  if public.sfc_my_family() is not null then raise exception 'already_in_family'; end if;
  select * into i from public.sfc_family_invites where code = upper(trim(p_code)) and used_by is null and created_at > now() - interval '7 days';
  if i.code is null then raise exception 'code_invalid'; end if;
  insert into public.sfc_family_members(family_id, user_id) values (i.family_id, auth.uid());
  update public.sfc_family_invites set used_by = auth.uid(), used_at = now() where code = i.code;
  return i.family_id;
end $$;

create or replace function public.sfc_family_parents() returns json
language plpgsql stable security definer set search_path = public as $$
declare fam uuid := public.sfc_my_family();
begin
  if fam is null then return '[]'::json; end if;
  return coalesce((select json_agg(x) from (
    select u.email, 'owner' as role, (u.id = auth.uid()) as me from public.sfc_families f join auth.users u on u.id = f.owner where f.id = fam
    union all
    select u.email, 'parent', (u.id = auth.uid()) from public.sfc_family_members m join auth.users u on u.id = m.user_id where m.family_id = fam) x), '[]'::json);
end $$;

revoke execute on function public.sfc_create_family_invite(), public.sfc_join_family(text), public.sfc_family_parents() from public, anon;
grant  execute on function public.sfc_create_family_invite(), public.sfc_join_family(text), public.sfc_family_parents() to authenticated;
select 'v17 ok' as status;
