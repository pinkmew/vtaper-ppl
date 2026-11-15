-- Costante update 7: puzzle leaderboards and Block Stack friend battles.
-- Paste all of this into Supabase → SQL Editor → New query, then press Run. Safe to run more than once.

-- ---------- Puzzle scores ----------
-- mode is 'daily' (one row per day) or a difficulty: 'easy', 'medium', 'hard' (one all-time row, day = 2000-01-01).
-- crown: time_s is the solve time (lower wins). word: score is tries (lower wins), wins counts solved words.
-- block: score is points (higher wins).
create table if not exists public.puzzle_scores (
  user_id uuid not null references public.profiles (id) on delete cascade,
  game text not null check (game in ('crown', 'word', 'block')),
  mode text not null check (mode in ('daily', 'easy', 'medium', 'hard')),
  day date not null,
  score int not null default 0,
  time_s int not null default 0,
  wins int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, game, mode, day)
);
create index if not exists puzzle_scores_board on public.puzzle_scores (game, mode, day);
alter table public.puzzle_scores enable row level security;
drop policy if exists "puzzle_scores: signed-in users can read" on public.puzzle_scores;
create policy "puzzle_scores: signed-in users can read" on public.puzzle_scores for select to authenticated using (true);
grant select on public.puzzle_scores to authenticated;

-- Save a finished puzzle. Keeps your best. Returns true when it's a new best.
create or replace function public.puzzle_submit(p_game text, p_mode text, p_day date, p_score int, p_time int) returns boolean
language plpgsql security definer set search_path = public as $$
declare d date; old puzzle_scores; better boolean;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if p_game not in ('crown', 'word', 'block') or p_mode not in ('daily', 'easy', 'medium', 'hard') then raise exception 'Unknown puzzle'; end if;
  if p_mode = 'daily' then
    if p_day is null or abs(p_day - current_date) > 1 then raise exception 'That daily puzzle has ended'; end if;
    d := p_day;
  else d := date '2000-01-01'; end if;
  if (p_game = 'crown' and (p_time < 4 or p_time > 86400))
    or (p_game = 'word' and (p_score < 1 or p_score > 7 or p_time < 0 or p_time > 86400))
    or (p_game = 'block' and (p_score < 0 or p_score > 200000)) then raise exception 'That score doesn''t look right'; end if;
  select * into old from puzzle_scores where user_id = auth.uid() and game = p_game and mode = p_mode and day = d;
  better := old.user_id is null
    or (p_game = 'crown' and p_time < old.time_s)
    or (p_game = 'word' and (p_score < old.score or (p_score = old.score and p_time < old.time_s)))
    or (p_game = 'block' and p_score > old.score);
  insert into puzzle_scores (user_id, game, mode, day, score, time_s, wins) values (auth.uid(), p_game, p_mode, d, p_score, p_time, 1)
  on conflict (user_id, game, mode, day) do update set
    score = case when better then excluded.score else puzzle_scores.score end,
    time_s = case when better then excluded.time_s else puzzle_scores.time_s end,
    wins = puzzle_scores.wins + 1, updated_at = now();
  return better;
end $$;

-- Ranked board. p_scope 'all' = everyone, 'friends' = you, your friends and group-mates.
create or replace function public.puzzle_board(p_game text, p_mode text, p_day date, p_scope text)
returns table (rank bigint, user_id uuid, username text, avatar text, frame text, level int, score int, time_s int, wins int)
language sql stable security definer set search_path = public as $$
  with s as (
    select ps.*, p.username, p.avatar, p.frame, p.level from puzzle_scores ps join profiles p on p.id = ps.user_id
    where ps.game = p_game and ps.mode = p_mode and ps.day = case when p_mode = 'daily' then p_day else date '2000-01-01' end
      and (p_scope = 'all' or ps.user_id = auth.uid() or are_friends(auth.uid(), ps.user_id) or share_group(auth.uid(), ps.user_id))
  ), r as (
    select rank() over (order by
      case p_game when 'block' then -s.score when 'crown' then s.time_s else case when p_mode = 'daily' then s.score else -s.wins end end,
      s.time_s) as rank, s.* from s
  )
  select r.rank, r.user_id, r.username, r.avatar, r.frame, r.level,
    case when p_game = 'crown' then 0 else r.score end, r.time_s, r.wins
  from r where r.rank <= 50 or r.user_id = auth.uid() order by r.rank, r.username limit 51;
$$;
revoke execute on function public.puzzle_submit(text, text, date, int, int), public.puzzle_board(text, text, date, text) from public, anon;
grant execute on function public.puzzle_submit(text, text, date, int, int), public.puzzle_board(text, text, date, text) to authenticated;

-- ---------- Block Stack battles: same blocks, play in your own time, higher score wins ----------
create table if not exists public.block_battles (
  id bigint generated always as identity primary key,
  p1 uuid not null references auth.users (id) on delete cascade,
  p2 uuid not null references auth.users (id) on delete cascade,
  mins int not null check (mins in (1, 2, 3)),
  seed int not null default floor(random() * 2147483647)::int,
  status text not null default 'open' check (status in ('open', 'done', 'declined')),
  start1 timestamptz, start2 timestamptz,
  score1 int, score2 int,
  winner uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (p1 <> p2)
);
create index if not exists block_battles_p1 on public.block_battles (p1, updated_at desc);
create index if not exists block_battles_p2 on public.block_battles (p2, updated_at desc);
alter table public.block_battles enable row level security;
drop policy if exists "block_battles: players can see" on public.block_battles;
create policy "block_battles: players can see" on public.block_battles for select to authenticated using (auth.uid() in (p1, p2));
grant select on public.block_battles to authenticated;

