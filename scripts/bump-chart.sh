#!/usr/bin/env bash
# Bump a chart to the latest release of the packaged project, if our image for it is already published.
#
# Usage: scripts/bump-chart.sh <chart> <project-repo> <image>
#   e.g. scripts/bump-chart.sh aegra aegra/aegra ghcr.io/upstreamyard/aegra
#
# Only plain X.Y.Z releases count; tags like 1.7.5-rc1 are skipped even when the project
# doesn't mark them as pre-releases.
#
# Prints "version=<x>" and "changed=true|false" (also to $GITHUB_OUTPUT when set).
# Edits charts/<chart>/Chart.yaml in place: appVersion, patch-bumped chart version,
# Artifact Hub image and changes annotations. Does not commit.
#
# Env: DRY_RUN=1          only report, do not edit
#      SKIP_IMAGE_CHECK=1 do not require the image to exist (local testing only)
#      TAG_SUFFIX=-kafka  the image tag is <version><suffix> (e.g. automqinc/automq:1.7.4-kafka)
# Needs: gh, yq (mikefarah v4), docker buildx (for the image check)
set -euo pipefail

chart=$1 upstream=$2 image=$3
chart_yaml="charts/$chart/Chart.yaml"

out() { echo "$1"; [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT"; return 0; }

current=$(yq '.appVersion' "$chart_yaml")
latest=$(gh api "repos/$upstream/releases?per_page=100" \
  --jq '.[] | select((.draft or .prerelease) | not) | .tag_name | ltrimstr("v") | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' \
  | sort -V | tail -1)
[ -n "$latest" ] || { echo "No X.Y.Z release found for $upstream."; exit 1; }
out "version=$latest"

if [ "$latest" = "$current" ] || [ "$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -1)" != "$latest" ]; then
  echo "$chart is up to date ($current)."
  out "changed=false"; exit 0
fi

if [ "${SKIP_IMAGE_CHECK:-}" != "1" ] && ! docker buildx imagetools inspect "$image:$latest${TAG_SUFFIX:-}" >/dev/null 2>&1; then
  echo "$upstream released $latest, but $image:$latest${TAG_SUFFIX:-} is not published yet. Will retry next run."
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
# The image as Artifact Hub shows it: our images by their Docker Hub name, other projects'
# official images without the docker.io/ prefix.
image_ref=${image#docker.io/}
image_ref=${image_ref/#ghcr.io\/upstreamyard\//upstreamyard/}
VERSION=$latest CHART_VERSION=$new_chart_version IMAGE_NAME=$image_name IMAGE_REF=$image_ref TAG=$latest${TAG_SUFFIX:-} yq -i '
  .appVersion = strenv(VERSION) |
  .version = strenv(CHART_VERSION) |
  .annotations."artifacthub.io/images" = "- name: " + strenv(IMAGE_NAME) + "\n  image: " + strenv(IMAGE_REF) + ":" + strenv(TAG) + "\n" |
  .annotations."artifacthub.io/changes" = "- kind: changed\n  description: Update " + strenv(IMAGE_NAME) + " to " + strenv(VERSION) + "\n"
' "$chart_yaml"
out "changed=true"
