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

-- ---------- Usernames: once a week ----------
alter table public.profiles add column if not exists username_changed_at timestamptz;

create or replace function public.profiles_username_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.username_changed_at := null;
    return new;
  end if;
  if new.username is distinct from old.username then
    if old.username_changed_at is not null and old.username_changed_at > now() - interval '7 days' then
      raise exception 'You can change your username once a week. Your next change is available on %.',
        to_char(old.username_changed_at + interval '7 days', 'FMDD Mon');
    end if;
    new.username_changed_at := now();
  else
    new.username_changed_at := old.username_changed_at;
  end if;
  return new;
end $$;

drop trigger if exists profiles_username_guard on public.profiles;
create trigger profiles_username_guard before insert or update on public.profiles
  for each row execute function public.profiles_username_guard();

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

-- ======== Chat and push notifications (same as supabase-update-2.sql) ========
-- ---------- Chat ----------
create table if not exists public.messages (
  id bigint generated always as identity primary key,
  sender uuid not null default auth.uid() references public.profiles on delete cascade,
  to_user uuid references public.profiles on delete cascade,
  group_id uuid references public.groups on delete cascade,
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now(),
  check ((to_user is null) <> (group_id is null)),
  check (to_user is null or to_user <> sender)
);
create index if not exists messages_pair on public.messages (sender, to_user, id desc);
create index if not exists messages_group on public.messages (group_id, id desc);

alter table public.messages enable row level security;
drop policy if exists "messages: see own chats" on public.messages;
create policy "messages: see own chats" on public.messages for select to authenticated
  using (sender = auth.uid() or to_user = auth.uid() or (group_id is not null and public.is_member(group_id)));
drop policy if exists "messages: send to friends and own groups" on public.messages;
create policy "messages: send to friends and own groups" on public.messages for insert to authenticated
  with check (sender = auth.uid() and (
    (to_user is not null and public.are_friends(auth.uid(), to_user)) or
    (group_id is not null and public.is_member(group_id))));
drop policy if exists "messages: delete own" on public.messages;
create policy "messages: delete own" on public.messages for delete to authenticated using (sender = auth.uid());
grant select, insert, delete on public.messages to authenticated;

-- No more than 30 messages a minute from one person.
create or replace function public.messages_rate_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from messages where sender = new.sender and created_at > now() - interval '1 minute') >= 30 then
    raise exception 'Slow down a little. Try again in a minute.';
  end if;
  return new;
end $$;
drop trigger if exists messages_rate_limit on public.messages;
create trigger messages_rate_limit before insert on public.messages for each row execute function public.messages_rate_limit();

-- Live updates in the app.
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages') then
    alter publication supabase_realtime add table public.messages;
  end if;
end $$;

-- ---------- Push notifications ----------
-- One row per phone or browser that turned notifications on.
create table if not exists public.push_subs (
  endpoint text primary key,
  user_id uuid not null references auth.users on delete cascade,
  p256dh text not null,
  auth text not null,
  prefs jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.push_subs enable row level security;
drop policy if exists "push_subs: own" on public.push_subs;
create policy "push_subs: own" on public.push_subs for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, delete on public.push_subs to authenticated;

-- Saves this device for the signed-in user (a device that changes account moves to the new one).
create or replace function public.save_push_sub(p_endpoint text, p_p256dh text, p_auth text, p_prefs jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if p_endpoint !~ '^https://' or char_length(p_endpoint) > 1000 then raise exception 'That push address is not valid'; end if;
  insert into push_subs (endpoint, user_id, p256dh, auth, prefs) values (p_endpoint, auth.uid(), p_p256dh, p_auth, coalesce(p_prefs, '{}'::jsonb))
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, prefs = excluded.prefs;
end $$;
revoke execute on function public.save_push_sub(text, text, text, jsonb) from public, anon;
grant execute on function public.save_push_sub(text, text, text, jsonb) to authenticated;

-- Notifications waiting to go out. The app schedules its own reminders; chat and friend alerts are added by triggers.
create table if not exists public.push_queue (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  kind text not null check (kind in ('remind', 'rest', 'streak', 'social', 'test')),
  tag text not null,
  title text not null check (char_length(title) <= 80),
  body text not null default '' check (char_length(body) <= 200),
  url text not null default '' check (char_length(url) <= 200),
  send_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (user_id, tag)
);
create index if not exists push_queue_due on public.push_queue (send_at);
alter table public.push_queue enable row level security;
drop policy if exists "push_queue: see own" on public.push_queue;
create policy "push_queue: see own" on public.push_queue for select to authenticated using (user_id = auth.uid());
drop policy if exists "push_queue: schedule own" on public.push_queue;
create policy "push_queue: schedule own" on public.push_queue for insert to authenticated
  with check (user_id = auth.uid() and kind in ('remind', 'rest', 'streak', 'test') and send_at < now() + interval '15 days');
drop policy if exists "push_queue: change own" on public.push_queue;
create policy "push_queue: change own" on public.push_queue for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid() and kind in ('remind', 'rest', 'streak', 'test') and send_at < now() + interval '15 days');
drop policy if exists "push_queue: cancel own" on public.push_queue;
create policy "push_queue: cancel own" on public.push_queue for delete to authenticated using (user_id = auth.uid());
grant select, insert, update, delete on public.push_queue to authenticated;

create or replace function public.push_queue_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from push_queue where user_id = new.user_id) >= 60 then
    raise exception 'Too many scheduled notifications';
  end if;
  return new;
