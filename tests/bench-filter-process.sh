#!/usr/bin/env bash
#
# bench-filter-process.sh
#
# Plan 019 spike harness. Measures the checkout cost of git-local-override's
# git filter in two modes:
#
#   perfile  - the shipped default: per-file `filter.local-override.smudge %f`
#              / `.clean %f`, so git spawns a fresh bash per managed file.
#   process  - the plan-019 prototype: one long-running
#              `filter.local-override.process` serving every file.
#
# It builds a throwaway repo with N managed targets, forces a full checkout
# that materializes them under each mode, and reports wall-clock milliseconds.
# It also runs the plan-009 byte-exact roundtrip cases (binary/NUL, CRLF,
# empty, no-newline, multi-newline) through REAL git in process mode, proving
# the pkt-line framing does not corrupt content.
#
# Usage:
#   tests/bench-filter-process.sh                 # bench + roundtrip verify
#   tests/bench-filter-process.sh --verify-only   # roundtrip verify only
#   tests/bench-filter-process.sh --sizes "1 10"  # custom N list
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED_SRC="$REPO_ROOT/shared"

SIZES="1 10 50 200"
REPEATS=3
VERIFY_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verify-only) VERIFY_ONLY=1 ;;
        --sizes) shift; SIZES="$1" ;;
        --repeats) shift; REPEATS="$1" ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

now_ms() {
    if command -v perl >/dev/null 2>&1; then
        perl -MTime::HiRes=time -e 'printf("%.0f\n", time() * 1000)'
    else
        printf '%s000\n' "$(date +%s)"
    fi
}

# Copy the filter runtime (lib + resolver + filter scripts) into a repo's
# .git/hooks so the filters resolve exactly as an installed repo would.
# Runtime only — the bench never installs entry hooks. The resolver's
# manifest-driven materializer owns the file set.
install_runtime() {
    local git_hooks="$1"
    (
        # shellcheck disable=SC1091
        source "$SHARED_SRC/local-override-resolver.sh"
        install_managed_runtime_from_checkout "$REPO_ROOT" "$git_hooks" false
    )
}

