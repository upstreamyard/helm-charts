#!/usr/bin/env bash
# Bump a chart to the latest release of the packaged project, if the image for it is already published.
#
# Usage: scripts/bump-chart.sh <chart> <project-repo> <image> [<tag-prefix>]
#   e.g. scripts/bump-chart.sh aegra aegra/aegra ghcr.io/upstreamyard/aegra
#        scripts/bump-chart.sh cube cube-js/cube docker.io/cubejs/cube v   # image tags are v1.2.3
#
# Prints "version=<x>" and "changed=true|false" (also to $GITHUB_OUTPUT when set).
# Edits charts/<chart>/Chart.yaml in place: appVersion, patch-bumped chart version,
# Artifact Hub image and changes annotations. Does not commit.
#
# Env: DRY_RUN=1          only report, do not edit
#      SKIP_IMAGE_CHECK=1 do not require the image to exist (local testing only)
# Needs: gh, yq (mikefarah v4), docker buildx (for the image check)
set -euo pipefail

chart=$1 upstream=$2 image=$3 tag_prefix=${4:-}
chart_yaml="charts/$chart/Chart.yaml"

out() { echo "$1"; [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT"; return 0; }

current=$(yq '.appVersion' "$chart_yaml")
# Highest stable release (vX.Y.Z), not GitHub's "latest release": some projects publish
# release candidates without flagging them as prereleases.
latest=$(gh api --paginate "repos/$upstream/releases?per_page=100" --jq '.[] | select(.draft | not) | .tag_name' \
  | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//' | sort -V | tail -1)
out "version=$latest"

if [ "$latest" = "$current" ] || [ "$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -1)" != "$latest" ]; then
  echo "$chart is up to date ($current)."
  out "changed=false"; exit 0
fi

if [ "${SKIP_IMAGE_CHECK:-}" != "1" ] && ! docker buildx imagetools inspect "$image:$tag_prefix$latest" >/dev/null 2>&1; then
  echo "$upstream released $latest, but $image:$tag_prefix$latest is not published yet. Will retry next run."
  out "changed=false"; exit 0
fi

chart_version=$(yq '.version' "$chart_yaml")
IFS=. read -r major minor patch <<< "$chart_version"
new_chart_version="$major.$minor.$((patch + 1))"
echo "Bumping $chart: appVersion $current -> $latest, chart $chart_version -> $new_chart_version"

if [ "${DRY_RUN:-}" = "1" ]; then
  out "changed=false"; exit 0
fi

image_name=${image##*/}
# The Artifact Hub images annotation keeps its image names; only the tags move
# from the old to the new version (works for charts with several images).
OLD_TAG=":$tag_prefix$current" NEW_TAG=":$tag_prefix$latest" VERSION=$latest CHART_VERSION=$new_chart_version IMAGE_NAME=$image_name yq -i '
  .appVersion = strenv(VERSION) |
  .version = strenv(CHART_VERSION) |
  .annotations."artifacthub.io/images" |= sub(strenv(OLD_TAG); strenv(NEW_TAG)) |
  .annotations."artifacthub.io/changes" = "- kind: changed\n  description: Update " + strenv(IMAGE_NAME) + " to " + strenv(VERSION) + "\n"
' "$chart_yaml"
out "changed=true"