end $$;
drop trigger if exists push_queue_limit on public.push_queue;
create trigger push_queue_limit before insert on public.push_queue for each row execute function public.push_queue_limit();

-- Chat and friend alerts.
create or replace function public.push_enqueue(p_user uuid, p_tag text, p_title text, p_body text, p_url text) returns void
language sql security definer set search_path = public as $$
  insert into push_queue (user_id, kind, tag, title, body, url, send_at)
  select p_user, 'social', p_tag, left(p_title, 80), left(p_body, 200), left(p_url, 200), now()
  where exists (select 1 from push_subs where user_id = p_user)
  on conflict (user_id, tag) do update set title = excluded.title, body = excluded.body, url = excluded.url, send_at = excluded.send_at;
$$;
revoke execute on function public.push_enqueue(uuid, text, text, text, text) from public, anon, authenticated;

create or replace function public.notify_message() returns trigger
language plpgsql security definer set search_path = public as $$
declare who text; gname text; m record;
begin
  select username into who from profiles where id = new.sender;
  if new.to_user is not null then
    perform push_enqueue(new.to_user, 'dm-' || new.sender, '@' || who, new.body, '#chat=dm:' || new.sender);
  else
    select name into gname from groups where id = new.group_id;
    for m in select user_id from group_members where group_id = new.group_id and user_id <> new.sender loop
      perform push_enqueue(m.user_id, 'grp-' || new.group_id, gname, '@' || who || ': ' || new.body, '#chat=g:' || new.group_id);
    end loop;
  end if;
  return new;
end $$;
drop trigger if exists messages_notify on public.messages;
create trigger messages_notify after insert on public.messages for each row execute function public.notify_message();

create or replace function public.notify_friend() returns trigger
language plpgsql security definer set search_path = public as $$
declare who text;
begin
  if tg_op = 'INSERT' then
    select username into who from profiles where id = new.requester;
    perform push_enqueue(new.addressee, 'fr-' || new.requester, 'New friend request', '@' || who || ' wants to be friends', '#friends');
  elsif new.status = 'accepted' and old.status <> 'accepted' then
    select username into who from profiles where id = new.addressee;
    perform push_enqueue(new.requester, 'fr-' || new.addressee, 'Friend request accepted', '@' || who || ' accepted your friend request', '#friends');
  end if;
  return new;
end $$;
drop trigger if exists friendships_notify on public.friendships;
create trigger friendships_notify after insert or update on public.friendships for each row execute function public.notify_friend();

-- Used only by the "push" server function: takes the notifications that are due and the devices to send them to.
create or replace function public.push_claim() returns table (id bigint, kind text, tag text, title text, body text, url text, subs jsonb)
language sql security definer set search_path = public as $$
  with due as (
    delete from push_queue q where q.id in (select x.id from push_queue x where x.send_at <= now() order by x.send_at limit 300 for update skip locked)
    returning q.*)
  select d.id, d.kind, d.tag, d.title, d.body, d.url,
    coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
      from push_subs s where s.user_id = d.user_id and coalesce((s.prefs ->> d.kind)::boolean, true)), '[]'::jsonb)
  from due d;
$$;
create or replace function public.push_drop(p_endpoints text[]) returns void
language sql security definer set search_path = public as $$
  delete from push_subs where endpoint = any(p_endpoints);
$$;
revoke execute on function public.push_claim(), public.push_drop(text[]) from public, anon, authenticated;
grant execute on function public.push_claim(), public.push_drop(text[]) to service_role;

