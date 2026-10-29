# AGENTS.md

Notes for AI agents working on this repo. The README covers users; this covers setting it up for someone and
changing the code.

## Setting it up on someone's PC

1. Get the repo onto the PC in a short path (very long paths break native tools launched from Git Bash).
2. Run `powershell -ExecutionPolicy Bypass -File scripts\setup.ps1` **in a terminal the person can see and type
   into**. It refuses to run without one. Hand over whenever it waits; it says what for.
3. When it ends, every line from `scripts\check-setup.ps1` should be `[  OK]`. Otherwise fix what it lists and rerun
   setup (it skips what's done).

Rules:

- **Never see, type, print or store the keys.** Only the person pastes them, into the hidden prompt of
  `scripts\set-secrets.ps1` (called by setup). Check them by calling Discord/YouTube and printing derived facts
  only (e.g. the bot's username), never the values. `.env` stays git- and docker-ignored.
- **Never click or suggest "Reset Token"** when adding a PC: all PCs share one token.
- Don't accept license agreements, approve admin prompts, or restart/sign out the PC for the person.

What setup does: checks virtualization and winget; installs Git, WSL 2 (`wsl --install --no-distribution`, then a
restart that resumes setup through a `RunOnce` entry) and Docker Desktop via winget; turns off Docker's own
`AutoStart` (`%APPDATA%\Docker\settings-store.json`); waits for the engine; runs `set-secrets.ps1`,
`start-bot.ps1` (image `lnn-music-bot:latest`, container `lnn-music-bot`, restart `unless-stopped`, `.env` as
env-file, `.\data` → `/data`, `INSTANCE_NAME=$env:COMPUTERNAME`) and `install-autostart.ps1`; then `check-setup.ps1`.

**Autostart:** the scheduled task "LnnMusicBot - Docker autostart" runs `scripts\docker-autostart.ps1` at sign-in.
Docker's own `Run` registry entry is removed and its AutoStart must stay off, so Docker can't start before the
cleanup. The reason: after an unclean shutdown Docker renames `%LOCALAPPDATA%\Docker\run\sailor-ingest.sock` to
`.stale`, and if an old `.stale` exists its backend crashes ("The file cannot be accessed by the system"). Those
AF_UNIX socket files can't be deleted from Windows, only through WSL:
`wsl -d docker-desktop -e rm -f /mnt/host/c/Users/<user>/AppData/Local/Docker/run/<file>.stale`. The script does
this before and after starting Docker, logging to `autostart.log`.

## Build and test

There's no local `node_modules`; build and test in Docker:

```bash
docker build --target builder -t lnn-music-bot:test .
docker run --rm lnn-music-bot:test sh -c "yarn typecheck && yarn lint && yarn vitest run tests/"
```

Pass `tests/` explicitly, or vitest also runs test files inside `prod_node_modules/` and reports false failures.
Deploy with `scripts\start-bot.ps1`; it recreates the live container, so the bot is offline for a few seconds.
To regenerate `yarn.lock` after dependency changes, run `yarn install --ignore-scripts` in a `node:22` container on
copies of `package.json`/`yarn.lock`, then copy the lockfile back.

## Code map

TypeScript (ESM, Node 22), discord.js 14, inversify DI, Prisma + SQLite in `/data`, yt-dlp + ffmpeg, YouTube Data
API v3, vitest.

| Path | What |
|---|---|
| `src/index.ts`, `src/bot.ts`, `src/inversify.config.ts` | Startup, Discord client, DI wiring |
| `src/commands/` | One file per slash command |
| `src/services/get-songs.ts` | `/play` query → songs (search, video, playlist, Mix, SoundCloud, Spotify) |
| `src/services/youtube-api.ts`, `src/utils/yt-dlp.ts` | YouTube Data API calls; all yt-dlp calls |
| `src/services/add-query-to-queue.ts`, `src/services/player.ts` | Queueing + replies/reaction controls; playback |
| `src/services/failover.ts` | Multi-PC coordination (`decide()` holds the rules) |
| `scripts/` | Windows setup and ops (PowerShell 5.1) |

Changes vs upstream Muse (commit `ef00b33`):

1. **YouTube Mixes** (`list=RD…`), which the Data API can't see: `getYouTubeMix()` reads entries with yt-dlp
   `--flat-playlist`; `YoutubeAPI.getVideosAsPlaylist()` fetches details in batches of 50 in Mix order. Mixes then use
   the normal queue path.
2. **Failover**: with a `#bots-internal` channel, installs register in a roster message (order = priority) and the
   active one edits a heartbeat message every 20 s, timed with Discord's clock. Standbys poll over REST and never
   log in to the gateway. Takeover after 75 s of silence or a `stopped` status; a higher install takes back only
   when `PlayerManager.isBusy()` is false; stepping down is `process.exit(0)`, and Docker restarts it as a standby.
   Identity is `data/failover-instance.json`. No channel means plain single-instance behaviour. Keep all PCs on the
   same version.
3. Plain startup banner and welcome DM; upstream CI, release tooling and funding files removed.

Conventions: 2-space indent, single quotes, `xo` ESLint rules, `.js` extensions on ESM imports, services through DI.
New behaviour gets vitest tests that mock yt-dlp, Discord and the YouTube API (no network).

## Security baseline

- The bot only talks to Discord, Google/YouTube (Data API, search suggestions, media via yt-dlp) and, if configured,
  Spotify/SponsorBlock. Check new dependencies and network calls against that.
- Keep `CHECKPOINT_DISABLE=1` in `.env`: the bundled Prisma CLI runs at every start and otherwise pings
  `checkpoint.prisma.io`.
- Don't enable `YT_DLP_AUTO_UPDATE` (downloads code at runtime). Never use a personal Google account's cookies for
  yt-dlp; a throwaway account only, if ever needed.

## Gotchas

- Git Bash: use `MSYS_NO_PATHCONV=1` for docker commands with container paths, and `C:/...` host paths for `docker cp`.
- Signal handlers: ora/signal-exit re-raise SIGTERM after login. Use `process.on` with a guard flag, never
  `process.once`, or the process dies mid-cleanup (exit 143).
- Docker reads `.env` as an `--env-file`: LF line endings, no BOM, no quotes or inline comments (`.gitattributes`
  keeps LF; `set-secrets.ps1` writes it correctly).
