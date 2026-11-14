-- V-Taper PPL update 2: chat with friends and groups, and push notifications.
-- Paste all of this into Supabase → SQL Editor → New query, then press Run. Safe to run more than once.

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