-- Every 5 seconds: if anything is due, wake the "push" server function. Old undelivered items are cleared after an hour.
create extension if not exists pg_net;
create extension if not exists pg_cron;
create or replace function public.push_tick() returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from push_queue where send_at < now() - interval '1 hour';
  if exists (select 1 from push_queue where send_at <= now()) then
    perform net.http_post(
      url := 'https://ydfmkkwfegrgbjqsazwb.supabase.co/functions/v1/push',
      body := '{}'::jsonb,
      headers := '{"Content-Type": "application/json"}'::jsonb,
      timeout_milliseconds := 8000);
  end if;
end $$;
revoke execute on function public.push_tick() from public, anon, authenticated;
do $$ begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'vtaper-push';
  perform cron.schedule('vtaper-push', '5 seconds', 'select public.push_tick()');
end $$;

grant usage, select on all sequences in schema public to authenticated;

-- ======== Redeemable codes (same as supabase-update-3.sql) ========

create table if not exists public.promo_codes (
  code_hash text primary key,
  label text not null default '',
  reward jsonb not null,
  max_uses int,
  uses int not null default 0,
  active boolean not null default true,
  expires_at timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists public.promo_redemptions (
  user_id uuid not null references auth.users on delete cascade,
  code_hash text not null references public.promo_codes on delete cascade,
  redeemed_at timestamptz not null default now(),
  primary key (user_id, code_hash)
);
create table if not exists public.promo_attempts (
  user_id uuid not null references auth.users on delete cascade,
  at timestamptz not null default now()
);
create index if not exists promo_attempts_user on public.promo_attempts (user_id, at);
-- Nobody can read codes or attempts through the app; only the functions below touch them.
alter table public.promo_codes enable row level security;
alter table public.promo_redemptions enable row level security;
alter table public.promo_attempts enable row level security;
drop policy if exists "redemptions: see own" on public.promo_redemptions;
create policy "redemptions: see own" on public.promo_redemptions for select to authenticated using (user_id = auth.uid());
grant select on public.promo_redemptions to authenticated;

-- Dashes, spaces and letter case don't matter: "gold-ab12c" and "GOLDAB12C" are the same code.
create or replace function public.code_hash(p text) returns text
language sql immutable set search_path = public as $$
  select encode(sha256(convert_to(upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')), 'UTF8')), 'hex');
$$;

-- Redeems a code once per account. Returns the reward, or {"error": "..."}.
create or replace function public.redeem_code(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); h text; c promo_codes;
begin
  if u is null then return jsonb_build_object('error', 'Sign in to redeem codes.'); end if;
  if (select count(*) from promo_attempts where user_id = u and at > now() - interval '1 hour') >= 15 then
    return jsonb_build_object('error', 'Too many tries. Wait an hour and try again.');
  end if;
  insert into promo_attempts (user_id) values (u);
  h := code_hash(p_code);
  select * into c from promo_codes where code_hash = h for update;
  if not found or not c.active or (c.expires_at is not null and c.expires_at < now()) then
    return jsonb_build_object('error', 'That code isn''t valid. Check the spelling.');
  end if;
  if exists (select 1 from promo_redemptions where user_id = u and code_hash = h) then
    return jsonb_build_object('error', 'You''ve already used this code.');
  end if;
  if c.max_uses is not null and c.uses >= c.max_uses then
    return jsonb_build_object('error', 'Too late! Everyone who could claim this code already has.');
  end if;
  insert into promo_redemptions (user_id, code_hash) values (u, h);
  update promo_codes set uses = uses + 1 where code_hash = h;
  return jsonb_build_object('reward', c.reward, 'label', c.label,
    'left', case when c.max_uses is null then null else c.max_uses - c.uses - 1 end);
end $$;
revoke execute on function public.redeem_code(text) from public, anon;
grant execute on function public.redeem_code(text) to authenticated;

-- For you, in the SQL editor only: add or change a code later, e.g.
--   select public.add_code('MYCODE-123', '{"gems": 250}', null, '250 gems');
create or replace function public.add_code(p_code text, p_reward jsonb, p_max_uses int default null, p_label text default '') returns void
language sql security definer set search_path = public as $$
  insert into promo_codes (code_hash, label, reward, max_uses) values (code_hash(p_code), p_label, p_reward, p_max_uses)
  on conflict (code_hash) do update set label = excluded.label, reward = excluded.reward, max_uses = excluded.max_uses, active = true;
$$;
revoke execute on function public.add_code(text, jsonb, int, text) from public, anon, authenticated;

-- The launch codes (stored as fingerprints only).
insert into public.promo_codes (code_hash, label, reward, max_uses) values ('f8b83008279c3d3ab2bc08074fc56d302278a97aaba34eeb7ed8337d7da11a61', 'Mythic pet (first 5)', '{"mythic": "random"}'::jsonb, 5)
  on conflict (code_hash) do update set label = excluded.label, reward = excluded.reward, max_uses = excluded.max_uses;
insert into public.promo_codes (code_hash, label, reward, max_uses) values ('971abd3a5723fa76ef6055b193e9178518c010e8bfb6d7356405055157aee9de', 'Code-only pet: Veelet', '{"pet": "veelet"}'::jsonb, null)
  on conflict (code_hash) do update set label = excluded.label, reward = excluded.reward, max_uses = excluded.max_uses;
insert into public.promo_codes (code_hash, label, reward, max_uses) values ('3686cbc3c4b59599eecc30b291bc9349ee30eb6664c697c7994421a461ad509e', 'Inner Circle cosmetics', '{"items": [{"kind": "frame", "id": "circle"}, {"kind": "banner", "id": "prism"}, {"kind": "title", "id": "innercircle"}]}'::jsonb, null)
  on conflict (code_hash) do update set label = excluded.label, reward = excluded.reward, max_uses = excluded.max_uses;
insert into public.promo_codes (code_hash, label, reward, max_uses) values ('8a2a492f65bdc2e78f692e6386da14ec89766c612fe66e39501aba8fae93d042', '500 gems', '{"gems": 500}'::jsonb, null)
  on conflict (code_hash) do update set label = excluded.label, reward = excluded.reward, max_uses = excluded.max_uses;
insert into public.promo_codes (code_hash, label, reward, max_uses) values ('e20f9aa0374282a83b0ffc839142c5cbce8164c72998917bea5b8028701d0368', 'Free Gold chest', '{"chest": "gold"}'::jsonb, null)
  on conflict (code_hash) do update set label = excluded.label, reward = excluded.reward, max_uses = excluded.max_uses;

-- ======== Origin pets and admin (same as supabase-update-4.sql) ========

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
drop function if exists public.list_grants();
create function public.list_grants() returns table (username text, pet_id text, granted_at timestamptz)
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

-- ======== Shiny and level for gifted pets (same as supabase-update-5.sql) ========

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

-- ===== Update 6: pet battles, ladder, workout photos =====

-- ---------- Pet battles ----------
create table if not exists public.battles (
  id bigint generated always as identity primary key,
  p1 uuid not null references auth.users (id) on delete cascade,
  p2 uuid not null references auth.users (id) on delete cascade,
  format int not null check (format in (1, 3, 6)),
  status text not null default 'pending' check (status in ('pending', 'active', 'done', 'declined')),
  seed int not null default floor(random() * 2147483647)::int,
  team1 jsonb not null,
  team2 jsonb,
  turns jsonb not null default '[]'::jsonb,
  moved1 boolean not null default false,
  moved2 boolean not null default false,
  winner uuid,
  delta int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (p1 <> p2)
);
create index if not exists battles_p1_idx on public.battles (p1, updated_at desc);
create index if not exists battles_p2_idx on public.battles (p2, updated_at desc);
alter table public.battles enable row level security;
drop policy if exists "battles: players can see" on public.battles;
create policy "battles: players can see" on public.battles for select to authenticated using (auth.uid() in (p1, p2));
grant select on public.battles to authenticated;

-- The move each player has locked in for the current turn. Nobody can read this table directly,
-- so you can't peek at your opponent's choice.
create table if not exists public.battle_pending (
  battle_id bigint not null references public.battles (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  turn int not null,
  action jsonb not null,
  primary key (battle_id, user_id)
);
alter table public.battle_pending enable row level security;
revoke all on public.battle_pending from anon, authenticated;

create table if not exists public.battle_ratings (
  user_id uuid primary key references auth.users (id) on delete cascade,
  rating int not null default 1000,
  wins int not null default 0,
  losses int not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.battle_ratings enable row level security;
drop policy if exists "battle_ratings: signed-in users can read" on public.battle_ratings;
create policy "battle_ratings: signed-in users can read" on public.battle_ratings for select to authenticated using (true);
grant select on public.battle_ratings to authenticated;

create or replace function public.battle_team_ok(p_team jsonb, p_format int) returns boolean
language sql immutable as $$
  select jsonb_typeof(p_team) = 'array' and jsonb_array_length(p_team) between 1 and p_format and length(p_team::text) < 4000;
$$;

create or replace function public.battle_challenge(p_opponent uuid, p_format int, p_team jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare bid bigint; who text;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if p_opponent = auth.uid() then raise exception 'You can''t battle yourself'; end if;
  if not (are_friends(auth.uid(), p_opponent) or share_group(auth.uid(), p_opponent)) then raise exception 'You can only battle friends and group-mates'; end if;
  if p_format not in (1, 3, 6) or not battle_team_ok(p_team, p_format) then raise exception 'That team doesn''t fit this battle'; end if;
  if (select count(*) from battles where p1 = auth.uid() and p2 = p_opponent and status = 'pending') >= 1 then raise exception 'You already have a challenge waiting with this friend'; end if;
  if (select count(*) from battles where auth.uid() in (p1, p2) and status in ('pending', 'active')) >= 20 then raise exception 'Finish some battles first'; end if;
  insert into battles (p1, p2, format, team1) values (auth.uid(), p_opponent, p_format, p_team) returning id into bid;
  select username into who from profiles where id = auth.uid();
  perform push_enqueue(p_opponent, 'battle:' || bid, 'Battle challenge', '@' || coalesce(who, 'A friend') || ' challenged you to a ' || p_format || ' v ' || p_format || ' pet battle', '#battle=' || bid);
  return bid;
end $$;

create or replace function public.battle_accept(p_id bigint, p_team jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare b battles; who text;
begin
  select * into b from battles where id = p_id for update;
  if b.id is null or b.p2 <> auth.uid() or b.status <> 'pending' then raise exception 'That challenge isn''t waiting for you'; end if;
  if not battle_team_ok(p_team, b.format) then raise exception 'That team doesn''t fit this battle'; end if;
  update battles set team2 = p_team, status = 'active', updated_at = now() where id = p_id;
  select username into who from profiles where id = auth.uid();
  perform push_enqueue(b.p1, 'battle:' || p_id, 'Battle on', '@' || coalesce(who, 'Your friend') || ' accepted. Pick your first move', '#battle=' || p_id);
end $$;

-- The challenged player says no, or the challenger takes the challenge back.
create or replace function public.battle_decline(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  update battles set status = 'declined', updated_at = now() where id = p_id and status = 'pending' and auth.uid() in (p1, p2);
  if not found then raise exception 'That challenge is no longer waiting'; end if;
end $$;

-- Lock in a move for the current turn. When both players have moved, the turn is added to the battle.
create or replace function public.battle_move(p_id bigint, p_turn int, p_action jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare b battles; a1 jsonb; a2 jsonb; other uuid; who text;
begin
  select * into b from battles where id = p_id for update;
  if b.id is null or auth.uid() not in (b.p1, b.p2) or b.status <> 'active' then raise exception 'That battle isn''t running'; end if;
  if p_turn <> jsonb_array_length(b.turns) then raise exception 'That turn has already been played'; end if;
  if jsonb_typeof(p_action) <> 'object' or length(p_action::text) > 60 then raise exception 'Bad move'; end if;
  insert into battle_pending (battle_id, user_id, turn, action) values (p_id, auth.uid(), p_turn, p_action)
  on conflict (battle_id, user_id) do update set turn = excluded.turn, action = excluded.action;
  select action into a1 from battle_pending where battle_id = p_id and user_id = b.p1 and turn = p_turn;
  select action into a2 from battle_pending where battle_id = p_id and user_id = b.p2 and turn = p_turn;
  other := case when auth.uid() = b.p1 then b.p2 else b.p1 end;
  if a1 is not null and a2 is not null then
    update battles set turns = turns || jsonb_build_array(jsonb_build_array(a1, a2)), moved1 = false, moved2 = false, updated_at = now() where id = p_id;
    delete from battle_pending where battle_id = p_id;
    perform push_enqueue(other, 'battle:' || p_id, 'Battle', 'The turn played out. Pick your next move', '#battle=' || p_id);
    return p_turn + 1;
  end if;
  update battles set moved1 = (a1 is not null), moved2 = (a2 is not null), updated_at = now() where id = p_id;
  select username into who from profiles where id = auth.uid();
  perform push_enqueue(other, 'battle:' || p_id, 'Your turn', '@' || coalesce(who, 'Your friend') || ' picked a move. Your turn in the battle', '#battle=' || p_id);
  return p_turn;
end $$;

create or replace function public.battle_settle(p_id bigint, p_winner uuid) returns int
language plpgsql security definer set search_path = public as $$
declare b battles; loser uuid; rw int; rl int; d int;
begin
  select * into b from battles where id = p_id for update;
  if b.status <> 'active' then return b.delta; end if;
  loser := case when p_winner = b.p1 then b.p2 else b.p1 end;
  insert into battle_ratings (user_id) values (p_winner), (loser) on conflict do nothing;
  select rating into rw from battle_ratings where user_id = p_winner;
  select rating into rl from battle_ratings where user_id = loser;
  d := greatest(1, round(32 * (1 - 1 / (1 + power(10, (rl - rw) / 400.0)))))::int;
  update battle_ratings set rating = rating + d, wins = wins + 1, updated_at = now() where user_id = p_winner;
  update battle_ratings set rating = greatest(0, rating - d), losses = losses + 1, updated_at = now() where user_id = loser;
  update battles set status = 'done', winner = p_winner, delta = d, updated_at = now() where id = p_id;
  delete from battle_pending where battle_id = p_id;
  return d;
end $$;
revoke execute on function public.battle_settle(bigint, uuid) from public, anon, authenticated;

-- Both phones replay the same turns, so they agree on who won. p_turns must match the turns played.
create or replace function public.battle_finish(p_id bigint, p_winner uuid, p_turns int) returns int
language plpgsql security definer set search_path = public as $$
declare b battles;
begin
  select * into b from battles where id = p_id;
  if b.id is null or auth.uid() not in (b.p1, b.p2) then raise exception 'That battle isn''t yours'; end if;
  if b.status = 'done' then return b.delta; end if;
  if b.status <> 'active' or p_winner not in (b.p1, b.p2) or p_turns <> jsonb_array_length(b.turns) or p_turns < 1 then raise exception 'That battle isn''t finished'; end if;
  return battle_settle(p_id, p_winner);
end $$;

create or replace function public.battle_forfeit(p_id bigint) returns int
language plpgsql security definer set search_path = public as $$
declare b battles;
begin
  select * into b from battles where id = p_id;
  if b.id is null or auth.uid() not in (b.p1, b.p2) or b.status <> 'active' then raise exception 'That battle isn''t running'; end if;
  perform push_enqueue(case when auth.uid() = b.p1 then b.p2 else b.p1 end, 'battle:' || p_id, 'You won', 'Your opponent gave up the battle', '#battle=' || p_id);
  return battle_settle(p_id, case when auth.uid() = b.p1 then b.p2 else b.p1 end);
end $$;

revoke execute on function public.battle_challenge(uuid, int, jsonb), public.battle_accept(bigint, jsonb), public.battle_decline(bigint),
  public.battle_move(bigint, int, jsonb), public.battle_finish(bigint, uuid, int), public.battle_forfeit(bigint) from public, anon;
grant execute on function public.battle_challenge(uuid, int, jsonb), public.battle_accept(bigint, jsonb), public.battle_decline(bigint),
  public.battle_move(bigint, int, jsonb), public.battle_finish(bigint, uuid, int), public.battle_forfeit(bigint) to authenticated;

-- ---------- Workout posts: add a photo after posting ----------
drop policy if exists "activity: edit own" on public.activity;
create policy "activity: edit own" on public.activity for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
grant update on public.activity to authenticated;

-- ---------- Workout photos (private bucket; you, your friends and group-mates can see them) ----------
insert into storage.buckets (id, name, public) values ('workout-photos', 'workout-photos', false) on conflict (id) do nothing;
drop policy if exists "workout photos: add own" on storage.objects;
create policy "workout photos: add own" on storage.objects for insert to authenticated
  with check (bucket_id = 'workout-photos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "workout photos: change own" on storage.objects;
create policy "workout photos: change own" on storage.objects for update to authenticated
  using (bucket_id = 'workout-photos' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'workout-photos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "workout photos: delete own" on storage.objects;
create policy "workout photos: delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'workout-photos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "workout photos: self, friends and group-mates" on storage.objects;
create policy "workout photos: self, friends and group-mates" on storage.objects for select to authenticated
  using (bucket_id = 'workout-photos' and ((storage.foldername(name))[1] = auth.uid()::text
    or public.are_friends(auth.uid(), ((storage.foldername(name))[1])::uuid)
    or public.share_group(auth.uid(), ((storage.foldername(name))[1])::uuid)));


notify pgrst, 'reload schema';
