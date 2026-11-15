-- Costante update 4: Origin pets that only the admin can give out.
-- Paste all of this into Supabase → SQL Editor → New query, then press Run. Safe to run more than once.

-- Who can give out Origin pets.
create table if not exists public.admins (
  user_id uuid primary key references auth.users on delete cascade
);
alter table public.admins enable row level security;

-- Which accounts have been given which Origin pet. Anyone signed in can read this, so friends can see it's genuine.
create table if not exists public.pet_grants (
  user_id uuid not null references public.profiles on delete cascade,
  pet_id text not null check (pet_id ~ '^[a-z0-9]{2,20}$'),
  granted_by uuid references public.profiles on delete set null,
  granted_at timestamptz not null default now(),
  primary key (user_id, pet_id)
);
alter table public.pet_grants enable row level security;
drop policy if exists "pet_grants: signed-in users can read" on public.pet_grants;
create policy "pet_grants: signed-in users can read" on public.pet_grants for select to authenticated using (true);
grant select on public.pet_grants to authenticated;

create or replace function public.am_i_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid());
$$;
grant execute on function public.am_i_admin() to authenticated;

-- Give or take back an Origin pet by username. Only admins can do this.
create or replace function public.grant_pet(p_username text, p_pet text, p_give boolean) returns text
language plpgsql security definer set search_path = public as $$
declare target uuid;
begin
  if not exists (select 1 from admins where user_id = auth.uid()) then raise exception 'Only the app admin can do that'; end if;
  select id into target from profiles where username = lower(trim(p_username));
  if target is null then raise exception 'No one has the username @%', lower(trim(p_username)); end if;
  if p_give then
    insert into pet_grants (user_id, pet_id, granted_by) values (target, p_pet, auth.uid()) on conflict do nothing;
    return 'Given to @' || lower(trim(p_username));
  else
    delete from pet_grants where user_id = target and pet_id = p_pet;
    return 'Taken back from @' || lower(trim(p_username));
  end if;
end $$;
revoke execute on function public.grant_pet(text, text, boolean) from public, anon;
grant execute on function public.grant_pet(text, text, boolean) to authenticated;

-- The admin's list of everyone who has an Origin pet.
create or replace function public.list_grants() returns table (username text, pet_id text, granted_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from admins where user_id = auth.uid()) then raise exception 'Only the app admin can do that'; end if;
  return query select p.username, g.pet_id, g.granted_at from pet_grants g join profiles p on p.id = g.user_id order by g.granted_at desc;
end $$;
revoke execute on function public.list_grants() from public, anon;
grant execute on function public.list_grants() to authenticated;

-- You (@munchlax) are the admin and get Hollowfang.
insert into public.admins (user_id) select id from public.profiles where username = 'munchlax' on conflict do nothing;
insert into public.pet_grants (user_id, pet_id, granted_by)
  select id, 'hollow', id from public.profiles where username = 'munchlax' on conflict do nothing;
