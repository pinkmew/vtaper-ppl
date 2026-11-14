-- V-Taper PPL: database setup for Supabase.
-- Paste all of this into Supabase → SQL Editor → New query, then press Run. Safe to run more than once.

-- ---------- Tables ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  username text not null unique check (username ~ '^[a-z0-9_]{3,20}$'),
  avatar text,
  frame text not null default '',
  title text not null default '',
  level int not null default 1,
  updated_at timestamptz not null default now()
);

-- Training summary that friends and group-mates can see (no bodyweight, no photos).
create table if not exists public.user_stats (
  id uuid primary key references public.profiles on delete cascade,
  stats jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- Full app backup, private to its owner.
create table if not exists public.user_state (
  id uuid primary key references auth.users on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now()
);

create table if not exists public.friendships (
  id bigint generated always as identity primary key,
  requester uuid not null references public.profiles on delete cascade,
  addressee uuid not null references public.profiles on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  check (requester <> addressee)
);
create unique index if not exists friendships_pair on public.friendships (least(requester, addressee), greatest(requester, addressee));

create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 30),
  code text not null unique,
  owner uuid references public.profiles on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.group_members (
  group_id uuid not null references public.groups on delete cascade,
  user_id uuid not null references public.profiles on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

create table if not exists public.activity (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references public.profiles on delete cascade,
  kind text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists activity_user_time on public.activity (user_id, created_at desc);

-- ---------- Helper checks ----------
create or replace function public.are_friends(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from friendships
    where status = 'accepted' and ((requester = a and addressee = b) or (requester = b and addressee = a)));
$$;

create or replace function public.share_group(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from group_members m1 join group_members m2 on m1.group_id = m2.group_id
    where m1.user_id = a and m2.user_id = b);
$$;

create or replace function public.is_member(g uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from group_members where group_id = g and user_id = auth.uid());
$$;

-- ---------- Actions the app calls ----------
create or replace function public.username_available(u text) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from profiles where username = lower(trim(u)));
$$;

create or replace function public.create_group(gname text) returns public.groups
language plpgsql security definer set search_path = public as $$
declare g public.groups; c text;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if (select count(*) from group_members where user_id = auth.uid()) >= 10 then raise exception 'You can be in up to 10 groups'; end if;
  loop
    select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '') into c from generate_series(1, 6);
    exit when not exists (select 1 from groups where code = c);
  end loop;
  insert into groups (name, code, owner) values (trim(gname), c, auth.uid()) returning * into g;
  insert into group_members (group_id, user_id) values (g.id, auth.uid());
  return g;
end $$;

create or replace function public.join_group(gcode text) returns public.groups
language plpgsql security definer set search_path = public as $$
declare g public.groups;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into g from groups where code = upper(trim(gcode));
  if not found then raise exception 'No group has that code'; end if;
  if (select count(*) from group_members where group_id = g.id) >= 30 then raise exception 'That group is full'; end if;
  insert into group_members (group_id, user_id) values (g.id, auth.uid()) on conflict do nothing;
  return g;
end $$;

-- ---------- Security: who can read and change what ----------
alter table public.profiles enable row level security;
alter table public.user_stats enable row level security;
alter table public.user_state enable row level security;
alter table public.friendships enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.activity enable row level security;

drop policy if exists "profiles: signed-in users can search" on public.profiles;
create policy "profiles: signed-in users can search" on public.profiles for select to authenticated using (true);
drop policy if exists "profiles: create own" on public.profiles;
create policy "profiles: create own" on public.profiles for insert to authenticated with check (id = auth.uid());
drop policy if exists "profiles: edit own" on public.profiles;
create policy "profiles: edit own" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "stats: self, friends and group-mates" on public.user_stats;
create policy "stats: self, friends and group-mates" on public.user_stats for select to authenticated
  using (id = auth.uid() or public.are_friends(auth.uid(), id) or public.share_group(auth.uid(), id));
drop policy if exists "stats: create own" on public.user_stats;
create policy "stats: create own" on public.user_stats for insert to authenticated with check (id = auth.uid());
drop policy if exists "stats: edit own" on public.user_stats;
create policy "stats: edit own" on public.user_stats for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "state: owner only" on public.user_state;
create policy "state: owner only" on public.user_state for all to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "friendships: see own" on public.friendships;
create policy "friendships: see own" on public.friendships for select to authenticated using (auth.uid() in (requester, addressee));
drop policy if exists "friendships: send request" on public.friendships;
create policy "friendships: send request" on public.friendships for insert to authenticated with check (requester = auth.uid() and status = 'pending');
drop policy if exists "friendships: accept request" on public.friendships;
create policy "friendships: accept request" on public.friendships for update to authenticated
  using (addressee = auth.uid()) with check (addressee = auth.uid() and status = 'accepted');
drop policy if exists "friendships: remove" on public.friendships;
create policy "friendships: remove" on public.friendships for delete to authenticated using (auth.uid() in (requester, addressee));

drop policy if exists "groups: members can see" on public.groups;
create policy "groups: members can see" on public.groups for select to authenticated using (public.is_member(id));
drop policy if exists "groups: owner can rename" on public.groups;
create policy "groups: owner can rename" on public.groups for update to authenticated using (owner = auth.uid()) with check (owner = auth.uid());

drop policy if exists "members: see own groups" on public.group_members;
create policy "members: see own groups" on public.group_members for select to authenticated using (public.is_member(group_id));
drop policy if exists "members: leave" on public.group_members;
create policy "members: leave" on public.group_members for delete to authenticated using (user_id = auth.uid());

drop policy if exists "activity: self, friends and group-mates" on public.activity;
create policy "activity: self, friends and group-mates" on public.activity for select to authenticated
  using (user_id = auth.uid() or public.are_friends(auth.uid(), user_id) or public.share_group(auth.uid(), user_id));
drop policy if exists "activity: post own" on public.activity;
create policy "activity: post own" on public.activity for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "activity: delete own" on public.activity;
create policy "activity: delete own" on public.activity for delete to authenticated using (user_id = auth.uid());

-- ---------- Access for the app ----------
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.profiles, public.user_stats, public.user_state,
  public.friendships, public.groups, public.group_members, public.activity to authenticated;
grant usage, select on all sequences in schema public to authenticated;
revoke execute on function public.create_group(text), public.join_group(text) from public, anon;
grant execute on function public.create_group(text), public.join_group(text) to authenticated;
grant execute on function public.username_available(text) to anon, authenticated;
grant execute on function public.are_friends(uuid, uuid), public.share_group(uuid, uuid), public.is_member(uuid) to authenticated;
