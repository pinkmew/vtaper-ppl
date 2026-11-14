-- V-Taper PPL update 1: usernames can be changed once every 7 days.
-- Paste into Supabase → SQL Editor → New query, then press Run. Safe to run more than once.

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
