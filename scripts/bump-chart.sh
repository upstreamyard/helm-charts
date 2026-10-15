#!/usr/bin/env bash
# Bump a chart to the latest release of the packaged project, if the image for it is already published.
#
# Usage: scripts/bump-chart.sh <chart> <project-repo> <image> [<values-path>]
#   e.g. scripts/bump-chart.sh aegra aegra/aegra ghcr.io/upstreamyard/aegra
#        scripts/bump-chart.sh saleor saleor/saleor ghcr.io/saleor/saleor
#        scripts/bump-chart.sh saleor saleor/saleor-dashboard ghcr.io/saleor/saleor-dashboard .dashboard.image.tag
#
# Without <values-path> the chart's appVersion follows the latest release of <project-repo>.
# With it, the image tag at that path in values.yaml does instead (for a second image such as
# Saleor's dashboard); only releases with the same major.minor as the chart's appVersion count,
# so the second image stays compatible with the app.
#
# Prints "version=<x>" and "changed=true|false" (also to $GITHUB_OUTPUT when set).
# Edits charts/<chart>/Chart.yaml (and values.yaml with <values-path>) in place: the version,
# patch-bumped chart version, Artifact Hub image and changes annotations. Does not commit.
#
# Env: DRY_RUN=1          only report, do not edit
#      SKIP_IMAGE_CHECK=1 do not require the image to exist (local testing only)
# Needs: gh, yq (mikefarah v4), docker buildx (for the image check)
set -euo pipefail

chart=$1 upstream=$2 image=$3 values_path=${4:-}
chart_yaml="charts/$chart/Chart.yaml"
values_yaml="charts/$chart/values.yaml"

out() { echo "$1"; [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT"; return 0; }

if [ -z "$values_path" ]; then
  current=$(yq '.appVersion' "$chart_yaml")
  latest=$(gh api "repos/$upstream/releases/latest" --jq .tag_name)
else
  current=$(yq "$values_path" "$values_yaml")
  app_minor=$(yq '.appVersion' "$chart_yaml" | cut -d. -f1-2)
  latest=$(gh api "repos/$upstream/releases?per_page=100" \
    --jq '.[] | select((.draft or .prerelease) | not) | .tag_name' \
    | sed 's/^v//' | { grep -E "^${app_minor//./\\.}\.[0-9]+$" || true; } | sort -V | tail -1)
  [ -n "$latest" ] || { echo "No $upstream release for $app_minor.x."; out "changed=false"; exit 0; }
fi
latest=${latest#v}
out "version=$latest"

if [ "$latest" = "$current" ] || [ "$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -1)" != "$latest" ]; then
  echo "$chart ($upstream) is up to date ($current)."
  out "changed=false"; exit 0
fi

if [ "${SKIP_IMAGE_CHECK:-}" != "1" ] && ! docker buildx imagetools inspect "$image:$latest" >/dev/null 2>&1; then
  echo "$upstream released $latest, but $image:$latest is not published yet. Will retry next run."
  out "changed=false"; exit 0
fi

chart_version=$(yq '.version' "$chart_yaml")
IFS=. read -r major minor patch <<< "$chart_version"
new_chart_version="$major.$minor.$((patch + 1))"
echo "Bumping $chart: $image $current -> $latest, chart $chart_version -> $new_chart_version"

if [ "${DRY_RUN:-}" = "1" ]; then
  out "changed=false"; exit 0
fi

image_name=${image##*/}
# The image as the chart references it: our images by their Docker Hub name,
# other projects' images by their full name.
image_ref=${image/#ghcr.io\/upstreamyard\//upstreamyard/}
if [ -n "$values_path" ]; then
  # Edit only that line; rewriting the file with yq would drop its blank lines.
  key=${values_path##*.}
  pattern="^\( *$key: \"\{0,1\}\)${current//./\\.}\(\"\{0,1\}\)$"
  [ "$(grep -c "$pattern" "$values_yaml")" = 1 ] || { echo "Expected exactly one '$key: $current' line in $values_yaml." >&2; exit 1; }
  sed -i "s/$pattern/\1$latest\2/" "$values_yaml"
  [ "$(yq "$values_path" "$values_yaml")" = "$latest" ] || { echo "Could not update $values_path in $values_yaml." >&2; exit 1; }
else
  VERSION=$latest yq -i '.appVersion = strenv(VERSION)' "$chart_yaml"
fi
# Only this image's line in the images annotation changes; charts can list several images.
VERSION=$latest CHART_VERSION=$new_chart_version IMAGE_NAME=$image_name IMAGE_REF=$image_ref yq -i '
  .version = strenv(CHART_VERSION) |
  .annotations."artifacthub.io/images" |= sub("image: " + strenv(IMAGE_REF) + ":[^\n]*", "image: " + strenv(IMAGE_REF) + ":" + strenv(VERSION)) |
  .annotations."artifacthub.io/changes" = "- kind: changed\n  description: Update " + strenv(IMAGE_NAME) + " to " + strenv(VERSION) + "\n"
' "$chart_yaml"
out "changed=true"
