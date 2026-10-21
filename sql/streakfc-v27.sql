-- v27: public invite branding so the console login shows the inviting academy (not hardcoded MSA)
create or replace function public.sfc_invite_brand(p_code text) returns jsonb language sql security definer set search_path to 'public' stable as $$
  select jsonb_build_object('name', o.name, 'short', o.short, 'brand', o.brand)
  from public.sfc_coach_invites i join public.sfc_orgs o on o.id = coalesce(i.org, public.sfc_program_org(i.program))
  where i.code = upper(p_code) limit 1 $$;
revoke all on function public.sfc_invite_brand(text) from public;
grant execute on function public.sfc_invite_brand(text) to anon, authenticated;
