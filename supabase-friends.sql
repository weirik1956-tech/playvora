-- PLAYVORA friends (run AFTER supabase-players.sql). Safe to run more than once.
-- Supabase dashboard > SQL Editor > New query > paste all of this > Run.

create table if not exists public.friendships (
  id bigint generated always as identity primary key,
  requester uuid not null references public.profiles(id) on delete cascade,
  addressee uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  check (requester <> addressee)
);
-- One friendship per pair of players, whichever of them asked first.
create unique index if not exists friendships_pair on public.friendships (least(requester, addressee), greatest(requester, addressee));
create index if not exists friendships_addressee on public.friendships (addressee);

-- Browsers never touch this table directly; everything goes through the functions below.
alter table public.friendships enable row level security;
revoke all on public.friendships from anon, authenticated;

create or replace function public.send_friend_request(p_username text) returns text
language plpgsql security definer set search_path = public as $$
declare t uuid; ex record; pending_count integer;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select id into t from public.profiles where lower(username) = lower(trim(p_username));
  if t is null then raise exception 'No player with that username'; end if;
  if t = auth.uid() then raise exception 'You cannot add yourself'; end if;
  select * into ex from public.friendships
    where (requester = auth.uid() and addressee = t) or (requester = t and addressee = auth.uid());
  if found then
    if ex.status = 'accepted' then raise exception 'You are already friends'; end if;
    if ex.requester = auth.uid() then raise exception 'Request already sent'; end if;
    update public.friendships set status = 'accepted' where id = ex.id;
    return 'accepted';
  end if;
  select count(*) into pending_count from public.friendships where requester = auth.uid() and status = 'pending';
  if pending_count >= 50 then raise exception 'Too many pending requests. Wait for some to be answered.'; end if;
  insert into public.friendships (requester, addressee) values (auth.uid(), t);
  return 'sent';
end $$;

create or replace function public.respond_friend(p_id bigint, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if p_accept then
    update public.friendships set status = 'accepted' where id = p_id and addressee = auth.uid() and status = 'pending';
  else
    delete from public.friendships where id = p_id and addressee = auth.uid() and status = 'pending';
  end if;
end $$;

create or replace function public.remove_friendship(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  delete from public.friendships where id = p_id and auth.uid() in (requester, addressee);
end $$;

create or replace function public.my_friends()
returns table (friendship_id bigint, username text, display_name text, level integer, relation text)
language sql stable security definer set search_path = public as $$
  select f.id, p.username, p.display_name, p.level,
    case when f.status = 'accepted' then 'friend'
         when f.addressee = auth.uid() then 'incoming' else 'outgoing' end
  from public.friendships f
  join public.profiles p on p.id = case when f.requester = auth.uid() then f.addressee else f.requester end
  where auth.uid() in (f.requester, f.addressee)
  order by f.created_at desc
$$;

-- Best score per player in a game, for you and your accepted friends only.
create or replace function public.friends_leaderboard(p_game text)
returns table (username text, score integer)
language sql stable security definer set search_path = public as $$
  select p.username, max(s.score)::integer
  from public.scores s join public.profiles p on p.id = s.user_id
  where s.game = p_game and (
    s.user_id = auth.uid() or s.user_id in (
      select case when f.requester = auth.uid() then f.addressee else f.requester end
      from public.friendships f where f.status = 'accepted' and auth.uid() in (f.requester, f.addressee)))
  group by p.username
  order by max(s.score) desc
  limit 10
$$;

revoke execute on function public.send_friend_request(text), public.respond_friend(bigint, boolean),
  public.remove_friendship(bigint), public.my_friends(), public.friends_leaderboard(text) from public, anon;
grant execute on function public.send_friend_request(text), public.respond_friend(bigint, boolean),
  public.remove_friendship(bigint), public.my_friends(), public.friends_leaderboard(text) to authenticated;
