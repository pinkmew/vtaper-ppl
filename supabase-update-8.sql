-- Costante update 8: Gym Word in Italian and Turkish, with their own leaderboards.
-- Paste all of this into Supabase → SQL Editor → New query, then press Run. Safe to run more than once.

alter table public.puzzle_scores drop constraint if exists puzzle_scores_game_check;
alter table public.puzzle_scores add constraint puzzle_scores_game_check check (game in ('crown', 'word', 'word_it', 'word_tr', 'block'));

-- Save a finished puzzle. Keeps your best. Returns true when it's a new best.
-- word, word_it and word_tr are Gym Word in English, Italian and Turkish; each has its own board.
create or replace function public.puzzle_submit(p_game text, p_mode text, p_day date, p_score int, p_time int) returns boolean
language plpgsql security definer set search_path = public as $$
declare d date; old puzzle_scores; better boolean; w boolean := p_game in ('word', 'word_it', 'word_tr');
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if p_game not in ('crown', 'word', 'word_it', 'word_tr', 'block') or p_mode not in ('daily', 'easy', 'medium', 'hard') then raise exception 'Unknown puzzle'; end if;
  if p_mode = 'daily' then
    if p_day is null or abs(p_day - current_date) > 1 then raise exception 'That daily puzzle has ended'; end if;
    d := p_day;
  else d := date '2000-01-01'; end if;
  if (p_game = 'crown' and (p_time < 4 or p_time > 86400))
    or (w and (p_score < 1 or p_score > 7 or p_time < 0 or p_time > 86400))
    or (p_game = 'block' and (p_score < 0 or p_score > 200000)) then raise exception 'That score doesn''t look right'; end if;
  select * into old from puzzle_scores where user_id = auth.uid() and game = p_game and mode = p_mode and day = d;
  better := old.user_id is null
    or (p_game = 'crown' and p_time < old.time_s)
    or (w and (p_score < old.score or (p_score = old.score and p_time < old.time_s)))
    or (p_game = 'block' and p_score > old.score);
  insert into puzzle_scores (user_id, game, mode, day, score, time_s, wins) values (auth.uid(), p_game, p_mode, d, p_score, p_time, 1)
  on conflict (user_id, game, mode, day) do update set
    score = case when better then excluded.score else puzzle_scores.score end,
    time_s = case when better then excluded.time_s else puzzle_scores.time_s end,
    wins = puzzle_scores.wins + 1, updated_at = now();
  return better;
end $$;
revoke execute on function public.puzzle_submit(text, text, date, int, int) from public, anon;
grant execute on function public.puzzle_submit(text, text, date, int, int) to authenticated;

notify pgrst, 'reload schema';
