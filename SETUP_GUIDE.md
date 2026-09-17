# TAE Accounting System — Setup Guide

This is a static, framework-free web app (no build step) backed by
Supabase. It hosts four modules — `masters.html`, `billing.html`,
`daily-ledger.html`, `reports.html` — inside the `index.html` shell.

## 1. Supabase project

1. Create a new Supabase project.
2. Enable email+password auth (Authentication → Providers → Email).
3. Apply every file in `supabase/migrations/` **in filename order** (they
   are numbered `0001_...` through the latest). Either paste each one into
   the SQL Editor in order, or use the Supabase CLI:
   ```
   supabase db push
   ```
4. Get your project's URL and anon (publishable) key from
   Settings → API. The anon key is safe to embed in client code — it is
   not a secret, RLS is the real access-control boundary — but it is
   currently hardcoded near the top of each `.html` file's `<script>`
   block. If you point this app at a different Supabase project, update
   the `SUPABASE_URL` / `SUPABASE_ANON_KEY` constants in **every** HTML
   file (`index.html`, `masters.html`, `billing.html`, `daily-ledger.html`,
   `reports.html`) to match.

## 2. Creating the first admin user

New users are never self-service (§7) — an admin always creates the
Supabase Auth account first, then creates the matching profile row:

1. In the Supabase Dashboard: Authentication → Users → **Add user**,
   set an email + password.
2. Copy that user's UUID.
3. Sign in to the app with that email/password. Because no `app_users`
   row exists yet, you'll see "not set up" — this is expected.
4. Open `masters.html` → **Manage Users** → **+ New user**, paste the
   UUID, give it a username, check **Admin**, save.
5. Sign out and back in — you now have full access.

Every subsequent user follows the same two-step flow (create the Auth
account in the Dashboard, then create their `app_users` profile with
whatever permission checkboxes they need).

## 3. Hosting

Any static host works (GitHub Pages, Netlify, Vercel static, etc.) —
just serve the repository root. There is no server-side rendering and
no build step; deploying is literally "upload these files."

## 4. Daily Email Backup — GitHub Actions secrets

The nightly backup (`.github/workflows/daily-backup.yml`, 2am Pakistan
time, or run manually via the Actions tab → "Daily Backup" →
**Run workflow**) needs these repository secrets
(Settings → Secrets and variables → Actions → New repository secret):

| Secret | Value |
|---|---|
| `SUPABASE_URL` | same as the app's `SUPABASE_URL` |
| `SUPABASE_ANON_KEY` | same as the app's anon key |
| `BACKUP_EMAIL` | email of a **dedicated** admin account for backups (don't reuse your own daily-driver login — rotating your password would silently break the backup) |
| `BACKUP_PASSWORD` | that account's password |
| `GMAIL_USER` | the Gmail address the backup will be sent FROM |
| `GMAIL_APP_PASSWORD` | a 16-character Gmail **App Password** (Google Account → Security → 2-Step Verification must be ON first, then App Passwords) — never your real Gmail password |
| `BACKUP_TO_EMAIL` | where the backup should land — comma-separate multiple addresses so you don't depend on one mailbox |
| `BACKUP_PASSPHRASE` | *(optional)* encrypts the JSON backup with this passphrase instead of just gzipping it. **If you lose this passphrase, that backup file is permanently unrecoverable — nobody can open it, not even us.** Leave unset if unsure. |
| `SUPABASE_DB_URL` | *(optional)* enables an extra schema-only `pg_dump` attached to the email. This is a full database connection string — far more powerful than the anon key. Get it from Settings → Database → Connection string. Never commit it anywhere. |

### What each backup file is

- `TAE-Backup-<date>.xlsx` — every table as a browsable spreadsheet, one
  sheet per table.
- `TAE-Restore-<date>.json.gz` — the same data as gzipped JSON, restorable
  via `masters.html` → Backup/Restore. (Or `TAE-Restore-<date>.json.enc`
  instead, AES-256-GCM encrypted, if `BACKUP_PASSPHRASE` is set.)
- `TAE-Schema-<date>.sql` — schema-only SQL dump (table/trigger/function
  definitions, no data), only attached if `SUPABASE_DB_URL` is set.

The in-app **Backup now** button (Masters → Backup/Restore) produces a
plain, unencrypted `.json` file the same way, for a quick manual
snapshot — it only accepts plain `.json`/`.json.gz` on restore, not the
encrypted `.json.enc` variant (decrypt that locally first if you ever
need to restore from an encrypted nightly backup).

## 5. Disaster recovery — from an empty Supabase project

1. Create a brand-new Supabase project.
2. Apply every migration in `supabase/migrations/`, in order (step 1
   above).
3. Update `SUPABASE_URL`/`SUPABASE_ANON_KEY` in every HTML file if this
   is a different project than before.
4. Re-create your admin user (step 2 above) — a fresh project has no
   `app_users` rows at all.
5. Sign in, go to Masters → Backup/Restore → **Restore**, pick your most
   recent `TAE-Restore-*.json`/`.json.gz` file.
6. Verify: spot-check a few parties/items/vouchers, then go to Reports →
   Trial Balance and run the reconciliation check — it should report no
   discrepancies.
7. `audit_log` is exported in every backup but is **never** restored —
   restoring a table means the app writing to it directly, and
   `audit_log` is meant to be an append-only, trigger-written record of
   what changed and when; making it just another restorable table would
   undermine that.

## 6. Known scope notes (read before reporting something as "broken")

- The in-app Restore tool performs a **merge** (upsert by id), never a
  full replace — it will not delete rows that exist in the database but
  aren't in the file you're restoring. This is deliberately the safer
  default.
- `.json.enc` (encrypted) backups can only be restored after decrypting
  them yourself (e.g. with a small local script using the same
  AES-256-GCM format `backup-job/backup.js` writes) — the in-app tool
  doesn't do this to avoid shipping a passphrase-entry flow that could
  be misused.
- Stock Transfers deliberately do **not** change any item's stock
  quantity or average cost (§17) — they only feed the on-demand
  per-warehouse breakdown. This is intentional, not a bug: stock is
  tracked as one global number per item, not per warehouse.
- There is no hard block on selling more than what's in stock (§9/§12)
  — this is intentional, matching how many trading businesses actually
  operate (selling ahead of a physical count).
