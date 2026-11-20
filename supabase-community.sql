-- PLAYVORA community: posts, comments (with replies) and likes.
-- Run AFTER supabase-notifications.sql and supabase-reviews.sql. Safe to run more than once.
-- Supabase dashboard > SQL Editor > New query > paste all of this > Run.

do $$ begin
  if to_regprocedure('public.notify(uuid,text,text,text,text)') is null then
    raise exception 'Run supabase-notifications.sql first';
  end if;
  if to_regclass('public.reports') is null then
    raise exception 'Run supabase-reviews.sql first';
  end if;
end $$;

create table if not exists public.posts (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null default 'post' check (kind in ('post','tip','question','recommendation')),
  game text check (game is null or game ~ '^[a-z0-9-]{1,40}$'),
  body text not null check (char_length(trim(body)) between 1 and 500),
  created_at timestamptz not null default now()
);
create index if not exists posts_recent on public.posts (created_at desc);
create index if not exists posts_game on public.posts (game, created_at desc);

create table if not exists public.comments (
  id bigint generated always as identity primary key,
  post_id bigint not null references public.posts(id) on delete cascade,
  parent_id bigint references public.comments(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 300),
  created_at timestamptz not null default now()
);
create index if not exists comments_post on public.comments (post_id, created_at);

create table if not exists public.likes (
  user_id uuid not null references public.profiles(id) on delete cascade,
  post_id bigint not null references public.posts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, post_id)
);

-- Everyone can read. Signed-in players can write as themselves. Authors and admins can delete.
alter table public.posts enable row level security;
alter table public.comments enable row level security;
alter table public.likes enable row level security;
drop policy if exists "posts are public" on public.posts;
drop policy if exists "write own post" on public.posts;
drop policy if exists "delete own post or admin" on public.posts;
drop policy if exists "comments are public" on public.comments;
drop policy if exists "write own comment" on public.comments;
drop policy if exists "delete own comment or admin" on public.comments;
drop policy if exists "likes are public" on public.likes;
drop policy if exists "like as myself" on public.likes;
drop policy if exists "remove my like" on public.likes;
create policy "posts are public" on public.posts for select using (true);
create policy "write own post" on public.posts for insert to authenticated with check (auth.uid() = user_id);
create policy "delete own post or admin" on public.posts for delete to authenticated using (auth.uid() = user_id or public.is_admin());
create policy "comments are public" on public.comments for select using (true);
create policy "write own comment" on public.comments for insert to authenticated with check (auth.uid() = user_id);
create policy "delete own comment or admin" on public.comments for delete to authenticated using (auth.uid() = user_id or public.is_admin());
create policy "likes are public" on public.likes for select using (true);
create policy "like as myself" on public.likes for insert to authenticated with check (auth.uid() = user_id);
create policy "remove my like" on public.likes for delete to authenticated using (auth.uid() = user_id);
revoke all on public.posts, public.comments, public.likes from anon, authenticated;
grant select on public.posts, public.comments, public.likes to anon, authenticated;
grant insert (user_id, kind, game, body) on public.posts to authenticated;
grant insert (user_id, post_id, parent_id, body) on public.comments to authenticated;
grant insert (user_id, post_id) on public.likes to authenticated;
grant delete on public.posts, public.comments, public.likes to authenticated;

-- Spam guard: 10 posts and 30 comments per hour per player. Replies must go under a top-level comment on the same post.
create or replace function public.limit_posting() returns trigger
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if tg_table_name = 'posts' then
    select count(*) into n from public.posts where user_id = new.user_id and created_at > now() - interval '1 hour';
    if n >= 10 then raise exception 'You are posting too fast. Please wait a while.'; end if;
  else
    select count(*) into n from public.comments where user_id = new.user_id and created_at > now() - interval '1 hour';
    if n >= 30 then raise exception 'You are commenting too fast. Please wait a while.'; end if;
    if new.parent_id is not null and not exists (
      select 1 from public.comments where id = new.parent_id and post_id = new.post_id and parent_id is null) then
      raise exception 'You can only reply to a top-level comment on the same post';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists posts_rate on public.posts;
drop trigger if exists comments_rate on public.comments;
create trigger posts_rate before insert on public.posts for each row execute function public.limit_posting();
create trigger comments_rate before insert on public.comments for each row execute function public.limit_posting();

-- New notification types and report targets.
alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('friend_request','friend_accepted','achievement','challenge','reward','level_up','announcement','comment','reaction'));
alter table public.reports drop constraint if exists reports_kind_check;
alter table public.reports add constraint reports_kind_check check (kind in ('review','game','user','post','comment'));

create or replace function public.notify_comment() returns trigger
language plpgsql security definer set search_path = public as $$
declare owner uuid; who text; parent_owner uuid;
begin
  select user_id into owner from public.posts where id = new.post_id;
  select username into who from public.profiles where id = new.user_id;
  if owner is not null and owner <> new.user_id then
    perform public.notify(owner, 'comment', who || ' commented on your post', left(new.body, 120), 'community.html?post=' || new.post_id);
  end if;
  if new.parent_id is not null then
    select user_id into parent_owner from public.comments where id = new.parent_id;
    if parent_owner is not null and parent_owner <> new.user_id and parent_owner is distinct from owner then
      perform public.notify(parent_owner, 'comment', who || ' replied to your comment', left(new.body, 120), 'community.html?post=' || new.post_id);
    end if;
  end if;
  return new;
end $$;
create or replace function public.notify_like() returns trigger
language plpgsql security definer set search_path = public as $$
declare owner uuid; who text; snippet text;
begin
  select user_id, left(body, 80) into owner, snippet from public.posts where id = new.post_id;
  select username into who from public.profiles where id = new.user_id;
  if owner is not null and owner <> new.user_id then
    perform public.notify(owner, 'reaction', who || ' liked your post', snippet, 'community.html?post=' || new.post_id);
  end if;
  return new;
end $$;
drop trigger if exists on_comment_added on public.comments;
drop trigger if exists on_like_added on public.likes;
create trigger on_comment_added after insert on public.comments for each row execute function public.notify_comment();
create trigger on_like_added after insert on public.likes for each row execute function public.notify_like();
