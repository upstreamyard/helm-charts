#!/usr/bin/env bash
# Bump a chart to the newest release of the packaged project, once the image for it is published.
#
# Usage: scripts/bump-chart.sh <chart> <project> <image>
#   <project>  GitHub repository (owner/name), or the URL of a download folder that lists one
#              folder per version (e.g. https://downloads.apache.org/activemq/)
#   <image>    the image the chart follows, e.g. ghcr.io/upstreamyard/aegra or docker.io/cubejs/cube
#   e.g. scripts/bump-chart.sh aegra aegra/aegra ghcr.io/upstreamyard/aegra
#
# Settings per chart live in .github/bump/<chart>.yaml; bump.yml passes them as environment:
#   RELEASE_PREFIX  only releases whose tag starts with it count, and the version is the rest
#                   (repositories that release several packages, e.g. "@core/sync-service@")
#   TAG_PREFIX      the image tag is <prefix><version>, e.g. "v" for cubejs/cube:v1.8.3
#   TAG_SUFFIX      the image tag is <version><suffix>, e.g. "-kafka" for automqinc/automq:1.7.4-kafka
#   VALUES_PATH     follow a second image whose tag is pinned in values.yaml at this path
#                   (e.g. .dashboard.image.tag) instead of appVersion. Only releases with the
#                   same major.minor as the chart's appVersion count.
#
# The highest plain X.Y.Z version counts: release candidates are skipped even when the project
# doesn't mark them as pre-releases, and a patch for an older line released last doesn't win.
# Versions come from GitHub releases, or from git tags when the project publishes no releases.
#
# Edits in place: appVersion (or the VALUES_PATH line), the patch-bumped chart version, the image
# in the Artifact Hub images annotation (the chart's other images stay) and the changes annotation.
# If scripts/bump-hooks/<chart>.sh exists, it runs with the release tag and may update files under
# charts/<chart>/files; when those change, "review=true" asks for a review instead of an auto-merge.
# Does not commit.
#
# Prints "version=<x>", "changed=true|false" and "review=true|false" (also to $GITHUB_OUTPUT when set).
# Env: DRY_RUN=1          only report, do not edit
#      SKIP_IMAGE_CHECK=1 do not require the image to exist (local testing only)
# Needs: gh, git, curl, yq (mikefarah v4), docker buildx (for the image check)
set -euo pipefail

chart=$1 project=$2 image=$3
chart_yaml="charts/$chart/Chart.yaml"
values_yaml="charts/$chart/values.yaml"
release_prefix=${RELEASE_PREFIX:-} tag_prefix=${TAG_PREFIX:-} tag_suffix=${TAG_SUFFIX:-} values_path=${VALUES_PATH:-}

