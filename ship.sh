#!/bin/bash
# One command to ship StreakFC: database updates, then git push, then Vercel.
set -e
cd "$(dirname "$0")"
if [ ! -s ~/.streakfc-db ]; then
  echo "First time setup. Supabase > Connect > Session pooler > copy the URI (put your DB password in it)."
  read -r -s -p "Paste connection string: " DBURL; echo
  printf '%s' "$DBURL" > ~/.streakfc-db && chmod 600 ~/.streakfc-db
fi
[ -d ~/.streakfc-tools/node_modules/pg ] || npm i --prefix ~/.streakfc-tools pg@8 --silent --no-audit --no-fund
for f in .git/*.lock; do [ -e "$f" ] && mv "$f" ".git/stale-$(basename "$f")-$(date +%s)"; done
node scripts/db.mjs
git push
npx vercel --prod
echo "Shipped."
