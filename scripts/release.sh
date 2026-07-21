#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/release.sh [--build-only]

Build the Modrinth pack for the version in pack.toml. By default, also create
and push an annotated v<version> tag and publish a GitHub release containing
the .mrpack and its SHA256SUMS file.

Options:
  --build-only  Build and verify release artifacts without publishing them.
  -h, --help    Show this help.
EOF
}

build_only=false
case "${1:-}" in
  "") ;;
  --build-only) build_only=true ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "error: run this script from inside the repository" >&2
  exit 1
}
cd "$repo_root"

for command_name in git packwiz sha256sum unzip; do
  command -v "$command_name" >/dev/null || {
    echo "error: required command not found: $command_name" >&2
    exit 1
  }
done
if ! $build_only; then
  command -v gh >/dev/null || { echo "error: required command not found: gh" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "error: gh is not authenticated" >&2; exit 1; }
fi

version=$(awk -F ' *= *' '
  /^\[/ { exit }
  $1 == "version" {
    value = $2
    gsub(/^"|"$/, "", value)
    print value
    exit
  }
' pack.toml)
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  echo "error: pack.toml has a missing or invalid version: ${version:-<empty>}" >&2
  exit 1
}

tag="v$version"
artifact_name="All-of-CC-Tweaked-$version.mrpack"
build_dir="$repo_root/build"
artifact="$build_dir/$artifact_name"
checksums="$build_dir/SHA256SUMS"

[[ -z $(git status --porcelain) ]] || {
  echo "error: the worktree must be clean before building a release" >&2
  exit 1
}

if ! $build_only; then
  [[ $(git branch --show-current) == main ]] || {
    echo "error: releases must be published from the main branch" >&2
    exit 1
  }
  git fetch origin main --tags
  [[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || {
    echo "error: local main must exactly match origin/main; commit and push first" >&2
    exit 1
  }
  ! git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null || {
    echo "error: tag $tag already exists" >&2
    exit 1
  }
  ! gh release view "$tag" >/dev/null 2>&1 || {
    echo "error: GitHub release $tag already exists" >&2
    exit 1
  }
fi

echo "Refreshing and checking Packwiz metadata..."
packwiz refresh
[[ -z $(git status --porcelain) ]] || {
  echo "error: packwiz refresh changed tracked files; review and commit them first" >&2
  git status --short >&2
  exit 1
}
before=$(sha256sum pack.toml index.toml)
packwiz refresh
after=$(sha256sum pack.toml index.toml)
[[ $before == "$after" ]] || {
  echo "error: repeated packwiz refresh was not deterministic" >&2
  exit 1
}

rm -rf "$build_dir"
mkdir -p "$build_dir"
echo "Exporting $artifact_name..."
packwiz modrinth export -o "$artifact"
unzip -tq "$artifact" >/dev/null
(
  cd "$build_dir"
  sha256sum "$artifact_name" > SHA256SUMS
  sha256sum -c SHA256SUMS
)

if $build_only; then
  echo "Built and verified: $artifact"
  echo "Checksums: $checksums"
  exit 0
fi

git tag -a "$tag" -m "All of CC:Tweaked $version"
git push origin "$tag"
gh release create "$tag" "$artifact" "$checksums" \
  --title "All of CC:Tweaked $version" \
  --generate-notes \
  --verify-tag

# Use jq through gh's built-in JSON query support, without requiring a separate jq binary.
url=$(gh release view "$tag" --json url --jq .url)
is_draft=$(gh release view "$tag" --json isDraft --jq .isDraft)
is_prerelease=$(gh release view "$tag" --json isPrerelease --jq .isPrerelease)
asset_count=$(gh release view "$tag" --json assets --jq '.assets | length')
asset_names=$(gh release view "$tag" --json assets --jq '.assets[].name')
[[ $is_draft == false && $is_prerelease == false && $asset_count == 2 ]] || {
  echo "error: published release verification failed; inspect $url" >&2
  exit 1
}
grep -Fxq "$artifact_name" <<<"$asset_names" && grep -Fxq SHA256SUMS <<<"$asset_names" || {
  echo "error: published release is missing an expected asset; inspect $url" >&2
  exit 1
}

echo "Published and verified: $url"