-- StreakFC v24: founding-family invites (link with email prefilled) + kid links (7-day, multi-device pair code). Safe to re-run.

-- Kid links reuse pair codes: kind 'link' lasts 7 days and works on up to 5 devices.
alter table public.sfc_pair_codes add column if not exists uses int not null default 1;
alter table public.sfc_pair_codes add column if not exists kind text not null default 'pair';

create or replace function public.sfc_create_pair_code() returns text
language plpgsql security definer set search_path = public, extensions as $$
declare fam uuid := public.sfc_my_family(); alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text; i int;
begin
  if fam is null then raise exception 'no_family'; end if;
  delete from public.sfc_pair_codes where expires_at < now() or (family_id = fam and kind = 'pair');
  loop
    c := ''; for i in 1..6 loop c := c || substr(alphabet, 1 + (get_byte(extensions.gen_random_bytes(1), 0) % 32), 1); end loop;
    exit when not exists (select 1 from public.sfc_pair_codes where code = c);
  end loop;
  insert into public.sfc_pair_codes(code, family_id, expires_at) values (c, fam, now() + interval '10 minutes');
  return c;
end $$;

create or replace function public.sfc_create_kid_link() returns text
language plpgsql security definer set search_path = public, extensions as $$
declare fam uuid := public.sfc_my_family(); alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text; i int;
begin
  if fam is null then raise exception 'no_family'; end if;
  delete from public.sfc_pair_codes where expires_at < now() or (family_id = fam and kind = 'link');
  loop
    c := ''; for i in 1..6 loop c := c || substr(alphabet, 1 + (get_byte(extensions.gen_random_bytes(1), 0) % 32), 1); end loop;
    exit when not exists (select 1 from public.sfc_pair_codes where code = c);
  end loop;
  insert into public.sfc_pair_codes(code, family_id, expires_at, uses, kind) values (c, fam, now() + interval '7 days', 5, 'link');
  return c;
end $$;

create or replace function public.sfc_pair_device(p_code text, p_label text default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare pc public.sfc_pair_codes; tok text;
begin
  select * into pc from public.sfc_pair_codes where code = upper(trim(coalesce(p_code,''))) and expires_at > now() and uses > 0;
  if pc.code is null then raise exception 'invalid_or_expired_code'; end if;
  if pc.uses > 1 then update public.sfc_pair_codes set uses = uses - 1 where code = pc.code;
  else delete from public.sfc_pair_codes where code = pc.code; end if;
  tok := encode(extensions.gen_random_bytes(24), 'hex');
  insert into public.sfc_devices(family_id, token_hash, label) values (pc.family_id, public.sfc_hash(tok), left(p_label, 40));
  return json_build_object('token', tok, 'players', public.sfc_roster_json(pc.family_id));
end $$;

-- Founding-family invites: Marcus creates one per parent email, the link prefills the email.
create table if not exists public.sfc_signup_invites (
  code text primary key,
  email text not null,
  label text,
  created_at timestamptz not null default now(),
  used_by uuid, used_at timestamptz);
alter table public.sfc_signup_invites enable row level security;
revoke all on public.sfc_signup_invites from public, anon, authenticated;

create or replace function public.sfc_admin_signup_invite(p_email text, p_label text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare c text := upper(encode(extensions.gen_random_bytes(5), 'hex'));
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  if coalesce(p_email, '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'bad_email'; end if;
  insert into public.sfc_signup_invites(code, email, label) values (c, lower(trim(p_email)), left(p_label, 60));
  return c;
end $$;

create or replace function public.sfc_admin_signup_invites() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.sfc_is_admin() then raise exception 'not_admin'; end if;
  return coalesce((select json_agg(json_build_object('code', i.code, 'email', i.email, 'label', i.label, 'created_at', i.created_at, 'used_at', i.used_at,
      'family', f.parent_name, 'kids', (select count(*) from public.sfc_players p where p.family_id = f.id and not p.archived),
      'active', (select count(distinct s.player_id) from public.sfc_sessions s where s.family_id = f.id and s.date >= current_date - 7))
    order by i.created_at desc)
    from public.sfc_signup_invites i left join public.sfc_families f on f.owner = i.used_by), '[]'::json);
end $$;

-- Anyone holding the link sees which email it is for (prefill only)
create or replace function public.sfc_signup_invite_info(p_code text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('email', email, 'label', label, 'used', used_at is not null)
  from public.sfc_signup_invites where code = upper(trim(coalesce(p_code, '')))
$$;

create or replace function public.sfc_signup_invite_claim(p_code text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.sfc_signup_invites set used_by = auth.uid(), used_at = now()
   where code = upper(trim(coalesce(p_code, ''))) and used_at is null and auth.uid() is not null;
end $$;

revoke execute on function public.sfc_admin_signup_invite(text,text), public.sfc_admin_signup_invites(), public.sfc_create_kid_link(), public.sfc_signup_invite_claim(text) from public, anon;
grant execute on function public.sfc_admin_signup_invite(text,text), public.sfc_admin_signup_invites(), public.sfc_create_kid_link(), public.sfc_signup_invite_claim(text) to authenticated;
grant execute on function public.sfc_signup_invite_info(text) to anon, authenticated;
select 'v24 ok' as status;
