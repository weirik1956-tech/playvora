-- PLAYVORA admin lock (run AFTER supabase-setup.sql). Safe to run more than once.
-- Supabase dashboard > SQL Editor > New query > paste all of this > Run.

-- 1. The game catalog now lives in the database. Everyone can read it; only admins can change it.
create table if not exists public.site_catalog (
  id integer primary key check (id = 1),
  data jsonb not null default '{"hidden":[],"added":[]}'::jsonb check (pg_column_size(data) < 20000),
  updated_at timestamptz not null default now()
);
alter table public.site_catalog enable row level security;
drop policy if exists "catalog is public" on public.site_catalog;
drop policy if exists "admins add catalog" on public.site_catalog;
drop policy if exists "admins change catalog" on public.site_catalog;
create policy "catalog is public" on public.site_catalog for select using (true);
create policy "admins add catalog" on public.site_catalog for insert to authenticated with check (public.is_admin());
create policy "admins change catalog" on public.site_catalog for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
grant select on public.site_catalog to anon, authenticated;
grant insert, update on public.site_catalog to authenticated;
insert into public.site_catalog (id) values (1) on conflict (id) do nothing;

-- 2. Players can never promote themselves: only these profile columns can be edited from the browser.
revoke update on public.profiles from anon, authenticated;
grant update (username, display_name, is_public) on public.profiles to authenticated;

-- 3. MAKE YOURSELF AN ADMIN: change the email below to the one you signed up with, then run this line on its own.
-- update public.profiles set is_admin = true where id = (select id from auth.users where email = 'you@example.com');
