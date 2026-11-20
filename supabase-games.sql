-- PLAYVORA new games: allow scores for Memory Cards, Minesweeper and Breakout.
-- Run once in Supabase: SQL Editor > New query > paste > Run. Safe to run again.
do $$
declare c text;
begin
  for c in select conname from pg_constraint
           where conrelid = 'public.scores'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%game%'
  loop
    execute format('alter table public.scores drop constraint %I', c);
  end loop;
  alter table public.scores add constraint scores_game_check
    check (game in ('tetris','space-shooter','snake','2048','memory','minesweeper','breakout'));
end $$;
