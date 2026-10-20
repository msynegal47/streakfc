-- StreakFC v26: a founding-family invite can only be claimed by the invited email. Applied live Oct 20, 2026.
create or replace function public.sfc_signup_invite_claim(p_code text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.sfc_signup_invites set used_by = auth.uid(), used_at = now()
   where code = upper(trim(coalesce(p_code, ''))) and used_at is null and auth.uid() is not null
     and lower(email) = (select lower(email) from auth.users where id = auth.uid());
end $$;
