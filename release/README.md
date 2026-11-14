# Releases

bandy ships as one tarball per release: Ruby, the gems, and bandy, built in CI for the jukebox (aarch64, Debian 13). The jukebox never compiles anything; it downloads a release, checks it, tests it, and switches to it.

- `build-ruby.sh` -- builds a relocatable Ruby (CI's `ruby` job)
- `probe-ruby.sh` -- proves that Ruby runs from somewhere else (CI's `ruby-probe` job)
- `package.sh` -- Ruby + vendored gems + bandy into one tarball (CI's `package` job)
- `deploy.sh` -- puts a published release on the jukebox (by hand, on the box)

## The layout on the jukebox

```
~/bandy/
  .env store/ logs/ downloads/ collection/   bandy's state; deploy.sh never touches it
  releases/<tag>/                            at most two: current, and the one before
  current -> releases/<tag>
  deploy.sh                                  copied from this repo
```

`deploy.sh` isn't in the tarball, so it gets copied over once, and again whenever it changes:

```sh
scp release/deploy.sh jukebox.local:bandy/deploy.sh
```

## Deploy

```sh
cd ~/bandy && bash deploy.sh v2026.11.14
```

In order, it:

1. downloads the tarball and its `.sha256` from the GitHub release with `curl`, into `~/tmp/` (the SD card; `/tmp` is RAM)
2. checks the sha256
3. extracts it to a hidden staging dir in `releases/`
4. runs bandy's suite from the release, with the release's own Ruby, niced so playback wins (about 10s on the Pi)
5. renames it to `releases/<tag>` and flips `current` to it in one rename

Then it prunes `releases/` down to two, the new current and the one before, and removes its temp files. Deploying the tag that's already current does nothing. Deploying a kept tag that isn't current downloads it fresh and replaces the old copy.

## Roll back

```sh
cd ~/bandy && bash deploy.sh --rollback
```

Switches `current` to the other kept release, after its suite passes on the box. Running it again flips back.

## What it refuses, and why

Anything that fails before the switch leaves `current` where it was and prints `FAILED at step: <step>`.

- **A sha256 that doesn't match**, or a `.sha256` that isn't one line naming the tarball. It catches a corrupted download. It doesn't catch a compromised GitHub account; GitHub is the trust root.
- **A release whose suite fails**, or crashes without minitest's summary line. The box tests what it's about to run, because CI's arm cores aren't the Pi's Cortex-A53. A gem built for newer cores passes CI and dies on the box.
- **Running while bandy runs.** Any `ruby` process with `bandy.rb` in its arguments counts. The suite would compete with a real run, and pruning could pull a release out from under it.
- **Two deploys at once** (a lock on `releases/.lock`).
- **A `current` that isn't a symlink**, and tags that aren't `v` + digits, dots, letters, and dashes.

`releases/<tag>` only ever holds a release that passed its suite on this box, so a rollback never lands on a half-extracted or failing one.

## Cron

bandy runs from `~/bandy`, so its state keeps its paths, and from `current`, so a deploy or rollback is all it takes to change what runs:

```
cd ~/bandy && current/ruby/bin/ruby current/bandy.rb >> logs/cron.log 2>&1
```

Keep the schedule the crontab already has. `bandy.rb` finds the Gemfile beside it, so a stale `~/bandy/Gemfile` from the rsync days doesn't get in the way.

## Testing deploy.sh

CI's `deploy-test` job runs it against a real published release in a container shaped like the jukebox (runtime libraries, `curl`, no compiler), then against doctored copies: one byte changed, and one test made to fail. Those come from `file://` through `BANDY_DEPLOY_BASE_URL`. **That variable is for tests only**; never set it on the jukebox.
