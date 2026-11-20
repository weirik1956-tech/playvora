-- PLAYVORA game ratings, reviews, play stats and reports.
-- Run AFTER supabase-admin.sql (it needs is_admin()). Safe to run more than once.
-- Supabase dashboard > SQL Editor > New query > paste all of this > Run.

-- 1. Reviews: one per player per game, 1-5 stars with an optional written review.
create table if not exists public.reviews (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  game text not null check (game ~ '^[a-z0-9-]{1,40}$'),
  rating integer not null check (rating between 1 and 5),
  body text check (body is null or char_length(body) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, game)
);
create index if not exists reviews_game on public.reviews (game, created_at desc);
alter table public.reviews enable row level security;
drop policy if exists "reviews are public" on public.reviews;
drop policy if exists "write own review" on public.reviews;
drop policy if exists "edit own review" on public.reviews;
drop policy if exists "delete own review or admin" on public.reviews;
create policy "reviews are public" on public.reviews for select using (true);
create policy "write own review" on public.reviews for insert to authenticated with check (auth.uid() = user_id);
create policy "edit own review" on public.reviews for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "delete own review or admin" on public.reviews for delete to authenticated using (auth.uid() = user_id or public.is_admin());
revoke all on public.reviews from anon, authenticated;
grant select on public.reviews to anon, authenticated;
grant insert (user_id, game, rating, body) on public.reviews to authenticated;
grant update (rating, body, updated_at) on public.reviews to authenticated;
grant delete on public.reviews to authenticated;

-- 2. Public summaries used on the homepage and game pages.
create or replace view public.game_ratings with (security_invoker = true) as
  select game, round(avg(rating)::numeric, 1) as avg, count(*)::integer as count
  from public.reviews group by game;
create or replace view public.game_stats with (security_invoker = true) as
  select game, count(*)::integer as plays, count(distinct user_id)::integer as players,
         (count(*) filter (where created_at > now() - interval '7 days'))::integer as plays_7d
  from public.scores group by game;
grant select on public.game_ratings, public.game_stats to anon, authenticated;

-- 3. Reports: players can report a review, game or player; only admins can read or close them.
create table if not exists public.reports (
  id bigint generated always as identity primary key,
  reporter uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('review','game','user')),
  target text not null check (char_length(target) <= 80),
  reason text not null check (char_length(reason) between 3 and 300),
  status text not null default 'open' check (status in ('open','resolved')),
  created_at timestamptz not null default now()
);
create unique index if not exists reports_once on public.reports (reporter, kind, target);
alter table public.reports enable row level security;
drop policy if exists "file own report" on public.reports;
drop policy if exists "admins read reports" on public.reports;
drop policy if exists "admins update reports" on public.reports;
create policy "file own report" on public.reports for insert to authenticated with check (auth.uid() = reporter);
create policy "admins read reports" on public.reports for select to authenticated using (public.is_admin());
create policy "admins update reports" on public.reports for update to authenticated using (public.is_admin()) with check (public.is_admin());
revoke all on public.reports from anon, authenticated;
grant insert (reporter, kind, target, reason) on public.reports to authenticated;
grant select on public.reports to authenticated;
grant update (status) on public.reports to authenticated;
