#!/bin/bash

# Fork-local tooling (not part of upstream notebook-navigator).
#
# Replays this fork's patch onto a new upstream release, verifies the result,
# builds it, and deploys it into the Obsidian vault.
#
# The fork carries a single patch commit ("variable title rows + dynamic preview
# row heights") on top of an upstream release tag, on a branch named
# integrate-<version>. This script automates everything around that patch except
# conflict resolution, which needs a human.
#
# Usage:
#   scripts/integrate-upstream.sh [version] [options]
#
#   version           Upstream release tag to integrate (default: newest tag)
#
# Options:
#   --patch <sha>     Patch commit to replay (default: auto-detected)
#   --vault <dir>     Obsidian plugin directory to deploy into
#   --no-deploy       Stop after the build; do not touch the vault
#   --skip-install    Do not run "npm ci" even if the lockfile moved
#   -h, --help        Show this help
#
# Resuming after a conflict: resolve the conflicts, "git add" the files, then
# rerun the same command. The script picks up where it stopped.
#
# Note: this script is carried inside the patch commit so that it lands on every
# integrate-<version> branch. Creating a branch from a bare upstream tag briefly
# removes it from the working tree, so the whole flow lives in main() and is
# invoked on the last line -- bash finishes parsing the file before any checkout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

UPSTREAM_REMOTE="${NN_UPSTREAM_REMOTE:-origin}"
DEFAULT_VAULT="/Users/charleshan/Google Drive/PKM/Obsidian/.obsidian/plugins/notebook-navigator"
VAULT_DIR="${NN_VAULT_PLUGIN_DIR:-$DEFAULT_VAULT}"
DEPLOY_FILES=(main.js styles.css manifest.json)

VERSION=""
PATCH_COMMIT=""
BRANCH=""
DO_DEPLOY=1
DO_INSTALL=1
WARNINGS=0

info() { echo "$*"; }
ok() { echo "✅ $*"; }
warn() {
    echo "⚠️  $*"
    WARNINGS=$((WARNINGS + 1))
}
fail() {
    echo "❌ $*" >&2
    exit 1
}
step() { echo -e "\n── $* ──"; }

usage() {
    sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h | --help) usage ;;
            --no-deploy)
                DO_DEPLOY=0
                shift
                ;;
            --skip-install)
                DO_INSTALL=0
                shift
                ;;
            --patch)
                PATCH_COMMIT="${2:-}"
                [ -n "$PATCH_COMMIT" ] || fail "--patch needs a commit"
                shift 2
                ;;
            --vault)
                VAULT_DIR="${2:-}"
                [ -n "$VAULT_DIR" ] || fail "--vault needs a directory"
                shift 2
                ;;
            -*) fail "Unknown option: $1" ;;
            *)
                [ -z "$VERSION" ] || fail "Version given twice: $VERSION and $1"
                VERSION="$1"
                shift
                ;;
        esac
    done
}

# The patch lives as the single commit on the newest integrate-<version> branch
# that is not part of upstream history.
detect_patch_commit() {
    local prev_branch commits count
    prev_branch="$(git branch --list 'integrate-*' --format='%(refname:short)' |
        grep -E '^integrate-[0-9]+\.[0-9]+\.[0-9]+$' |
        grep -v "^$BRANCH\$" |
        sed 's/^integrate-//' | sort -V | tail -1)"
    [ -n "$prev_branch" ] || return 1
    prev_branch="integrate-$prev_branch"

    commits="$(git rev-list "$prev_branch" --not "$UPSTREAM_REMOTE/main" 2>/dev/null || true)"
    count="$(echo "$commits" | grep -c . || true)"
    if [ "$count" != "1" ]; then
        echo "$prev_branch carries $count commits outside upstream; expected 1" >&2
        return 1
    fi
    echo "$commits"
}

# styles.css is generated from src/styles/sections/*.css, so a conflict in it is
# noise: regenerate it once the CSS sources are settled.
regenerate_styles_if_only_conflict() {
    local unmerged
    unmerged="$(git diff --name-only --diff-filter=U)"
    [ -n "$unmerged" ] || return 0
    if [ "$unmerged" = "styles.css" ]; then
        info "Only styles.css conflicts; regenerating it from src/styles/sections/"
        node scripts/build-styles.mjs >/dev/null || fail "build-styles.mjs failed"
        git add styles.css
        ok "styles.css regenerated and staged"
    fi
}

report_conflicts_and_exit() {
    local unmerged
    unmerged="$(git diff --name-only --diff-filter=U)"
    echo
    echo "❌ Cherry-pick stopped on conflicts in:"
    echo "$unmerged" | sed 's/^/     /'
    cat <<EOF

  Resolve them, then:
     git add <files>
     $0 $VERSION

  The script will finish the cherry-pick and continue from there.
  To give up entirely:  git cherry-pick --abort
EOF
    exit 2
}

resolve_target() {
    step "Fetching $UPSTREAM_REMOTE"
    git fetch "$UPSTREAM_REMOTE" --tags --prune >/dev/null 2>&1 || fail "Fetch from $UPSTREAM_REMOTE failed"
    ok "Fetched $UPSTREAM_REMOTE"

    if [ -z "$VERSION" ]; then
        VERSION="$(git tag --list --sort=-v:refname | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -1)"
        [ -n "$VERSION" ] || fail "No release tags found; pass a version explicitly"
        info "No version given, using newest tag: $VERSION"
    fi

    git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null || fail "Tag '$VERSION' does not exist"
    BRANCH="integrate-$VERSION"
    ok "Target: upstream $VERSION -> branch $BRANCH"
}

