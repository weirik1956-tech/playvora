-- PLAYVORA database upgrade (run AFTER supabase-setup.sql). Safe to run more than once.
-- Supabase dashboard > SQL Editor > New query > paste all of this > Run.

-- 1. Richer profiles. xp, level and is_admin can never be edited by players (see the grant below).
alter table public.profiles
  add column if not exists display_name text check (display_name is null or char_length(display_name) <= 30),
  add column if not exists bio text check (bio is null or char_length(bio) <= 160),
  add column if not exists status text not null default 'online' check (status in ('online','away','busy','invisible')),
  add column if not exists is_public boolean not null default true,
  add column if not exists favourite_genres text[] not null default '{}' check (cardinality(favourite_genres) <= 8),
  add column if not exists xp integer not null default 0 check (xp >= 0),
  add column if not exists level integer not null default 1 check (level >= 1);

revoke update on public.profiles from anon, authenticated;
grant update (username, display_name, bio, status, is_public, favourite_genres) on public.profiles to authenticated;

-- 2. One settings row per player (theme, accent and accessibility choices sync across devices).
create table if not exists public.user_settings (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  data jsonb not null default '{}'::jsonb check (pg_column_size(data) < 4096),
  updated_at timestamptz not null default now()
);
alter table public.user_settings enable row level security;
drop policy if exists "read own settings" on public.user_settings;
drop policy if exists "add own settings" on public.user_settings;
drop policy if exists "change own settings" on public.user_settings;
create policy "read own settings" on public.user_settings for select using (auth.uid() = user_id);
create policy "add own settings" on public.user_settings for insert with check (auth.uid() = user_id);
create policy "change own settings" on public.user_settings for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
grant select, insert, update on public.user_settings to authenticated;

-- 3. Foundations for achievements and favourites.
create table if not exists public.achievements (
  id text primary key,
  name text not null,
  description text not null,
  xp integer not null default 0
);
create table if not exists public.user_achievements (
  user_id uuid not null references public.profiles(id) on delete cascade,
  achievement_id text not null references public.achievements(id) on delete cascade,
  unlocked_at timestamptz not null default now(),
  primary key (user_id, achievement_id)
);
create table if not exists public.favourites (
  user_id uuid not null references public.profiles(id) on delete cascade,
  game text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, game)
);
alter table public.achievements enable row level security;
alter table public.user_achievements enable row level security;
alter table public.favourites enable row level security;
drop policy if exists "achievements are public" on public.achievements;
drop policy if exists "see own achievements" on public.user_achievements;
drop policy if exists "see own favourites" on public.favourites;
drop policy if exists "add own favourites" on public.favourites;
drop policy if exists "remove own favourites" on public.favourites;
create policy "achievements are public" on public.achievements for select using (true);
create policy "see own achievements" on public.user_achievements for select using (auth.uid() = user_id);
create policy "see own favourites" on public.favourites for select using (auth.uid() = user_id);
create policy "add own favourites" on public.favourites for insert with check (auth.uid() = user_id);
create policy "remove own favourites" on public.favourites for delete using (auth.uid() = user_id);
grant select on public.achievements to anon, authenticated;
grant select on public.user_achievements to authenticated;
grant select, insert, delete on public.favourites to authenticated;

insert into public.achievements (id, name, description, xp) values
  ('first_score', 'First Score', 'Save your first score to the leaderboard', 10),
  ('explorer', 'Explorer', 'Save a score in all four games', 40),
  ('high_roller', 'High Roller', 'Score 1,000 or more in any game', 50)
on conflict (id) do nothing;

-- 4. Server-side rewards: XP, levels and achievements are granted by the database, not the browser.
--    XP stops after 5 scores in a minute so spamming the save button earns nothing.
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
  insert into public.user_achievements (user_id, achievement_id) values (new.user_id, 'first_score') on conflict do nothing;
  select count(distinct game) into games_played from public.scores where user_id = new.user_id;
  if games_played >= 4 then
    insert into public.user_achievements (user_id, achievement_id) values (new.user_id, 'explorer') on conflict do nothing;
  end if;
  if new.score >= 1000 then
    insert into public.user_achievements (user_id, achievement_id) values (new.user_id, 'high_roller') on conflict do nothing;
  end if;
  return new;
end $$;
drop trigger if exists on_score_added on public.scores;
create trigger on_score_added after insert on public.scores
  for each row execute function public.award_on_score();
