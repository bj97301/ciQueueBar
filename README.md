# CIQueueBar

A macOS menu bar app that shows your GitHub Actions job queue, grouped by where the jobs run:

- **Mac**: self-hosted runners with a macOS label
- **Blacksmith**: `blacksmith-*` runners
- **GitHub**: GitHub-hosted `ubuntu-*`, `windows-*`, `macos-*`
- **Self-hosted**: other self-hosted runners
- **Other**: anything else

The menu bar shows counts like `Mac 3⏳1▶  BS 2▶` (queued ⏳, running ▶). Click a job in the menu to open it on GitHub.

## Install

```sh
./build-app.sh
cp -R build/CIQueueBar.app /Applications/
open -g /Applications/CIQueueBar.app
```

Auth comes from `gh auth token` (or a `GITHUB_TOKEN` env var).

## Config

Optional `~/.config/ciqueuebar/config.json`:

```json
{
  "repos": ["owner/repo", "org/other"],
  "recentDays": 2,
  "maxRepos": 25,
  "refreshSeconds": 45
}
```

Without `repos`, it scans your repos (owned, collaborator, org member) pushed within `recentDays`.

## Bartender

Bartender files new menu bar items under **Always Hide**. Move CIQueueBar to **Shown** in Bartender's Menu Bar Layout, or drag it out of the hidden section.
