# bandy

Checks your Bandcamp collection for new purchases, downloads them, and unpacks them to your music library. This leverages unofficial Bandcamp APIs, so these scripts may change or break at any time. Use at your own risk, no warranties implied, etc. etc.

## How it works

Each run executes a five-stage pipeline, moving discovered purchases through a state machine:

```
:seen → :ready (or :preorder) → :queued → :downloaded → :unpacked
```

1. **SyncCollection** — Fetches your Bandcamp collection summary and records any new purchases as `:seen`
2. **EnrichItems** — Fetches download tokens and redownload URLs for `:seen` items, advancing them to `:ready` (or `:preorder` if not yet released)
3. **QueueItems** — Resolves CDN download URLs for `:ready` items and marks them `:queued` (batch-limited by `QUEUE_LIMIT`)
4. **DownloadItems** — Downloads zip archives from CDN for `:queued` items; re-queues if the CDN URL has gone stale
5. **UnpackItems** — Extracts zip archives to `UNPACK_PATH`, organized as `artist/album/`

State is persisted in a [PStore](https://ruby-doc.org/3.4.1/stdlibs/pstore/PStore.html) database at `./store/collection_items.pstore`. Logs rotate monthly in `./logs/`.

## Setup

**Prerequisites:** Ruby 4.x, Bundler

```sh
bundle install
```

**Create a `.env` file** (copy the example below and fill in your values):

```sh
IDENT='<your-bandcamp-identity-cookie>'
FORMAT='mp3-320'
DOWNLOAD_PATH='./downloads'
UNPACK_PATH='./collection'
QUEUE_LIMIT='25'
CDN_FRESHNESS_THRESHOLD='300'
MAX_REQUEUE_ATTEMPTS='3'
DELETE_AFTER_UNPACK='true'
DEBUG='false'
```

### Getting your `IDENT` cookie

1. Log into [bandcamp.com](https://bandcamp.com) in your browser
2. Open DevTools → Application → Cookies → `https://bandcamp.com`
3. Copy the value of the `identity` cookie

## Running
`bandy`'s shebang includes the `--yjit` flag, which may throw a warning if your local Ruby wasn't compiled with Rust support.

```sh
./bandy.rb
```

To run on a schedule, add a cron entry:

```
0 * * * * ./path/to/bandy >> logs/cron.log 2>&1
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `IDENT` | *(required)* | Bandcamp `identity` cookie value |
| `FORMAT` | `mp3-320` | Download format (`mp3-320`, `flac`, `aac-hi`, etc.) |
| `DOWNLOAD_PATH` | `./downloads` | Where zip archives are saved |
| `UNPACK_PATH` | `./collection` | Where music is extracted |
| `QUEUE_LIMIT` | `25` | Max items queued per run |
| `CDN_FRESHNESS_THRESHOLD` | `300` | Seconds before a CDN URL is considered stale |
| `MAX_REQUEUE_ATTEMPTS` | `3` | Times to retry a stale CDN URL before marking `:failed` |
| `DELETE_AFTER_UNPACK` | `true` | Delete zip archives after successful extraction |
| `DEBUG` | `false` | Set to `true` to route logs to stdout instead of log files |

## Project structure

```
bandy.rb                  # entry point — runs the pipeline
api/
  baseapi.rb              # HTTParty base class for Bandcamp API calls
  collection_summary.rb   # fetches collection overview + fan ID
  collection_items.rb     # fetches paginated collection with download tokens
  hidden_items.rb         # fetches hidden/gift items
  pagedata.rb             # resolves redownload URLs to page data
scripts/
  sync_collection.rb      # stage 1: sync remote → local store
  enrich_items.rb         # stage 2: fetch download metadata
  queue_items.rb          # stage 3: resolve CDN URLs
  download_items.rb       # stage 4: download archives
  unpack_items.rb         # stage 5: extract archives
store/
  collection_items.pstore # persistent item state database (created on first run)
logs/                     # monthly rotating logs per stage
downloads/                # zip archives (default, transient; change path in `.env`)
collection/               # unpacked music library (default; change path in `.env`)
```
