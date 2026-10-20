# 9router-go — Botkeep.cloud deploy branch

This branch contains **only** the Botkeep start script (~4 KB). The full 9router-go
source lives on `main`; this orphan branch exists because Botkeep's repo/ZIP import
limit is ~20 MB and the main branch's `.git` alone is ~33 MB.

## Deploy

1. Botkeep panel → new workload → profile **Go** → import repo `nareida/9router-go`,
   branch **`botkeep`**.
2. Start command: `bash botkeep-start.sh`
3. The script downloads the latest 9router-go release binary (~44 MB) from THIS fork's mirrored
   GitHub Releases at container start — nothing large is committed to this branch.

## First boot

The script prints a `BOOTSTRAP` dashboard password to the console log. Save it,
log in, change it. The JWT secret is auto-generated and persisted to `$HOME/data/.jwt-secret`.

## What the script does

- Reads `SERVER_PORT` (Botkeep's port), falls back to `PORT`, then `20130`.
- Downloads the 9router-go binary to `$HOME/app/9router-go` (outside the repo tree,
  so redeploys don't re-download).
- Points `DATA_DIR` to `$HOME/data` (outside the repo tree, so redeploys don't wipe the DB).
- Generates + persists a stable `JWT_SECRET`.
- Generates a random `INITIAL_PASSWORD` on first boot (printed once to stdout).
- Binds `0.0.0.0:$PORT` and execs the binary.
