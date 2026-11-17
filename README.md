# CIQueueBar

A macOS menu bar app that shows your GitHub Actions job queue, grouped by where the jobs run:

- **Mac**: self-hosted macOS runners
- **Linux**: self-hosted Linux runners
- **Blacksmith**: `blacksmith-*` runners
- **GitHub**: GitHub-hosted `ubuntu-*`, `windows-*`, `macos-*`
- **Other**: anything else

Jobs are matched to your registered self-hosted runners by label, so custom labels like `electro-local-mac` land in the right group.

![Panel](docs/panel.png)

The menu bar shows counts like `Mac 3⏳1▶  BS 2▶` (queued ⏳, running ▶). Click it for a panel with every queued and running job (repo, workflow and run number, branch, who triggered it, commit title, wait or run time, current step) plus your self-hosted runners and whether each is busy, idle or offline. Click a job to open it on GitHub.

`CIQueueBar --snapshot out.png` renders that panel with live data to a PNG.

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
