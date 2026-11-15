-- Costante update 6: pet battles, the battle ladder, and workout photos friends can see.
-- Paste all of this into Supabase → SQL Editor → New query, then press Run. Safe to run more than once.

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
