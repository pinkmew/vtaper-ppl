-- Costante update 9: emoji reactions on friends' posts.
-- Paste all of this into Supabase → SQL Editor → New query, then press Run. Safe to run more than once.

-- One reaction per person per post. Anyone who can see the post can see its reactions.
create table if not exists public.reactions (
  activity_id bigint not null references public.activity (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  emoji text not null check (emoji in ('💪', '🔥', '👏', '🏆', '😂', '❤️')),
  created_at timestamptz not null default now(),
  primary key (activity_id, user_id)
);
create index if not exists reactions_user on public.reactions (user_id);
alter table public.reactions enable row level security;
drop policy if exists "reactions: on posts you can see" on public.reactions;
create policy "reactions: on posts you can see" on public.reactions for select to authenticated
  using (exists (select 1 from public.activity a where a.id = activity_id));
grant select on public.reactions to authenticated;

-- React, change your reaction, or take it back (send the same emoji again, or null).
-- The post's owner gets a notification the first time you react.
create or replace function public.react(p_activity bigint, p_emoji text) returns text
language plpgsql security definer set search_path = public as $$
declare a activity; old text; who text;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into a from activity where id = p_activity;
  if a.id is null or not (a.user_id = auth.uid() or are_friends(auth.uid(), a.user_id) or share_group(auth.uid(), a.user_id)) then
    raise exception 'That post is gone'; end if;
  if a.user_id = auth.uid() then raise exception 'You can''t react to your own post'; end if;
  select emoji into old from reactions where activity_id = p_activity and user_id = auth.uid();
  if p_emoji is null or p_emoji = old then
    delete from reactions where activity_id = p_activity and user_id = auth.uid();
    return null;
  end if;
  if p_emoji not in ('💪', '🔥', '👏', '🏆', '😂', '❤️') then raise exception 'Unknown reaction'; end if;
  insert into reactions (activity_id, user_id, emoji) values (p_activity, auth.uid(), p_emoji)
  on conflict (activity_id, user_id) do update set emoji = excluded.emoji, created_at = now();
  if old is null then
    select username into who from profiles where id = auth.uid();
    perform push_enqueue(a.user_id, 'react-' || p_activity, '@' || who || ' reacted ' || p_emoji,
      'to your ' || case a.kind when 'workout' then 'workout' when 'pr' then 'PR' when 'cardio' then 'session'
        when 'rank' then 'rank-up' when 'level' then 'level-up' when 'puzzle' then 'puzzle' else 'post' end, '#friends');
  end if;
  return p_emoji;
end $$;
revoke execute on function public.react(bigint, text) from public, anon;
grant execute on function public.react(bigint, text) to authenticated;

notify pgrst, 'reload schema';
