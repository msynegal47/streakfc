#!/bin/bash
# One command to ship StreakFC: database updates, then git push, then Vercel.
set -e
cd "$(dirname "$0")"
if [ -s ~/.streakfc-db ]; then
  [ -d ~/.streakfc-tools/node_modules/pg ] || npm i --prefix ~/.streakfc-tools pg@8 --silent --no-audit --no-fund
  RUN_DB=1
else
  echo "Database: skipped (Claude applies database updates in Supabase)"
fi
for f in .git/*.lock; do [ -e "$f" ] && mv "$f" ".git/stale-$(basename "$f")-$(date +%s)"; done
[ -n "$RUN_DB" ] && node scripts/db.mjs
git push
npx vercel --prod
echo "Shipped."