apply_patch() {
    if [ -f "$(git rev-parse --git-dir)/CHERRY_PICK_HEAD" ]; then
        # Resuming a cherry-pick left behind by a previous run
        step "Resuming in-progress cherry-pick"
        regenerate_styles_if_only_conflict
        [ -z "$(git diff --name-only --diff-filter=U)" ] || report_conflicts_and_exit
        GIT_EDITOR=true git cherry-pick --continue || fail "Could not finish the cherry-pick"
        BRANCH="$(git rev-parse --abbrev-ref HEAD)"
        ok "Cherry-pick completed on $BRANCH"
        return 0
    fi

    # Untracked files are ignored: this script may itself be untracked on a
    # freshly created branch.
    [ -z "$(git status --porcelain --untracked-files=no)" ] ||
        fail "Working tree has uncommitted changes; commit or stash first"

    local patch_applied=0
    if git rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null; then
        step "Branch $BRANCH already exists"
        git checkout "$BRANCH" >/dev/null 2>&1 || fail "Could not check out $BRANCH"
        if [ "$(git rev-list --count "$VERSION..HEAD")" -gt 0 ]; then
            ok "Patch already applied on $BRANCH; skipping to verification"
            patch_applied=1
        fi
    else
        step "Creating $BRANCH from upstream $VERSION"
        git checkout -b "$BRANCH" "$VERSION" >/dev/null 2>&1 || fail "Could not create $BRANCH"
        ok "Created $BRANCH"
    fi

    [ "$patch_applied" -eq 0 ] || return 0

    if [ -z "$PATCH_COMMIT" ]; then
        PATCH_COMMIT="$(detect_patch_commit)" ||
            fail "Could not auto-detect the patch commit; pass it with --patch <sha>"
    fi
    info "Replaying patch: $(git log -1 --format='%h %s' "$PATCH_COMMIT")"

    if git cherry-pick "$PATCH_COMMIT" >/dev/null 2>&1; then
        ok "Patch applied cleanly"
        return 0
    fi

    regenerate_styles_if_only_conflict
    if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
        report_conflicts_and_exit
    fi
    GIT_EDITOR=true git cherry-pick --continue >/dev/null || fail "Could not finish the cherry-pick"
    ok "Patch applied (styles.css auto-resolved)"
}

sync_dependencies() {
    step "Dependencies"
    if [ "$DO_INSTALL" -eq 0 ]; then
        info "Skipped (--skip-install)"
    elif [ -f node_modules/.package-lock.json ] && [ node_modules/.package-lock.json -nt package-lock.json ]; then
        ok "node_modules is current"
    else
        info "Lockfile moved; running npm ci"
        npm ci >/dev/null 2>&1 || fail "npm ci failed"
        ok "Dependencies installed"
    fi
}

verify() {
    step "Verifying"

    npx tsc --noEmit --skipLibCheck || fail "TypeScript type checking failed"
    ok "TypeScript types are valid"

    npm run lint >/dev/null 2>&1 || fail "ESLint failed (run 'npm run lint' for details)"
    ok "ESLint passed"

    npm run lint:styles >/dev/null 2>&1 || fail "Stylelint failed (run 'npm run lint:styles' for details)"
    ok "Stylelint passed"

    # Formatting is cosmetic, so it warns rather than blocking a deploy.
    if npm run format:check >/dev/null 2>&1; then
        ok "Formatting is clean"
    else
        warn "Prettier reported unformatted files (run 'npm run format:check')"
    fi

    npm test || fail "Tests failed"
    ok "Tests passed"
}

build() {
    step "Building"
    npm run build >/dev/null 2>&1 || fail "Build failed"
    local f
    for f in "${DEPLOY_FILES[@]}"; do
        [ -f "$f" ] || fail "Build did not produce $f"
    done
    ok "Built main.js ($(du -h main.js | cut -f1)) and styles.css ($(du -h styles.css | cut -f1))"
}

deploy() {
    if [ "$DO_DEPLOY" -eq 0 ]; then
        step "Deploy skipped (--no-deploy)"
        return 0
    fi

    step "Deploying to vault"
    [ -d "$VAULT_DIR" ] || fail "Vault plugin directory not found: $VAULT_DIR"

    local backup_dir f
    backup_dir="$VAULT_DIR/backup_$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    # data.json holds live plugin settings. It is backed up but never written to.
    for f in "${DEPLOY_FILES[@]}" data.json; do
        if [ -f "$VAULT_DIR/$f" ]; then
            cp "$VAULT_DIR/$f" "$backup_dir/$f"
        fi
    done
    ok "Backed up current install to $(basename "$backup_dir")/"

    for f in "${DEPLOY_FILES[@]}"; do
        cp "$f" "$VAULT_DIR/$f"
    done
    ok "Deployed ${DEPLOY_FILES[*]} (data.json untouched)"
}

summary() {
    echo
    echo "════════════════════════════════════════════"
    echo "  Integrated upstream $VERSION on $BRANCH"
    if [ "$WARNINGS" -gt 0 ]; then
        echo "  Completed with $WARNINGS warning(s)"
    fi
    echo "════════════════════════════════════════════"
    if [ "$DO_DEPLOY" -eq 1 ]; then
        echo
        echo "  Reload Obsidian, or toggle Notebook Navigator"
        echo "  off and on, to load the new build."
    fi
    echo
}

main() {
    parse_args "$@"
    git rev-parse --git-dir >/dev/null 2>&1 || fail "Not a git repository"
    resolve_target
    apply_patch
    sync_dependencies
    verify
    build
    deploy
    summary
}

main "$@"
