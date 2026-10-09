#!/usr/bin/env bash
# publish-render.bash <env> <branch> <source-sha>: commit the rendered tree in dist/manifests/<env> to
# <branch> as one commit on top of the previous render, and push it. The tree replaces the branch's
# content, a generated README.md names the source commit, and nothing is pushed when the render did not
# change. The branch is created, as an orphan, only the first time. A rejected push is retried once on top
# of the branch as it then is; nothing is ever force-pushed.
set -euo pipefail
cd "$(dirname "$0")/.."

env=${1:?usage: publish-render.bash <env> <branch> <source-sha>}
branch=${2:?usage: publish-render.bash <env> <branch> <source-sha>}
sha=${3:?usage: publish-render.bash <env> <branch> <source-sha>}
src="dist/manifests/$env"
[[ -d "$src" ]] || { echo "publish: $src does not exist; run make render ENV=$env first" >&2; exit 1; }

work="$(mktemp -d)"
trap 'git worktree remove --force "$work" >/dev/null 2>&1 || true' EXIT

# commit_on_top: put the render on top of origin/<branch> (or a new orphan branch) in $work and commit it.
# Exits the script on any git failure; returns 3 when the manifests did not change.
commit_on_top() {
  git worktree remove --force "$work" >/dev/null 2>&1 || true
  rm -rf "$work"
  if git fetch -q origin "$branch" 2>/dev/null; then
    git worktree add -q -B "$branch" "$work" FETCH_HEAD || exit 1
  else
    git branch -D "$branch" >/dev/null 2>&1 || true
    git worktree add -q --orphan -b "$branch" "$work" || exit 1
  fi
  find "$work" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} + || exit 1
  cp -R "$src"/. "$work"/ || exit 1
  cat >"$work/README.md" <<README || exit 1
# Rendered manifests: $env

Generated; do not edit or push to this branch by hand. The \`render-dev\` workflow rewrites it from
\`main\` on every push, as one commit per render.

- Source: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/commit/$sha
- Environment: \`cluster-configs/overrides/values-$env.yaml\`
- Layout: \`<namespace>/<kind>-<name>.yaml\`, CRDs included, no Argo CD Applications

Apply it with \`kubectl apply -R -f .\` (the CRDs and the operator first, so apply twice on a new cluster),
or track it with a directory Application. Secrets are not here: create them in the cluster first.
README
  git -C "$work" add -A || exit 1
  # README.md names the source commit, so it changes every time; only the manifests decide.
  if git -C "$work" rev-parse -q --verify HEAD >/dev/null &&
    git -C "$work" diff --cached --quiet HEAD -- . ':!README.md'; then
    echo "publish: the $env render did not change; nothing to push"
    return 3
  fi
  git -C "$work" -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit -q -m "chore: render $env manifests from $sha" || exit 1
}

status=0
commit_on_top || status=$?
((status == 3)) && exit 0
if ! git -C "$work" push -q origin "$branch"; then
  echo "publish: push rejected; retrying once on top of the current $branch"
  status=0
  commit_on_top || status=$?
  ((status == 3)) && exit 0
  git -C "$work" push -q origin "$branch"
fi
echo "publish: pushed $(git -C "$work" rev-parse --short HEAD) to $branch"