# Remove the managed target files so the next checkout must run the SMUDGE
# filter to re-materialize them (git skips smudge for files already present
# with matching stat, running clean for its up-to-date check instead).
remove_targets() {
    local repo="$1"
    local attrs="$repo/.git/info/attributes"
    local line target
    [[ -f "$attrs" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        target="${line% filter=local-override}"
        [[ -n "$target" && "$target" != "$line" ]] && rm -f "$repo/$target"
    done < "$attrs"
}

configure_mode() {
    # $1 = repo, $2 = mode (perfile|process)
    local repo="$1" mode="$2"
    local hooks="$repo/.git/hooks"
    git -C "$repo" config --unset-all filter.local-override.smudge 2>/dev/null || true
    git -C "$repo" config --unset-all filter.local-override.clean 2>/dev/null || true
    git -C "$repo" config --unset-all filter.local-override.process 2>/dev/null || true
    if [[ "$mode" == "process" ]]; then
        git -C "$repo" config filter.local-override.process "$hooks/local-override-filter-process"
    else
        git -C "$repo" config filter.local-override.smudge "$hooks/local-override-filter-smudge %f"
        git -C "$repo" config filter.local-override.clean "$hooks/local-override-filter-clean %f"
    fi
    git -C "$repo" config filter.local-override.required false
}

# Build a repo with $2 managed targets under workspace $1.
build_repo() {
    local repo="$1" n="$2" i target
    rm -rf "$repo"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config core.autocrlf false
    git -C "$repo" config user.email bench@example.com
    git -C "$repo" config user.name bench
    install_runtime "$repo/.git/hooks"

    {
        echo 'pattern: ".local"'
        echo 'files:'
    } > "$repo/.local-overrides.yaml"

    local attrs="$repo/.git/info/attributes"
    mkdir -p "$repo/.git/info"
    : > "$attrs"

    i=0
    while [[ "$i" -lt "$n" ]]; do
        target="$(printf 'file_%04d.txt' "$i")"
        printf 'original content for %s\n' "$target" > "$repo/$target"
        {
            printf '  - override: %s.local\n' "$target"
            printf '    replaces:\n'
            printf '      - %s\n' "$target"
        } >> "$repo/.local-overrides.yaml"
        printf '%s filter=local-override\n' "$target" >> "$attrs"
        i=$((i + 1))
    done

    git -C "$repo" add -A
    git -C "$repo" commit -q -m "seed $n targets"

    # Create the local override files (gitignored in real use; here just present).
    i=0
    while [[ "$i" -lt "$n" ]]; do
        target="$(printf 'file_%04d.txt' "$i")"
        printf 'LOCAL override content for %s\n' "$target" > "$repo/$target.local"
        i=$((i + 1))
    done
}

# Force a full checkout that re-materializes every tracked file (running the
# smudge filter for the attributed ones), timed in ms. Returns min over REPEATS.
time_checkout() {
    local repo="$1" mode="$2" r start end best="" ms
    configure_mode "$repo" "$mode"
    r=0
    while [[ "$r" -lt "$REPEATS" ]]; do
        remove_targets "$repo"
        start="$(now_ms)"
        git -C "$repo" checkout-index -f -a
        end="$(now_ms)"
        ms=$((end - start))
        if [[ -z "$best" || "$ms" -lt "$best" ]]; then
            best="$ms"
        fi
        r=$((r + 1))
    done
    printf '%s\n' "$best"
}

# Confirm the checkout actually substituted override content for a sample of
# targets (smudge correctness). Byte-exact clean roundtrip is proven
# separately and authoritatively in verify_roundtrip; here we only guard that
# the timed checkout did real filter work rather than passing through.
check_correctness() {
    local repo="$1" n="$2" target sample
    for sample in 0 $((n / 2)) $((n - 1)); do
        [[ "$sample" -lt 0 ]] && continue
        target="$(printf 'file_%04d.txt' "$sample")"
        if ! cmp -s "$repo/$target" "$repo/$target.local"; then
            echo "  CORRECTNESS FAIL: $target working tree != override" >&2
            return 1
        fi
    done
    return 0
}

run_benchmark() {
    local workspace n perfile process
    workspace="$(mktemp -d "${TMPDIR:-/tmp}/lo-bench.XXXXXX")"
    echo "=== Benchmark: checkout of N managed files (min of $REPEATS runs, ms) ==="
    printf '%8s  %12s  %12s  %10s\n' "N" "per-file" "process" "speedup"
    for n in $SIZES; do
        build_repo "$workspace/repo" "$n"
        perfile="$(time_checkout "$workspace/repo" perfile)"
        check_correctness "$workspace/repo" "$n" || exit 1
        process="$(time_checkout "$workspace/repo" process)"
        check_correctness "$workspace/repo" "$n" || exit 1
        local speedup="n/a"
        if [[ "$process" -gt 0 ]]; then
            speedup="$(perl -e 'printf("%.2fx", $ARGV[0]/$ARGV[1])' "$perfile" "$process" 2>/dev/null || echo n/a)"
        fi
        printf '%8s  %10sms  %10sms  %10s\n' "$n" "$perfile" "$process" "$speedup"
    done
    rm -rf "$workspace"
}

# --- byte-exact roundtrip verification through real git, process mode --------
verify_roundtrip() {
    local workspace repo attrs pass=0 fail=0
    workspace="$(mktemp -d "${TMPDIR:-/tmp}/lo-verify.XXXXXX")"
    repo="$workspace/repo"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config core.autocrlf false
    git -C "$repo" config user.email v@example.com
    git -C "$repo" config user.name v
    install_runtime "$repo/.git/hooks"

    local refdir="$workspace/refs"
    mkdir -p "$refdir"
    # Hazardous tracked-blob bytes (plan 009 variants).
    printf 'a\0b\0c' > "$refdir/binary"
    printf 'line1\r\nline2\r\n' > "$refdir/crlf"
    : > "$refdir/empty-blob"
    printf 'tracked content\n' > "$refdir/empty-override"
    printf 'no trailing newline' > "$refdir/no-newline"
    printf 'x\n\n\n' > "$refdir/multi-newline"

    local cases="binary crlf empty-blob empty-override no-newline multi-newline"
    local name
    {
        echo 'pattern: ".local"'
        echo 'files:'
    } > "$repo/.local-overrides.yaml"
    attrs="$repo/.git/info/attributes"
    mkdir -p "$repo/.git/info"
    : > "$attrs"
    for name in $cases; do
        cp "$refdir/$name" "$repo/rt-$name.txt"
        {
            printf '  - override: rt-%s.local.txt\n' "$name"
            printf '    replaces:\n'
            printf '      - rt-%s.txt\n' "$name"
        } >> "$repo/.local-overrides.yaml"
        printf 'rt-%s.txt filter=local-override\n' "$name" >> "$attrs"
    done
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "roundtrip targets"

    # Hazardous OVERRIDE bytes (distinct from the tracked blob shapes).
    printf 'x\0y\0local' > "$repo/rt-binary.local.txt"
    printf 'local1\r\nlocal2\r\n' > "$repo/rt-crlf.local.txt"
    printf 'local override content\n' > "$repo/rt-empty-blob.local.txt"
    : > "$repo/rt-empty-override.local.txt"
    printf 'local no trailing newline' > "$repo/rt-no-newline.local.txt"
    printf 'y\n\n\n\n' > "$repo/rt-multi-newline.local.txt"
    # Reference copies of override bytes for smudge comparison.
    local ovdir="$workspace/ovrefs"
    mkdir -p "$ovdir"
    for name in $cases; do
        cp "$repo/rt-$name.local.txt" "$ovdir/$name"
    done

    configure_mode "$repo" process

    # Smudge every target through the real filter.process handshake. Remove the
    # freshly-committed targets first so git must run smudge (not its clean
    # up-to-date check) to re-materialize them.
    remove_targets "$repo"
    git -C "$repo" checkout-index -f -a

    echo "=== Roundtrip byte-exactness (filter.process, real git) ==="
    # Roundtrip = clean(smudge(original)) == original, byte-for-byte.
    #   smudge: proven by the on-disk working tree == the override bytes.
    #   clean:  `git add` runs the clean filter (through the process protocol)
    #           into the index; the resulting index blob must equal the
    #           original tracked bytes. We compare with cmp (never $(...),
    #           which strips trailing newlines and cannot hold NUL bytes).
    local index_blob="$workspace/index-blob"
    for name in $cases; do
        if ! cmp -s "$repo/rt-$name.txt" "$ovdir/$name"; then
            printf '  [FAIL] %-16s smudge output != override bytes\n' "$name"
            fail=$((fail + 1))
            continue
        fi
        git -C "$repo" add "rt-$name.txt"
        git -C "$repo" show ":rt-$name.txt" > "$index_blob" 2>/dev/null || : > "$index_blob"
        if cmp -s "$index_blob" "$refdir/$name"; then
            printf '  [PASS] %-16s smudge + clean roundtrip byte-exact\n' "$name"
            pass=$((pass + 1))
        else
            printf '  [FAIL] %-16s clean(smudge(x)) != original bytes\n' "$name"
            fail=$((fail + 1))
        fi
    done

    # After clean substituted every original back into the index, nothing is
    # staged (the index blobs match HEAD).
    if [[ -n "$(git -C "$repo" diff --cached --name-only)" ]]; then
        echo "  [FAIL] index diverged from HEAD after smudge+clean roundtrip" >&2
        git -C "$repo" diff --cached --name-only >&2
        fail=$((fail + 1))
    fi

    rm -rf "$workspace"
    echo "=== Roundtrip result: $pass passed, $fail failed ==="
    [[ "$fail" -eq 0 ]]
}

main() {
    verify_roundtrip
    if [[ "$VERIFY_ONLY" -eq 0 ]]; then
        echo ""
        run_benchmark
    fi
}

main "$@"
