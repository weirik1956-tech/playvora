-- PLAYVORA database setup.
-- Supabase dashboard > SQL Editor > New query > paste all of this > Run.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check (username ~ '^[a-z0-9_]{3,20}$'),
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.scores (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  game text not null check (game in ('tetris','space-shooter','snake','2048')),
  score integer not null check (score > 0 and score <= 10000000),
  created_at timestamptz not null default now()
);
create index if not exists scores_game_score_idx on public.scores (game, score desc);

-- Create a profile automatically whenever someone signs up.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, username)
  values (new.id, coalesce(nullif(new.raw_user_meta_data->>'username',''), 'player' || substr(new.id::text,1,8)));
  return new;
exception when others then
  insert into public.profiles (id, username) values (new.id, 'player' || substr(new.id::text,1,8));
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false)
$$;

alter table public.profiles enable row level security;
alter table public.scores enable row level security;

-- Profiles: anyone can read; you can change only your own username (never is_admin).
create policy "profiles are public" on public.profiles for select using (true);
create policy "edit own profile" on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);
revoke update on public.profiles from anon, authenticated;
grant update (username) on public.profiles to authenticated;

-- Scores: anyone can read; signed-in players add their own; only admins delete.
create policy "scores are public" on public.scores for select using (true);
create policy "save own scores" on public.scores for insert with check (auth.uid() = user_id);
create policy "admins delete scores" on public.scores for delete using (public.is_admin());

-- Best score per player per game.
create or replace view public.leaderboard with (security_invoker = true) as
  select s.game, p.username, max(s.score) as score
  from public.scores s join public.profiles p on p.id = s.user_id
  group by s.game, p.username;
grant select on public.leaderboard to anon, authenticated;

-- AFTER you sign up on the site, make yourself an admin (replace yourname):
-- update public.profiles set is_admin = true where username = 'yourname';
