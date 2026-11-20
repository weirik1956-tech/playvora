-- PLAYVORA public player profiles (run AFTER supabase-challenges.sql). Safe to run more than once.
-- Supabase dashboard > SQL Editor > New query > paste all of this > Run.
-- Moves bio, status and favourite genres into their own table so the "public profile" switch is enforced by the database.

create table if not exists public.profile_details (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  bio text check (bio is null or char_length(bio) <= 160),
  status text not null default 'online' check (status in ('online','away','busy','invisible')),
  favourite_genres text[] not null default '{}' check (cardinality(favourite_genres) <= 8),
  updated_at timestamptz not null default now()
);

do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'profiles' and column_name = 'bio') then
    insert into public.profile_details (user_id, bio, status, favourite_genres)
      select id, bio, status, favourite_genres from public.profiles
      on conflict (user_id) do nothing;
    alter table public.profiles drop column bio, drop column status, drop column favourite_genres;
  end if;
end $$;

revoke update on public.profiles from anon, authenticated;
grant update (username, display_name, is_public) on public.profiles to authenticated;

alter table public.profile_details enable row level security;
drop policy if exists "see visible details" on public.profile_details;
drop policy if exists "add own details" on public.profile_details;
drop policy if exists "change own details" on public.profile_details;
create policy "see visible details" on public.profile_details for select
  using (auth.uid() = user_id or exists (select 1 from public.profiles p where p.id = user_id and p.is_public));
create policy "add own details" on public.profile_details for insert with check (auth.uid() = user_id);
create policy "change own details" on public.profile_details for update
  using (auth.uid() = user_id) with check (auth.uid() = user_id);
grant select on public.profile_details to anon, authenticated;
grant insert, update on public.profile_details to authenticated;

-- Achievements of public profiles can be seen by everyone; private ones only by their owner.
drop policy if exists "see own achievements" on public.user_achievements;
drop policy if exists "see visible achievements" on public.user_achievements;
create policy "see visible achievements" on public.user_achievements for select
  using (auth.uid() = user_id or exists (select 1 from public.profiles p where p.id = user_id and p.is_public));
grant select on public.user_achievements to anon, authenticated;
