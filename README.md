# bd_carradio

Vehicle radio for FiveM that plays **YouTube** audio with real **3D positional sound** - distance falloff, HRTF panning, and cabin muffling. No YouTube API key, no embedded players, no iframes.

Audio is resolved on the server with **yt-dlp**, cached to disk, and streamed to clients as plain media files through a Web Audio graph.

![bd_carradio preview](web/dist/preview.png)

## Features

- **Search** YouTube by name or paste a link (watch, Shorts, `youtu.be`, Music)
- **Queue** up to 25 tracks per vehicle with play, skip, seek, and volume
- **Playlists** — saved playlists (`list=PL...`) load in order; first track plays, the rest queue behind it
- **True 3D audio** — outside listeners hear direction and distance; open doors and broken windows affect muffling
- **Occupants** hear the stereo directly (no ear-flicker from an HRTF panner on top of them)
- **Disk cache** — repeat plays are instant for the whole server; LRU eviction with a configurable size cap
- **Blocklist** — ban specific video ids or words in titles and channel names
- **Optional HTTPS streaming** — serve cached audio from your own reverse proxy instead of the game connection
- **Passenger control** — configurable; driver-only mode supported
- **View-only mode** — passengers without control still hear nearby radios

## Requirements

- FiveM artifact with **Lua 5.4** and **Node.js 22** (bundled runtime via `fxmanifest`)
- Server able to run **yt-dlp** (downloaded automatically on first start into `data/`)
- Outbound HTTPS from the game server (YouTube + GitHub for yt-dlp updates)

## Installation

1. Place the resource in your server `resources` folder as `bd_carradio` (or any name you prefer).
2. Add to `server.cfg`:

```cfg
add_unsafe_child_process_permission bd_carradio

ensure bd_carradio
```

The permission line is required because the resource spawns **yt-dlp** as a child process. It is scoped to this resource only.

3. Adjust `config.lua` if needed and restart the server.

On first start the resource downloads **yt-dlp** into `data/` and prints `[binary-radio] ready` when it can resolve tracks. That one-time download can take about a minute; searches before it finishes return *yt-dlp is still installing*.

> If your folder name is not `bd_carradio`, use that name in both the permission line and `ensure`.

## Usage

| Input | Action |
|--------|--------|
| `/carradio` or default key **G** | Open the radio while in a vehicle |
| YouTube link or video id | Play immediately |
| `list=PL...` playlist link | Play first track, queue the rest in order |
| Anything else | Search YouTube, pick a result |

**Live streams** are rejected (no fixed duration). Tracks longer than `config.maxSongMinutes` are refused.

### Playlists vs mixes

| Link type | Example | Behaviour |
|-----------|---------|-------------|
| **Saved playlist** | `list=PL...` | Exact track list and order |
| **YouTube Mix / Radio** | `list=RD...` | Algorithmic mix — **not** the same as your YouTube app unless you add cookies (see below) |
| **Watch Later / Liked** | `list=WL`, `list=LM...` | Requires your YouTube cookies on the server |

## Configuration

Main options in `config.lua`:

| Option | Description |
|--------|-------------|
| `command` | Chat command to open the panel (default: `carradio`) |
| `keybind` | Default keybind (default: `G`; players can rebind in GTA settings) |
| `permission` | ACE permission to control the radio; empty = everyone |
| `passengersCanControl` | Allow non-drivers to change music (default: `true`) |
| `hearingDistance` | How far away music can be heard, in metres (default: `24`) |
| `outsideVolume` | Outside volume relative to inside (default: `0.7`) |
| `maxSongMinutes` | Refuse tracks longer than this (default: `15`) |
| `queueSize` | Max queued tracks per vehicle (default: `25`) |
| `searchResults` | How many search results to show (default: `24`) |
| `maxPlaylistTracks` | Max tracks loaded from one playlist (default: `50`) |
| `blockedSongs` | List of YouTube video ids that are never allowed |
| `blockedWords` | Words banned from track titles and channel names |
| `audioUrl` | Optional HTTPS base URL for streaming cached audio (see below) |

Advanced tuning lives under `config.advanced` (cache size, transfer rate, yt-dlp timeouts, 3D audio curves, rate limits). Defaults are sensible; most servers never need to touch them.

## Optional: HTTPS audio streaming

By default, audio is sent over the **game connection** (base64 via latent events). That works with zero extra setup but every listener waits for the full file before playback starts.

Set `config.audioUrl` to an **https** URL that reaches this resource’s HTTP handler. Clients then pull `/stream/<videoId>` directly from cache. Playback starts sooner and the game connection carries no audio data.

```lua
config.audioUrl = 'https://radio.yourserver.com/bd_carradio'
```

The value must be **https** — NUI will not play plain HTTP media. At boot the resource checks `/health` and logs whether streaming is live.

Example nginx location (proxy to your FXServer HTTP port):

```nginx
location /bd_carradio/ {
    proxy_pass http://127.0.0.1:30120/bd_carradio/;
    proxy_set_header Host $host;
    proxy_http_version 1.1;
}
```

Do **not** add extra CORS headers in nginx; the resource already sends `Access-Control-Allow-Origin: *`.

## Optional: server.cfg convars

Set these in `server.cfg` (not in `config.lua`) if YouTube blocks or throttles your host IP:

```cfg
set binary_radio:cookies "/path/to/cookies.txt"
set binary_radio:proxy "http://user:pass@host:port"
```

**Cookies** help with age-restricted videos, personalized YouTube mixes (`list=RD...`), and library lists. Export a Netscape-format cookies file from a browser logged into YouTube.

**Proxy** is the heavier option for datacenter IPs that get bot-checked.

## Keeping yt-dlp current

YouTube breaks extraction periodically. The resource auto-updates its bundled **yt-dlp** every `config.advanced.autoUpdateHours` (default: 12). Set to `0` to manage updates yourself.

If a `yt-dlp` binary is already on the system **PATH**, that copy is used instead and is never auto-updated.

## Project structure

```
bd_carradio/
├── client/
│   ├── emitters.lua      # 3D audio emitters, cabin acoustics, distance culling
│   ├── main.lua          # Panel open/close, keybind, state sync
│   ├── nui.lua           # NUI callbacks (search, queue, playback)
│   └── vehicle.lua       # Door/window state for muffling
├── server/
│   ├── main.lua          # Radio state, queue, HTTP /stream handler
│   └── resolver.js       # yt-dlp search, resolve, download, cache
├── shared/
│   └── callback.lua      # Lightweight client ↔ server RPC
├── web/
│   └── dist/             # Pre-built NUI (shipped with the resource)
├── config.lua
└── fxmanifest.lua
```

Cached audio and the yt-dlp binary live under `data/` at runtime (`data/cache`, `data/yt-dlp`). Both are gitignored.

---

## Credits

- **Authors:** noah & eugene

## Support

For issues or suggestions, open a GitHub issue or reach out on Discord.

**Store:** [bd-shop.tebex.io](https://bd-shop.tebex.io/)  
**Discord:** [discord.gg/fvCfx8fX2Z](https://discord.gg/fvCfx8fX2Z)
