# bd_carradio

Vehicle radio for FiveM that plays **YouTube** audio with real **3D positional sound** - distance falloff, HRTF panning, and cabin muffling. Uses the **YouTube Data API** for search and metadata, and YouTube's streaming endpoints (resolved server-side) for Web Audio playback.

![bd_carradio preview](web/dist/preview.png)

## Features

- **Search** YouTube by name or paste a link (watch, Shorts, `youtu.be`, Music)
- **Queue** up to 25 tracks per vehicle with play, skip, seek, and volume
- **Playlists** - saved playlists (`list=PL...`) load in order; first track plays, the rest queue behind it
- **True 3D audio** - outside listeners hear direction and distance; open doors and broken windows affect muffling
- **Occupants** hear the stereo directly (no ear-flicker from an HRTF panner on top of them)
- **Blocklist** - ban specific video ids or words in titles and channel names
- **HTTPS streaming** - serve proxied audio from your own reverse proxy for 3D panning (recommended)
- **Passenger control** - configurable; driver-only mode supported
- **View-only mode** - passengers without control still hear nearby radios

## Requirements

- FiveM artifact with **Lua 5.4**
- A **YouTube Data API v3** key (`config.youtubeApiKey`) - see [YouTube API key setup](#youtube-api-key-setup)
- Outbound HTTPS from the game server (`googleapis.com`, `youtube.com`, `googlevideo.com`)
- An **HTTPS reverse proxy** pointing at this resource's HTTP handler (optional, for 3D web audio - see [HTTPS streaming (`audioUrl`)](#https-streaming-audiourl))

## Installation

1. Place the resource in your server `resources` folder as `bd_carradio` (or any name you prefer).
2. Follow [YouTube API key setup](#youtube-api-key-setup) and paste your key into `shared/config.lua`.
3. Optionally set up [HTTPS streaming (`audioUrl`)](#https-streaming-audiourl) for 3D web audio.
4. Add to `server.cfg`:

```cfg
ensure bd_carradio
```

5. Restart the server. You should see `[bd_carradio] loaded v1.0.1` in the console.

## YouTube API key setup

You need a **YouTube Data API v3** key from Google Cloud. This is free for normal server use (Google gives 10,000 quota units per day by default).

### 1. Create a Google Cloud project

1. Open [Google Cloud Console](https://console.cloud.google.com/).
2. Sign in with a Google account.
3. Click the project dropdown at the top (next to "Google Cloud").
4. Click **New project**.
5. Enter a name (for example `fivem-carradio`) and click **Create**.
6. Make sure that project is selected in the top bar.

### 2. Enable the YouTube Data API v3

1. Open the [YouTube Data API v3 library page](https://console.cloud.google.com/apis/library/youtube.googleapis.com).
2. Confirm the correct project is selected at the top.
3. Click **Enable**.
4. Wait until it finishes enabling.

### 3. Create an API key

1. Open [APIs & Services > Credentials](https://console.cloud.google.com/apis/credentials).
2. Click **+ Create credentials** at the top.
3. Choose **API key**.
4. Copy the key that appears (it starts with `AIza...`).

### 4. Restrict the key (recommended)

1. On the credentials page, click your new API key to edit it.
2. Under **API restrictions**, choose **Restrict key**.
3. Select **YouTube Data API v3** from the list.
4. Click **Save**.

This stops the key from being used with other Google APIs if it ever leaks.

### 5. Add the key to bd_carradio

1. Open `shared/config.lua` in this resource.
2. Set your key:

```lua
youtubeApiKey = 'AIzaSy...your_key_here...',
```

3. Save the file and restart the resource (or the whole server).

### 6. Test it

1. Start the server and check the console for `[bd_carradio] loaded v...`.
2. Join the server, get in a vehicle, and open the radio (`/carradio` or **G** by default).
3. Search for a song or paste a YouTube link.

If search or playback fails, double-check that **YouTube Data API v3** is enabled on the same project as the key.

### Common issues

| Problem | Fix |
|---------|-----|
| `missing youtube api key` in console | `youtubeApiKey` is empty in `shared/config.lua` |
| Search returns nothing / API errors | Enable **YouTube Data API v3** on your Google Cloud project |
| `API key not valid` | Copy the full key again; make sure there are no extra spaces |
| Quota exceeded | Default limit is 10,000 units/day; each search uses ~100 units |
| Key works in browser but not server | Remove HTTP referrer restrictions, or add your server IP if you use IP restrictions |

## HTTPS streaming (`audioUrl`)

FiveM's in-game browser only allows **HTTPS** audio URLs for Web Audio 3D panning. bd_carradio ships a built-in HTTP handler on your FXServer that proxies YouTube audio with the correct CORS and range-request headers.

When `audioUrl` is set, clients load audio from:

```text
https://your-domain.com/stream/{videoId}
```

That URL must be a **public HTTPS reverse proxy** pointing at your game server's HTTP port. Without it, playback falls back to the YouTube iframe player (works out of the box, but 3D panning and cabin muffling are simulated instead of real).

### What the resource exposes

| Path | Purpose |
|------|---------|
| `/health` | Health check - returns a token so the resource can verify your proxy on startup |
| `/stream/{videoId}` | Proxied YouTube audio (11-character video id) |

Both endpoints are served by FXServer itself. You do **not** host separate audio files - you only proxy traffic from your domain to the game server.

### Before you start

1. **FXServer port** - note the TCP port in `server.cfg` (default `30120`). The examples below use `30120`; change it if yours differs.
2. **Domain** - a subdomain is fine, e.g. `radio.yourserver.com`.
3. **TLS certificate** - required for HTTPS. Use [Let's Encrypt](https://letsencrypt.org/) (free) via Caddy or Certbot on Linux.
4. **Firewall** - players only need port **443** on your proxy. The game port (`30120`) can stay local-only; the proxy talks to `127.0.0.1:30120` on the same machine.

### Linux setup (nginx)

Install nginx and Certbot on your FXServer host (Debian/Ubuntu example):

```bash
sudo apt update
sudo apt install nginx certbot python3-certbot-nginx
```

Create `/etc/nginx/sites-available/bd-carradio`:

```nginx
server {
    listen 80;
    server_name radio.yourserver.com;
}

server {
    listen 443 ssl http2;
    server_name radio.yourserver.com;

    # certbot will fill these in, or set paths manually
    ssl_certificate     /etc/letsencrypt/live/radio.yourserver.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/radio.yourserver.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:30120;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # required for seek / scrubbing in the radio UI
        proxy_set_header Range $http_range;
        proxy_pass_request_headers on;
        proxy_buffering off;
    }
}
```

Enable the site and get a certificate:

```bash
sudo ln -s /etc/nginx/sites-available/bd-carradio /etc/nginx/sites-enabled/
sudo certbot --nginx -d radio.yourserver.com
sudo nginx -t && sudo systemctl reload nginx
```

### Linux setup (Caddy)

Caddy is simpler if you prefer automatic HTTPS with almost no config. Install [Caddy](https://caddyserver.com/docs/install), then create `/etc/caddy/Caddyfile`:

```caddy
radio.yourserver.com {
    reverse_proxy 127.0.0.1:30120
}
```

Start or reload Caddy:

```bash
sudo systemctl enable --now caddy
sudo systemctl reload caddy
```

Caddy obtains and renews the TLS certificate automatically.

### Windows setup (Caddy)

Caddy is the easiest option on Windows because it handles HTTPS certificates for you.

1. Download Caddy for Windows from [caddyserver.com/download](https://caddyserver.com/download).
2. Create a folder, e.g. `C:\caddy`, and place `caddy.exe` there.
3. Create `C:\caddy\Caddyfile`:

```caddy
radio.yourserver.com {
    reverse_proxy 127.0.0.1:30120
}
```

4. Open **Windows Firewall** and allow inbound **TCP 443** (and **80** for the initial certificate challenge).
5. Point your DNS A record for `radio.yourserver.com` at this machine's public IP.
6. Run Caddy from an elevated prompt (or install as a service):

```powershell
cd C:\caddy
.\caddy.exe run --config Caddyfile
```

To run in the background as a Windows service, use [NSSM](https://nssm.cc/) or Caddy's built-in `caddy start` after `caddy install`.

### Windows setup (nginx)

If you already use nginx on Windows:

1. Download nginx from [nginx.org](https://nginx.org/en/download.html) and extract it, e.g. to `C:\nginx`.
2. Add a `server` block to `conf\nginx.conf` (same as the [Linux nginx example](#linux-setup-nginx) above - proxy to `127.0.0.1:30120`).
3. Obtain a certificate with [win-acme](https://www.win-acme.com/) or copy certs from another tool into paths nginx can read.
4. Start nginx:

```powershell
cd C:\nginx
.\nginx.exe
```

Reload after config changes: `.\nginx.exe -s reload`

### Configure bd_carradio

Set the **public HTTPS base URL** (no trailing slash, no `/stream` path) in `shared/config.lua`:

```lua
audioUrl = 'https://radio.yourserver.com',
```

Restart the resource or server. On startup you should see:

```text
[bd_carradio] stream proxy connected at https://radio.yourserver.com
```

If the proxy is wrong or unreachable:

```text
[bd_carradio] stream proxy failed for https://radio.yourserver.com (404)
```

### Verify it works

1. **Health check** - from any machine with curl:

```bash
curl https://radio.yourserver.com/health
```

You should get a short token string (not HTML, not 404).

2. **In-game** - open the car radio, play a track. With `audioUrl` set, audio uses Web Audio 3D panning; you should hear direction and distance outside the vehicle.

3. **Leave `audioUrl` empty** if you cannot set up HTTPS yet - the YouTube iframe fallback still works, just without full 3D audio.

### `audioUrl` troubleshooting

| Problem | Fix |
|---------|-----|
| `stream proxy failed` on startup | DNS not pointing at the server, proxy not running, or wrong port in `proxy_pass` |
| `audiourl must use https` | Use `https://` in config, not `http://` |
| Health returns 404 or nginx default page | Proxy is not forwarding to FXServer, or FXServer is on a different port |
| Health works but no audio in-game | Check server console for stream resolve errors; confirm outbound HTTPS to `youtube.com` / `googlevideo.com` |
| Seeking / progress bar broken | Ensure nginx passes the `Range` header (see config above) |
| Certificate errors in NUI | Use a valid public CA cert (Let's Encrypt). Self-signed certs will not work in FiveM's browser |
| Proxy on a different machine | Point `proxy_pass` / `reverse_proxy` at the FXServer's **LAN IP** and port instead of `127.0.0.1` |

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
| **YouTube Mix / Radio** | `list=RD...` | Algorithmic mix - may not match what you see in the YouTube app |
| **Watch Later / Liked** | `list=WL`, `list=LM...` | Not supported (requires OAuth) |

## Configuration

Main options in `shared/config.lua`:

| Option | Description |
|--------|-------------|
| `youtubeApiKey` | YouTube Data API v3 key |
| `audioUrl` | Public HTTPS URL proxying this resource's `/stream` endpoint |
| `command` | Chat command to open the panel (default: `carradio`) |
| `keybind` | Default keybind (default: `G`) |
| `permission` | ACE permission to control the radio; empty = everyone |
| `passengersCanControl` | Allow non-drivers to change music (default: `true`) |
| `hearingDistance` | How far away music can be heard, in metres (default: `24`) |
| `outsideVolume` | Outside volume relative to inside (default: `0.7`) |
| `maxSongMinutes` | Refuse tracks longer than this (default: `15`) |
| `queueSize` | Max queued tracks per vehicle (default: `25`) |
| `searchResults` | How many search results to show (default: `24`) |
| `maxPlaylistTracks` | Max tracks loaded from a playlist (default: `50`) |
| `blockedSongs` | List of video ids to block |
| `blockedWords` | Words in titles/channels to block |

## How 3D audio works

When `audioUrl` is set, the server resolves a direct audio stream URL and proxies it. The NUI loads that audio into an `HTMLAudioElement` connected to a Web Audio graph with HRTF panning, lowpass filtering, and cabin muffling.

Without `audioUrl`, the YouTube iframe player handles playback. Volume and muffling are simulated, but true 3D panning is limited.

## API quota

Each search costs ~100 quota units, each video lookup costs ~1 unit. The default daily quota is 10,000 units.

## Building the UI

```bash
cd web
npm install
npm run build
```
