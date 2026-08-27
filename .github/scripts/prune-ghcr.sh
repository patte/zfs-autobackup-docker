#!/usr/bin/env sh
# Prune the GHCR package: keep every tagged release forever, delete untagged
# leftovers once they are older than KEEP_AGE_DAYS.
#
# The policy by example (KEEP_AGE_DAYS=90):
#   - A weekly rebuild moves :latest/:main/:3.3 from digest A to digest B.
#     A is now untagged but stays pullable by digest for 90 days from its
#     build date, then is deleted together with its cosign signature and
#     child manifests. Digest pins are guaranteed for ~90 days per build.
#   - Upstream releases 3.4: :latest moves on, :3.3 keeps pointing at its
#     final build and is kept forever. Tagged versions are never deleted
#     (they are also no longer rebuilt: only the current stable and pre
#     versions are).
#   - :pre moves from 4.0rc1 to 4.0rc2: :4.0rc1 remains as a permanent pin;
#     the rc1-era rebuild leftovers age out after 90 days like everything
#     else.
#
# Why a custom script instead of an off-the-shelf "delete untagged versions":
# a release is several package versions. With provenance + SBOM the release is
# an index whose child manifests (image + the provenance/SBOM attestation) are
# *untagged* versions, and cosign stores its signature as a separate artifact
# tagged after the subject digest -- sha256-<hex> (OCI 1.1 referrers fallback)
# or the legacy sha256-<hex>.sig -- which itself references an untagged
# signature manifest. To keep a release usable we must keep all of these; to
# drop one we must delete all of them. So we resolve each kept release to the
# exact set of digests that belong to it and delete everything outside that
# set.
#
# The keep set is computed from tags first and the age gate protects fresh
# pushes, so a bug or odd registry state can at worst delete a stray too early
# or keep too much -- never break a tagged release.
#
# Env:
#   IMAGE          image ref without tag, e.g. ghcr.io/patte/zfs-autobackup
#   OWNER          GHCR owner (user/org) that owns the package
#   PACKAGE        package name, e.g. zfs-autobackup
#   KEEP_AGE_DAYS  minimum age before an untagged version is deleted
#                  (default 90)
#   DRY_RUN        "true" prints what would be deleted without deleting
#   GH_TOKEN       token with packages:write on the package (GITHUB_TOKEN is
#                  enough when the package inherits access from this repo;
#                  otherwise a PAT with delete:packages)
set -eu

: "${IMAGE:?}"
: "${OWNER:?}"
: "${PACKAGE:?}"
: "${GH_TOKEN:?}"
KEEP_AGE_DAYS="${KEEP_AGE_DAYS:-90}"
DRY_RUN="${DRY_RUN:-false}"

# GHCR refs and package names are lowercase; the caller may pass them straight
# from ${{ github.repository }} etc., which can contain uppercase on some forks.
IMAGE="$(printf '%s' "$IMAGE" | tr '[:upper:]' '[:lower:]')"
OWNER="$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')"
PACKAGE="$(printf '%s' "$PACKAGE" | tr '[:upper:]' '[:lower:]')"

# Age cutoff as ISO-8601 UTC; ISO strings compare lexically == chronologically.
# GNU date (runners) first, BSD date (local macOS dry-runs) as fallback.
cutoff="$(date -u -d "${KEEP_AGE_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v -"${KEEP_AGE_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)"

# Packages live under /users/<user> or /orgs/<org>; GET /users/<owner> reports the type for both
if [ "$(gh api "/users/${OWNER}" -q .type 2>/dev/null)" = "Organization" ]; then
  api="/orgs/${OWNER}/packages/container/${PACKAGE}/versions"
else
  api="/users/${OWNER}/packages/container/${PACKAGE}/versions"
fi
tab="$(printf '\t')"

# Registry pull token for manifest lookups (GH_TOKEN works as the basic-auth
# password on the token endpoint, so this also covers private packages).
registry="${IMAGE%%/*}"
repo_path="${IMAGE#*/}"
reg_token="$(curl -sfS -u "x:${GH_TOKEN}" \
  "https://${registry}/token?scope=repository:${repo_path}:pull" | jq -r .token)"
manifest_accept="application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"

# Every version: id, digest (.name), created_at, comma-joined tags.
all="$(mktemp)"
gh api --paginate "$api" \
  -q '.[] | [.id, .name, .created_at, ((.metadata.container.tags // []) | join(","))] | @tsv' \
  >"$all"

# A cosign artifact tag is the subject digest rewritten as sha256-<hex>, with an
# optional legacy .sig/.att/.sbom suffix. Such a tag is never a release tag.
sig_re='^sha256-[0-9a-f]+(\.(sig|att|sbom))?$'

# Releases = tagged versions that are not cosign artifacts. All of them are kept.
keep_indexes="$(mktemp)"
awk -F"$tab" -v re="$sig_re" 'NF>=4 && $4 != "" && $4 !~ re { print $2 }' "$all" \
  >"$keep_indexes"

# Cosign artifacts as "tag<TAB>digest", for referrers lookup by subject digest.
sigmap="$(mktemp)"
awk -F"$tab" -v re="$sig_re" 'NF>=4 && $4 ~ re { print $4 "\t" $2 }' "$all" >"$sigmap"

# Build the keep set: each kept release, the child manifests it references
# (image + provenance/SBOM attestation; `[]?` no-ops for a plain manifest), and
# the cosign artifact covering it plus that artifact's own child manifest(s).
keep="$(mktemp)"
# A failed manifest fetch must abort the run (not silently yield no children),
# otherwise a kept release's children would look deletable.
children() {
  raw="$(curl -sfS -H "Authorization: Bearer ${reg_token}" -H "Accept: ${manifest_accept}" \
    "https://${registry}/v2/${repo_path}/manifests/${1}")"
  printf '%s\n' "$raw" | jq -r '.manifests[]?.digest'
}

while IFS= read -r d; do
  printf '%s\n' "$d"
  children "$d"
  want="sha256-${d#sha256:}"
  sdig="$(awk -F"$tab" -v w="$want" '$1 == w || $1 == w ".sig" { print $2; exit }' "$sigmap")"
  if [ -n "$sdig" ]; then
    printf '%s\n' "$sdig"
    children "$sdig"
  fi
done <"$keep_indexes" >>"$keep"

sort -u -o "$keep" "$keep"

echo "Keeping $(wc -l <"$keep_indexes") tagged release(s) + children + signatures = $(wc -l <"$keep") manifest(s); deleting the rest once older than ${KEEP_AGE_DAYS} days (cutoff ${cutoff})."

# Delete everything outside the keep set that is older than the cutoff: strays
# a tag was moved off of, their children, and their signatures.
deleted=0
skipped=0
while IFS="$tab" read -r id digest created tags; do
  if grep -qxF "$digest" "$keep"; then
    continue
  fi
  if expr "$created" \> "$cutoff" >/dev/null; then
    skipped=$((skipped + 1))
    continue
  fi
  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] would delete $digest (id $id, created $created, tags: ${tags:-<none>})"
  else
    echo "Deleting $digest (id $id, created $created, tags: ${tags:-<none>})"
    gh api --method DELETE "${api}/${id}"
  fi
  deleted=$((deleted + 1))
done <"$all"

verb="deleted"
[ "$DRY_RUN" = "true" ] && verb="would delete"
echo "Prune complete; ${verb} ${deleted} version(s), kept ${skipped} recent stray(s)."