out() { echo "$1"; [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT"; return 0; }

# Every release of the project as "<tag> <publish date>" lines; the date is "-" when unknown.
release_tags() {
  if [[ $project == https://* ]]; then
    curl -fsSL "$project" | grep -oE 'href="v?[0-9]+\.[0-9]+\.[0-9]+/"' | sed -E 's/^href="//; s#/"$# -#'
    return
  fi
  local tags
  tags=$(gh api --paginate "repos/$project/releases?per_page=100" \
    --jq '.[] | select((.draft or .prerelease) | not) | "\(.tag_name) \(.published_at // "-")"')
  if [ -z "$tags" ]; then
    # Some projects (e.g. Discourse) publish releases only as git tags.
    tags=$(git ls-remote --tags --refs "https://github.com/$project.git" | sed 's#.*refs/tags/##; s/$/ -/')
  fi
  printf '%s\n' "$tags"
}

# Reads "<tag> <date>" lines, prints "<version> <tag> <date>" for every X.Y.Z version
# (optionally only within $1, a major.minor).
versions() {
  local tag date version within=${1:-}
  while read -r tag date; do
    [ -n "$tag" ] || continue
    version=$tag
    if [ -n "$release_prefix" ]; then
      [[ $tag == "$release_prefix"* ]] || continue
      version=${tag#"$release_prefix"}
    fi
    version=${version#v}
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    [ -z "$within" ] || [[ $version == "$within".* ]] || continue
    echo "$version $tag ${date:--}"
  done
}

# Reads "<version> <tag> <date>" lines, prints "<version> <tag>" of the highest version that was
# published no earlier than the current version $1. The date check skips old tags in another
# numbering that sort higher (Saleor's 2017.07.0 next to 3.23.x).
newest() {
  local all since
  all=$(cat)
  since=$(awk -v cur="$1" '$1 == cur && $3 != "-" { print $3; exit }' <<< "$all")
  awk -v since="$since" 'since == "" || $3 == "-" || $3 >= since { print $1, $2 }' <<< "$all" | sort -V | tail -1
}

if [ -n "$values_path" ]; then
  current=$(yq "$values_path" "$values_yaml")
  within=$(yq '.appVersion' "$chart_yaml" | cut -d. -f1-2)
else
  current=$(yq '.appVersion' "$chart_yaml")
  within=""
fi
tags=$(release_tags) || { echo "Could not list the releases of $project." >&2; exit 1; }
read -r latest tag <<< "$(versions "$within" <<< "$tags" | newest "$current")" || true
[ -n "${latest:-}" ] || { echo "No X.Y.Z release found for $project${within:+ in $within.x}."; exit 1; }
out "version=$latest"

if [ "$latest" = "$current" ] || [ "$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -1)" != "$latest" ]; then
  echo "$chart is up to date ($image $current)."
  out "changed=false"; out "review=false"; exit 0
fi

old_tag=$tag_prefix$current$tag_suffix new_tag=$tag_prefix$latest$tag_suffix
if [ "${SKIP_IMAGE_CHECK:-}" != "1" ] && ! docker buildx imagetools inspect "$image:$new_tag" >/dev/null 2>&1; then
  echo "$project released $latest, but $image:$new_tag is not published yet. Will retry next run."
  out "changed=false"; out "review=false"; exit 0
fi

chart_version=$(yq '.version' "$chart_yaml")
IFS=. read -r major minor patch <<< "$chart_version"
new_chart_version="$major.$minor.$((patch + 1))"
echo "Bumping $chart: $image $current -> $latest, chart $chart_version -> $new_chart_version"

if [ "${DRY_RUN:-}" = "1" ]; then
  out "changed=false"; out "review=false"; exit 0
fi

if [ -n "$values_path" ]; then
  # Edit only that line; rewriting values.yaml with yq would drop its blank lines.
  key=${values_path##*.}
  pattern="^\( *$key: \"\{0,1\}\)${current//./\\.}\(\"\{0,1\}\)$"
  [ "$(grep -c "$pattern" "$values_yaml")" = 1 ] || { echo "Expected exactly one '$key: $current' line in $values_yaml." >&2; exit 1; }
  sed -i "s/$pattern/\1$latest\2/" "$values_yaml"
  [ "$(yq "$values_path" "$values_yaml")" = "$latest" ] || { echo "Could not update $values_path in $values_yaml." >&2; exit 1; }
else
  VERSION=$latest yq -i '.appVersion = strenv(VERSION)' "$chart_yaml"
fi

# The images annotation as Artifact Hub shows it: our images by their Docker Hub name, other
# projects' images by their full name without docker.io/. This image gets the new tag; so do the
# chart's other images on the old tag when they follow appVersion (e.g. cubejs/cubestore).
# Images with other tags (sidecars, a separately released second image) stay as they are.
image_name=${image##*/}
image_ref=${image#docker.io/}
image_ref=${image_ref/#ghcr.io\/upstreamyard\//upstreamyard/}
export REF=$image_ref NAME=$image_name OLD=$old_tag NEW=$new_tag
SIBLINGS=true
[ -z "$values_path" ] || SIBLINGS=false
export SIBLINGS
images=$(yq '.annotations."artifacthub.io/images" // "[]"' "$chart_yaml" | yq '
  (.[] | select((.image | sub(":[^:/]*$"; "")) == strenv(REF)
                or (strenv(SIBLINGS) == "true" and (.image | split(":") | .[-1]) == strenv(OLD))) | .image)
    |= sub(":[^:/]*$"; "") + ":" + strenv(NEW)')
if [ "$(echo "$images" | yq '[.[] | select((.image | sub(":[^:/]*$"; "")) == strenv(REF))] | length')" = 0 ]; then
  images=$(echo "$images" | yq '. + [{"name": strenv(NAME), "image": strenv(REF) + ":" + strenv(NEW)}]')
fi
IMAGES="$images" VERSION=$latest CHART_VERSION=$new_chart_version IMAGE_NAME=$image_name yq -i '
  .version = strenv(CHART_VERSION) |
  .annotations."artifacthub.io/images" = strenv(IMAGES) + "\n" |
  .annotations."artifacthub.io/changes" = "- kind: changed\n  description: Update " + strenv(IMAGE_NAME) + " to " + strenv(VERSION) + "\n"
' "$chart_yaml"
out "changed=true"

hook="scripts/bump-hooks/$chart.sh"
if [ -x "$hook" ]; then
  "$hook" "$tag"
  if [ -d "charts/$chart/files" ] && [ -n "$(git status --porcelain -- "charts/$chart/files")" ]; then
    echo "The release changed files under charts/$chart/files; the PR needs a review."
    out "review=true"; exit 0
  fi
fi
out "review=false"
