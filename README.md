# bd_carradio

Vehicle radio for FiveM that plays **YouTube** audio with real **3D positional sound** - distance falloff, HRTF panning, and cabin muffling. Uses the **YouTube Data API** for search and metadata, and YouTube's streaming endpoints (resolved server-side) for Web Audio playback.

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
- An **HTTPS reverse proxy** pointing at this resource's HTTP handler (optional, for 3D web audio - see [HTTPS streaming](#https-streaming))

## Installation

1. Place the resource in your server `resources` folder as `bd_carradio` (or any name you prefer).
2. Follow [YouTube API key setup](#youtube-api-key-setup) and paste your key into `shared/config.lua`.
3. Optionally set up [HTTPS streaming](#https-streaming) for 3D web audio.
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

## HTTPS streaming

Browsers inside FiveM's NUI require **HTTPS** audio URLs with CORS headers for Web Audio 3D panning. The resource exposes a built-in HTTP handler at `/stream/{videoId}` that proxies YouTube audio with the correct headers.

Point a reverse proxy (nginx, Caddy, etc.) at your FXServer HTTP port and set `config.audioUrl` to that public HTTPS URL:

```lua
audioUrl = 'https://radio.yourserver.com',
```

Without `audioUrl`, playback uses the YouTube iframe player instead (instant start, simulated muffling outside the car).

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
