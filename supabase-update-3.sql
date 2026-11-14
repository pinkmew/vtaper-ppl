-- V-Taper PPL update 3: redeemable codes.
-- Paste all of this into Supabase → SQL Editor → New query, then press Run. Safe to run more than once.
-- Codes are stored only as fingerprints (SHA-256), so they never appear in the app or this file.

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
