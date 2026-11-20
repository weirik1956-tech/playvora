PLAYVORA - how to run

1. Unzip this whole folder (right-click > Extract All). Do not open files from inside the zip.
2. Keep the folders exactly as they are: css/, js/ and games/ must sit next to index.html.
3. Double-click index.html to open the site in your browser.

If a page ever looks plain or its buttons do nothing, the css/ and js/ folders are not next to the page.

Supabase setup (run once each, in this order, in Supabase > SQL Editor):
  supabase-setup.sql, supabase-upgrade.sql, supabase-challenges.sql,
  supabase-players.sql, supabase-friends.sql, supabase-games.sql
  supabase-admin.sql, supabase-notifications.sql
(Run the last two after the others. Then make yourself admin with the line at the bottom of supabase-admin.sql.)

Email settings (Supabase > Authentication):
  - Sign In / Providers > Email > Confirm email: OFF (current choice, no custom SMTP yet).
  - To turn on email password reset later: set up custom SMTP (Authentication > Emails > SMTP Settings),
    turn Confirm email back on if you want it, then set passwordReset:true in js/config.js.

New in this version: run supabase-reviews.sql too (after supabase-admin.sql). It adds game ratings, reviews, play stats and reports.
Optional: put an email address in contactEmail inside js/config.js so it shows on the Terms and Privacy pages.
