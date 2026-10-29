# LnnMusicBot

Self-hosted Discord music bot: queue YouTube songs, playlists and Mixes with slash commands and play them in a voice
channel. A fork of [Muse](https://github.com/museofficial/muse) with YouTube Mix support, failover across several
PCs, and a one-command Windows setup that starts the bot automatically at sign-in.

## Setup (Windows 10/11)

You need:

- A **Discord bot token** and a **YouTube Data API v3 key** (see [Keys](#keys)).
- A **home internet connection**. YouTube blocks cloud/datacenter and most VPN IPs ("Sign in to confirm you're not a bot").

Download or clone this repo to a short path (e.g. `C:\repos\lnnmusicbot`), then in a PowerShell window you can type into:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
```

It installs Git, WSL 2 and Docker Desktop if missing, asks for the two keys (hidden input), builds and starts the
bot in Docker, and registers a sign-in task so it starts automatically. You only approve Windows admin prompts,
restart if asked (setup continues by itself afterwards), and accept Docker's license on its first start. It's safe
to run again at any time.

| Task | Command (from the repo folder) |
|---|---|
| Check everything (no secrets printed) | `powershell -ExecutionPolicy Bypass -File scripts\check-setup.ps1` |
| Rebuild/restart, e.g. after `git pull`, or when YouTube playback breaks (gets the newest yt-dlp) | `powershell -ExecutionPolicy Bypass -File scripts\start-bot.ps1` |
| Change the keys | `scripts\set-secrets.ps1`, then `scripts\start-bot.ps1` |
| Logs / stop / start | `docker logs -f lnn-music-bot` / `docker stop lnn-music-bot` / `docker start lnn-music-bot` |

## Keys

Both live only in `.env` in the repo folder, which is ignored by git and Docker.

- **Joining an existing bot:** ask its owner for both values over a private channel. **Never click "Reset Token"**:
  it logs out every PC running the bot.
- **Discord bot (new):** [Developer Portal](https://discord.com/developers/applications) → New Application → **Bot** →
  **Reset Token** → copy. Recommended settings: Bot → *Public Bot* off; all *Privileged Gateway Intents* off (not
  needed). Installation → *Install Link* None, *Guild Install* only. Invite it with the URL it prints in
  `docker logs lnn-music-bot`.
- **YouTube key:** [Google Cloud Console](https://console.cloud.google.com) → new project → enable **YouTube Data API v3** →
  Credentials → **API key**, restricted to that API. Free quota ≈ 100 searches a day; pasted links cost almost nothing.

## Using it in Discord

| Command | What it does |
|---|---|
| `/play query:` | Search, video link, playlist link or Mix link; adds to the queue. Options: `immediate`, `skip`, `shuffle`, `split` |
| `/queue`, `/next`, `/skip`, `/unskip` | Show and move through the queue |
| `/remove`, `/move`, `/shuffle`, `/clear` | Edit the queue |
| `/pause`, `/resume`, `/stop`, `/disconnect`, `/seek`, `/volume`, `/loop`, `/loop-queue` | Playback |
| `/favorites create name: query:` / `/favorites use name:` | Save a link under a name and queue it later |
| `/config set-playlist-limit limit:` | Songs taken from a playlist or Mix (default 50) |

The reply that starts playback gets reaction controls: ⏮️ ⏪ ⏯️ ⏩ ⏭️ ⏹️ 🔀. Playlists must be public or unlisted.

## Several PCs (failover)

Several PCs can run the bot with the same keys. One is in charge; the others are backups that take over if it goes
offline. Names (computer names) and priorities (the order PCs first started) are automatic.

1. Create a private text channel named **`bots-internal`** and give the bot *View Channel*, *Send Messages* and
   *Read Message History* there. The bot keeps two messages in it (install list and status). Don't edit them.
2. Run setup on each PC.

- Backups never log in to Discord, so there are no double replies.
- A backup takes over 75 s after the active PC goes silent, or within about 30 s of a clean stop. Queues aren't
  carried over; settings and favorites are per PC.
- A returning higher-priority PC takes back control only when nothing is playing.
- **Without the channel every PC runs on its own and they clash.** Never run two PCs without it.
- To reset the order: stop all PCs, delete the bot's two messages, start them in the order you want.

## Troubleshooting

| Problem | Fix |
|---|---|
| Docker error window at startup ("Quit / Reset to factory defaults") | Click **Quit**, never reset. Leftover socket files crash Docker's startup; the sign-in task clears them. Run `scripts\docker-autostart.ps1` or sign out and in. |
| `Sign in to confirm you're not a bot` | Not a home connection (VPN/cloud). Turn the VPN off; rerun `start-bot.ps1`. |
| `Playlist could not be found.` | The playlist is private. Make it public or unlisted. |
| Bot answers twice / hops voice channels | Two PCs are active: `#bots-internal` is missing or unreadable for one of them (its log says `Failover off`). |
| Bot offline after reboot | Run `check-setup.ps1`; see `autostart.log` in the repo folder. |

## License

MIT. Based on Muse, copyright (c) 2020 Max Isom; see [LICENSE](LICENSE).
