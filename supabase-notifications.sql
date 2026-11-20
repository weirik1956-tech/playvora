-- PLAYVORA notifications (run AFTER supabase-admin.sql, so after friends, challenges and admin). Safe to run more than once.
-- Supabase dashboard > SQL Editor > New query > paste all of this > Run.

create table if not exists public.notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('friend_request','friend_accepted','achievement','challenge','reward','level_up','announcement')),
  title text not null check (char_length(title) <= 120),
  body text check (body is null or char_length(body) <= 300),
  link text check (link is null or link ~ '^[A-Za-z0-9_-]+\.html(\?[A-Za-z0-9_=&%.-]*)?$'),
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists notifications_user on public.notifications (user_id, is_read, created_at desc);

-- Players can read, mark as read, and delete their own notifications. Only the database creates them.
alter table public.notifications enable row level security;
drop policy if exists "see own notifications" on public.notifications;
drop policy if exists "mark own notifications read" on public.notifications;
drop policy if exists "delete own notifications" on public.notifications;
create policy "see own notifications" on public.notifications for select using (auth.uid() = user_id);
create policy "mark own notifications read" on public.notifications for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "delete own notifications" on public.notifications for delete using (auth.uid() = user_id);
revoke all on public.notifications from anon, authenticated;
grant select, delete on public.notifications to authenticated;
grant update (is_read) on public.notifications to authenticated;

-- Internal helpers (not callable from the browser).
create or replace function public.notify(p_user uuid, p_kind text, p_title text, p_body text default null, p_link text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications (user_id, kind, title, body, link)
  values (p_user, p_kind, left(p_title, 120), left(p_body, 300), p_link);
end $$;

-- All XP goes through here so a level-up always sends a notification.
create or replace function public.add_xp(p_user uuid, p_amount integer) returns void
language plpgsql security definer set search_path = public as $$
declare old_lvl integer; new_lvl integer;
begin
  if p_amount <= 0 then return; end if;
  select level into old_lvl from public.profiles where id = p_user;
  update public.profiles set xp = xp + p_amount, level = 1 + (xp + p_amount) / 200
    where id = p_user returning level into new_lvl;
  if new_lvl > old_lvl then
    perform public.notify(p_user, 'level_up', 'You reached level ' || new_lvl, 'Keep playing to climb higher.', 'profile.html');
  end if;
end $$;

create or replace function public.grant_achievement(p_user uuid, p_id text) returns void
language plpgsql security definer set search_path = public as $$
declare a record;
begin
  insert into public.user_achievements (user_id, achievement_id) values (p_user, p_id) on conflict do nothing;
  if found then
    select * into a from public.achievements where id = p_id;
    perform public.add_xp(p_user, a.xp);
    perform public.notify(p_user, 'achievement', 'Achievement unlocked: ' || a.name, a.description || ' (+' || a.xp || ' XP)', 'profile.html');
  end if;
end $$;

create or replace function public.award_on_score() returns trigger
language plpgsql security definer set search_path = public as $$
declare recent integer; games_played integer;
begin
  select count(*) into recent from public.scores
    where user_id = new.user_id and created_at > now() - interval '1 minute';
  if recent <= 5 then
    perform public.add_xp(new.user_id, least(50, 5 + new.score / 100));
  end if;
  perform public.grant_achievement(new.user_id, 'first_score');
  select count(distinct game) into games_played from public.scores where user_id = new.user_id;
  if games_played >= 4 then perform public.grant_achievement(new.user_id, 'explorer'); end if;
  if new.score >= 1000 then perform public.grant_achievement(new.user_id, 'high_roller'); end if;
  return new;
end $$;

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
  perform public.add_xp(auth.uid(), c.xp);
  perform public.notify(auth.uid(), 'reward', 'Challenge complete: ' || c.title, '+' || c.xp || ' XP', 'challenges.html');
  return c.xp;
end $$;

-- Friend requests and acceptances now notify the other player.
create or replace function public.send_friend_request(p_username text) returns text
language plpgsql security definer set search_path = public as $$
declare t uuid; ex record; pending_count integer; uname text;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select id into t from public.profiles where lower(username) = lower(trim(p_username));
  if t is null then raise exception 'No player with that username'; end if;
  if t = auth.uid() then raise exception 'You cannot add yourself'; end if;
  select username into uname from public.profiles where id = auth.uid();
  select * into ex from public.friendships
    where (requester = auth.uid() and addressee = t) or (requester = t and addressee = auth.uid());
  if found then
    if ex.status = 'accepted' then raise exception 'You are already friends'; end if;
    if ex.requester = auth.uid() then raise exception 'Request already sent'; end if;
    update public.friendships set status = 'accepted' where id = ex.id;
    perform public.notify(t, 'friend_accepted', uname || ' accepted your friend request', null, 'friends.html');
    return 'accepted';
  end if;
  select count(*) into pending_count from public.friendships where requester = auth.uid() and status = 'pending';
  if pending_count >= 50 then raise exception 'Too many pending requests. Wait for some to be answered.'; end if;
  insert into public.friendships (requester, addressee) values (auth.uid(), t);
  perform public.notify(t, 'friend_request', uname || ' sent you a friend request', null, 'friends.html');
  return 'sent';
end $$;

create or replace function public.respond_friend(p_id bigint, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
declare rq uuid; uname text;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if p_accept then
    update public.friendships set status = 'accepted'
      where id = p_id and addressee = auth.uid() and status = 'pending' returning requester into rq;
    if rq is not null then
      select username into uname from public.profiles where id = auth.uid();
      perform public.notify(rq, 'friend_accepted', uname || ' accepted your friend request', null, 'friends.html');
    end if;
  else
    delete from public.friendships where id = p_id and addressee = auth.uid() and status = 'pending';
  end if;
end $$;

-- Admins can send an announcement to every player.
create or replace function public.broadcast_announcement(p_title text, p_body text) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  if char_length(trim(coalesce(p_title, ''))) = 0 then raise exception 'Add a title'; end if;
  insert into public.notifications (user_id, kind, title, body, link)
    select id, 'announcement', left(trim(p_title), 120), left(p_body, 300), null from public.profiles;
  get diagnostics n = row_count;
  return n;
end $$;

-- Lock down who can call what.
revoke execute on function public.notify(uuid, text, text, text, text), public.add_xp(uuid, integer),
  public.grant_achievement(uuid, text) from public, anon, authenticated;
revoke execute on function public.broadcast_announcement(text, text) from public, anon;
grant execute on function public.broadcast_announcement(text, text) to authenticated;
