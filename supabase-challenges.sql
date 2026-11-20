-- PLAYVORA daily challenges (run AFTER supabase-upgrade.sql). Safe to run more than once.
-- Supabase dashboard > SQL Editor > New query > paste all of this > Run.

create table if not exists public.challenges (
  id text primary key,
  title text not null,
  description text not null,
  kind text not null check (kind in ('plays','distinct_games','min_score')),
  target integer not null check (target > 0),
  xp integer not null check (xp > 0)
);
create table if not exists public.challenge_claims (
  user_id uuid not null references public.profiles(id) on delete cascade,
  challenge_id text not null references public.challenges(id) on delete cascade,
  day date not null,
  claimed_at timestamptz not null default now(),
  primary key (user_id, challenge_id, day)
);
alter table public.challenges enable row level security;
alter table public.challenge_claims enable row level security;
drop policy if exists "challenges are public" on public.challenges;
drop policy if exists "see own claims" on public.challenge_claims;
create policy "challenges are public" on public.challenges for select using (true);
create policy "see own claims" on public.challenge_claims for select using (auth.uid() = user_id);
grant select on public.challenges to anon, authenticated;
grant select on public.challenge_claims to authenticated;

insert into public.challenges (id, title, description, kind, target, xp) values
  ('play_3',      'Warm up',        'Finish 3 games today',               'plays',          3,   30),
  ('play_5',      'On a roll',      'Finish 5 games today',               'plays',          5,   50),
  ('two_games',   'Mix it up',      'Play 2 different games today',       'distinct_games', 2,   25),
  ('three_games', 'Explorer',       'Play 3 different games today',       'distinct_games', 3,   40),
  ('score_300',   'Getting good',   'Score 300 or more in any game',      'min_score',      300, 30),
  ('score_1000',  'High scorer',    'Score 1,000 or more in any game',    'min_score',      1000,60)
on conflict (id) do nothing;

-- Today's three challenges (the same for everyone, picked by the date in UTC) with the caller's progress.
create or replace function public.my_challenges()
returns table (id text, title text, description text, kind text, target integer, xp integer, progress integer, claimed boolean)
language sql stable security definer set search_path = public as $$
  with today as (select (now() at time zone 'utc')::date as d),
  stats as (
    select count(*)::int as plays, count(distinct s.game)::int as games, coalesce(max(s.score), 0)::int as best
    from public.scores s, today
    where s.user_id = auth.uid() and (s.created_at at time zone 'utc')::date = today.d
  ),
  picked as (
    select c.* from public.challenges c, today order by md5(c.id || today.d::text) limit 3
  )
  select p.id, p.title, p.description, p.kind, p.target, p.xp,
    case p.kind when 'plays' then least(st.plays, p.target)
                when 'distinct_games' then least(st.games, p.target)
                else least(st.best, p.target) end,
    exists (select 1 from public.challenge_claims cc, today
            where cc.user_id = auth.uid() and cc.challenge_id = p.id and cc.day = today.d)
  from picked p, stats st
$$;

-- Claim a finished challenge once per day. The database checks the work and grants the XP.
create or replace function public.claim_challenge(p_id text) returns integer
language plpgsql security definer set search_path = public as $$
declare c record;
begin
  if auth.uid() is null then raise exception 'Sign in to claim rewards'; end if;
  select * into c from public.my_challenges() m where m.id = p_id;
  if not found then raise exception 'That is not one of today''s challenges'; end if;
  if c.claimed then raise exception 'Already claimed'; end if;
  if c.progress < c.target then raise exception 'Not finished yet'; end if;
  insert into public.challenge_claims (user_id, challenge_id, day)
    values (auth.uid(), p_id, (now() at time zone 'utc')::date);
  update public.profiles set xp = xp + c.xp, level = 1 + (xp + c.xp) / 200 where id = auth.uid();
  return c.xp;
end $$;

revoke execute on function public.my_challenges() from public;
revoke execute on function public.claim_challenge(text) from public, anon;
grant execute on function public.my_challenges() to anon, authenticated;
grant execute on function public.claim_challenge(text) to authenticated;

-- Achievements now pay out their XP when first unlocked (internal helper, not callable from the browser).
create or replace function public.grant_achievement(p_user uuid, p_id text) returns void
language plpgsql security definer set search_path = public as $$
declare a_xp integer;
begin
  insert into public.user_achievements (user_id, achievement_id) values (p_user, p_id) on conflict do nothing;
  if found then
    select xp into a_xp from public.achievements where id = p_id;
    update public.profiles set xp = xp + a_xp, level = 1 + (xp + a_xp) / 200 where id = p_user;
  end if;
end $$;
revoke execute on function public.grant_achievement(uuid, text) from public, anon, authenticated;

create or replace function public.award_on_score() returns trigger
language plpgsql security definer set search_path = public as $$
declare gained integer; recent integer; games_played integer;
begin
  select count(*) into recent from public.scores
    where user_id = new.user_id and created_at > now() - interval '1 minute';
  if recent <= 5 then
    gained := least(50, 5 + new.score / 100);
    update public.profiles set xp = xp + gained, level = 1 + (xp + gained) / 200 where id = new.user_id;
  end if;
  perform public.grant_achievement(new.user_id, 'first_score');
  select count(distinct game) into games_played from public.scores where user_id = new.user_id;
  if games_played >= 4 then perform public.grant_achievement(new.user_id, 'explorer'); end if;
  if new.score >= 1000 then perform public.grant_achievement(new.user_id, 'high_roller'); end if;
  return new;
end $$;
