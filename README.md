# Repository Sync Action

> Sync a source git repository to a target repository. Skips if already in sync, clones + pushes if behind. Handles large repos (>2GB) with automatic batch push fallback.

[![Sync](https://github.com/zhongdaiqi/repository-sync-action/actions/workflows/sync.yml/badge.svg)](https://github.com/zhongdaiqi/repository-sync-action/actions/workflows/sync.yml)

## Features

- **Smart skip**: Compares HEAD SHAs first, skips push if already in sync
- **Large repo support**: Falls back to batch push (500 commits/batch) if mirror push exceeds GitHub's 2GB limit
- **All branches + tags**: Mirror push syncs everything, not just default branch
- **Dry run mode**: Compare without pushing

## Setup

### 1. Configure Repository Secrets

In the repository that runs the sync workflow, add these secrets (Settings → Secrets and variables → Actions):

| Secret | Required | Description |
|--------|----------|-------------|
| `SOURCE_GIT_URL` | ✅ | Source repo URL (e.g. `https://gitcode.com/user/repo.git`) |
| `TARGET_GIT_URL` | ✅ | Target repo URL (e.g. `https://github.com/user/repo.git`) |
| `TARGET_GIT_TOKEN` | ✅ | GitHub PAT with `repo` scope (for push) |

### 2. Create the PAT

1. Go to GitHub → Settings → Developer settings → Personal access tokens → **Tokens (classic)**
2. Generate new token (classic)
3. Select scope: **`repo`** (full repo access)
4. Set expiration (recommend 1 year)
5. Copy the token and add it as secret `TARGET_GIT_TOKEN`

### 3. Add the workflow

Create `.github/workflows/sync.yml`:

```yaml
name: Sync
on:
  schedule:
    - cron: '0 */6 * * *'  # every 6 hours
  workflow_dispatch: {}    # manual trigger

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ./
        with:
          source-git-url: ${{ secrets.SOURCE_GIT_URL }}
          target-git-url: ${{ secrets.TARGET_GIT_URL }}
          target-git-token: ${{ secrets.TARGET_GIT_TOKEN }}
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `source-git-url` | ✅ | — | Source repository URL |
| `target-git-url` | ✅ | — | Target repository URL |
| `target-git-token` | ✅ | — | PAT for pushing to target |
| `source-git-token` | ❌ | `''` | Token for private source repos |
| `dry-run` | ❌ | `false` | Only compare, don't push |

## Outputs

| Output | Description |
|--------|-------------|
| `synced` | `true` if push happened, `false` if skipped |
| `source-sha` | Source HEAD commit SHA |
| `target-sha` | Target HEAD SHA before sync |

## How It Works

1. `git ls-remote` on both repos to get HEAD SHAs
2. If SHAs match → skip (already in sync)
3. If different → `git clone --mirror` source
4. `git push --mirror` to target
5. If mirror push fails (>2GB) → fall back to batch push (500 commits at a time)
6. Push all tags

## License

MIT