create or replace function public.bb_challenge(p_opponent uuid, p_mins int) returns bigint
language plpgsql security definer set search_path = public as $$
declare bid bigint; who text;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if p_opponent = auth.uid() then raise exception 'You can''t battle yourself'; end if;
  if not (are_friends(auth.uid(), p_opponent) or share_group(auth.uid(), p_opponent)) then raise exception 'You can only battle friends and group-mates'; end if;
  if p_mins not in (1, 2, 3) then raise exception 'Pick 1, 2 or 3 minutes'; end if;
  if (select count(*) from block_battles where auth.uid() in (p1, p2) and status = 'open') >= 20 then raise exception 'Finish some battles first'; end if;
  insert into block_battles (p1, p2, mins) values (auth.uid(), p_opponent, p_mins) returning id into bid;
  select username into who from profiles where id = auth.uid();
  perform push_enqueue(p_opponent, 'bb:' || bid, 'Block Stack battle', '@' || coalesce(who, 'A friend') || ' challenged you to ' || p_mins || ' minute' || case when p_mins > 1 then 's' else '' end || ' of Block Stack', '#bb=' || bid);
  return bid;
end $$;

-- Starting locks in your attempt. You only get one go.
create or replace function public.bb_start(p_id bigint) returns int
language plpgsql security definer set search_path = public as $$
declare b block_battles;
begin
  select * into b from block_battles where id = p_id for update;
  if b.id is null or auth.uid() not in (b.p1, b.p2) or b.status <> 'open' then raise exception 'That battle isn''t open'; end if;
  if (auth.uid() = b.p1 and b.start1 is not null) or (auth.uid() = b.p2 and b.start2 is not null) then raise exception 'You''ve already played this one'; end if;
  if auth.uid() = b.p1 then update block_battles set start1 = now(), updated_at = now() where id = p_id;
  else update block_battles set start2 = now(), updated_at = now() where id = p_id; end if;
  return b.seed;
end $$;

create or replace function public.bb_submit(p_id bigint, p_score int) returns text
language plpgsql security definer set search_path = public as $$
declare b block_battles; s1 int; s2 int; w uuid; who text; other uuid; me1 boolean;
begin
  select * into b from block_battles where id = p_id for update;
  if b.id is null or auth.uid() not in (b.p1, b.p2) or b.status <> 'open' then raise exception 'That battle isn''t open'; end if;
  me1 := auth.uid() = b.p1;
  if (me1 and b.start1 is null) or (not me1 and b.start2 is null) then raise exception 'Start the game first'; end if;
  if (me1 and b.score1 is not null) or (not me1 and b.score2 is not null) then raise exception 'Your score is already in'; end if;
  if p_score < 0 or p_score > 1500 * b.mins then raise exception 'That score doesn''t look right'; end if;
  if me1 then update block_battles set score1 = p_score, updated_at = now() where id = p_id;
  else update block_battles set score2 = p_score, updated_at = now() where id = p_id; end if;
  select score1, score2 into s1, s2 from block_battles where id = p_id;
  other := case when me1 then b.p2 else b.p1 end;
  select username into who from profiles where id = auth.uid();
  if s1 is not null and s2 is not null then
    w := case when s1 > s2 then b.p1 when s2 > s1 then b.p2 else null end;
    update block_battles set status = 'done', winner = w, updated_at = now() where id = p_id;
    perform push_enqueue(other, 'bb:' || p_id, 'Block Stack result',
      case when w is null then 'You drew with @' || coalesce(who, 'your friend') || ': ' || p_score || ' each'
           when w = other then 'You beat @' || coalesce(who, 'your friend') || '! ' || greatest(s1, s2) || ' to ' || least(s1, s2)
           else '@' || coalesce(who, 'Your friend') || ' won ' || greatest(s1, s2) || ' to ' || least(s1, s2) end, '#bb=' || p_id);
    return 'done';
  end if;
  perform push_enqueue(other, 'bb:' || p_id, 'Block Stack battle', '@' || coalesce(who, 'Your friend') || ' scored ' || p_score || '. Your turn to beat it', '#bb=' || p_id);
  return 'waiting';
end $$;

create or replace function public.bb_decline(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  update block_battles set status = 'declined', updated_at = now()
  where id = p_id and status = 'open' and auth.uid() in (p1, p2)
    and ((auth.uid() = p2 and start2 is null) or (auth.uid() = p1 and start1 is null and start2 is null));
  if not found then raise exception 'That battle can''t be cancelled now'; end if;
end $$;

revoke execute on function public.bb_challenge(uuid, int), public.bb_start(bigint), public.bb_submit(bigint, int), public.bb_decline(bigint) from public, anon;
grant execute on function public.bb_challenge(uuid, int), public.bb_start(bigint), public.bb_submit(bigint, int), public.bb_decline(bigint) to authenticated;

notify pgrst, 'reload schema';
