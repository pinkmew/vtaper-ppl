-- Costante update 5: the admin can make a gifted pet shiny and set its level (1 to 100).
-- Paste all of this into Supabase → SQL Editor → New query, then press Run. Safe to run more than once.

alter table public.pet_grants add column if not exists myth boolean not null default false;
alter table public.pet_grants add column if not exists level int not null default 1;
alter table public.pet_grants drop constraint if exists pet_grants_level_range;
alter table public.pet_grants add constraint pet_grants_level_range check (level between 1 and 100);

-- Give a pet, or change one already given: shiny on/off and its level.
create or replace function public.set_pet_grant(p_username text, p_pet text, p_myth boolean, p_level int) returns text
language plpgsql security definer set search_path = public as $$
declare target uuid; lv int := greatest(1, least(100, coalesce(p_level, 1)));
begin
  if not exists (select 1 from admins where user_id = auth.uid()) then raise exception 'Only the app admin can do that'; end if;
  select id into target from profiles where username = lower(trim(p_username));
  if target is null then raise exception 'No one has the username @%', lower(trim(p_username)); end if;
  insert into pet_grants (user_id, pet_id, granted_by, myth, level) values (target, p_pet, auth.uid(), coalesce(p_myth, false), lv)
  on conflict (user_id, pet_id) do update set myth = excluded.myth, level = excluded.level;
  return 'Saved for @' || lower(trim(p_username)) || case when coalesce(p_myth, false) then ' · shiny' else '' end || ' · level ' || lv;
end $$;
revoke execute on function public.set_pet_grant(text, text, boolean, int) from public, anon;
grant execute on function public.set_pet_grant(text, text, boolean, int) to authenticated;

drop function if exists public.list_grants();
create function public.list_grants() returns table (username text, pet_id text, granted_at timestamptz, myth boolean, level int)
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from admins where user_id = auth.uid()) then raise exception 'Only the app admin can do that'; end if;
  return query select p.username, g.pet_id, g.granted_at, g.myth, g.level from pet_grants g join profiles p on p.id = g.user_id order by g.granted_at desc;
end $$;
revoke execute on function public.list_grants() from public, anon;
grant execute on function public.list_grants() to authenticated;

notify pgrst, 'reload schema';
