# shellcheck disable=SC2148

if [ -n "${BASH_VERSION:-}" ]; then
    _root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
elif [ -n "${ZSH_VERSION:-}" ]; then
    _root_dir="${0:a:h}"
else
    echo "dev.sh only supports bash and zsh" >&2
    return 1 2>/dev/null || exit 1
fi

source "$_root_dir/devutils/shared.sh"
source "$_root_dir/devutils/set_quilt_vars.sh"

___helium_setup_presetup() {
    local download=true
    if [ $# -eq 1 ] && [ "$1" = -c ]; then
        download=false
    elif [ $# -ne 0 ]; then
        echo "usage: he setup|presetup [-c]" >&2
        return 1
    fi

    if [ -d "$_src_dir/out" ]; then
        echo "$_src_dir/out already exists" >&2
        return
    fi

    rm -rf "$_src_dir" && mkdir -p "$_src_dir"

    fetch_sources "$download"
    mkdir -p "$_out_dir"
    cd "$_src_dir"
    python3 "$_main_repo/utils/prune_binaries.py" --keep-build-dependencies "$_src_dir" "$_main_repo/pruning.list"
    helium_resources
    write_gn_args "$_arch" dev

    python3 "$_main_repo/utils/helium_version.py" \
        --tree "$_main_repo" \
        --platform-tree "$_root_dir" \
        --chromium-tree "$_src_dir"
}

___helium_setup() {
    ___helium_setup_presetup "$@"

    "$_root_dir/devutils/update_patches.sh" merge

    cd "$_src_dir"
    quilt push -a --refresh

    gn_gen --export-compile-commands
}

___helium_reset() {
    "$_root_dir/devutils/update_patches.sh" unmerge || true
    rm "$_subs_cache" || true
    rm "$_namesubs_cache" || true
    if mv "$_src_dir" "${_src_dir}x"; then
        rm -rf "${_src_dir}x" &
    fi
}

___helium_name_substitution() {
    if [ "$1" = "nameunsub" ]; then
        python3 "$_main_repo/utils/name_substitution.py" --unsub \
            -t "$_src_dir" --backup-path "$_namesubs_cache"
    elif [ "$1" = "namesub" ]; then
        if [ -f "$_namesubs_cache" ]; then
            echo "$_namesubs_cache exists, are you sure you want to do this?" >&2
            echo "if yes, then delete the $_namesubs_cache file" >&2
            return
        fi

        python3 "$_main_repo/utils/name_substitution.py" --sub \
            -t "$_src_dir" --backup-path "$_namesubs_cache"
    else
        echo "unknown action: $1" >&2
        return
    fi
}

___helium_apply_translations() {
    python3 "$_main_repo/utils/i18n_apply.py" -t "$_src_dir"
}

___helium_generate_translations() {
    python3 "$_main_repo/devutils/i18n.py" generate
}

___helium_substitution() {
    if [ "$1" = "unsub" ]; then
        python3 "$_main_repo/utils/domain_substitution.py" revert \
            -c "$_subs_cache" "$_src_dir"

        ___helium_name_substitution nameunsub
    elif [ "$1" = "sub" ]; then
        if [ -f "$_subs_cache" ]; then
            echo "$_subs_cache exists, are you sure you want to do this?" >&2
            echo "if yes, then delete the $_subs_cache file" >&2
            return
        fi

        ___helium_name_substitution namesub

        python3 "$_main_repo/utils/domain_substitution.py" apply \
            -r "$_main_repo/domain_regex.list" \
            -f "$_main_repo/domain_substitution.list" \
            -c "$_subs_cache" \
            "$_src_dir"
    else
        echo "unknown action: $1" >&2
        return
    fi
}

___helium_build() {
    local -a siso_flags=(${=SISO_FLAGS:-})
    cd "$_src_dir"
    if [ -n "${SISO_REAPI_ADDRESS:-}" ]; then
        configure_siso || return
    fi
    helium_build -k 0 "${siso_flags[@]}" "$@"
}

___helium_run() {
    local profile="$HOME/.config/net.imput.helium.dev"
    # .git is a file in linked worktrees, and a directory in the main checkout
    if [ -f "$_root_dir/.git" ]; then
        profile="$profile.wt/${_root_dir#*.wt/}"
    fi

    cd "$_src_dir" && ./out/Default/helium \
    --user-data-dir="$profile" \
    --enable-ui-devtools=$RANDOM \
    "$@"
}

___helium_wt_path() {
    local common
    common=$(git -C "$_root_dir" rev-parse --path-format=absolute --git-common-dir)
    echo "$(dirname "$common").wt/$1"
}

___helium_wt_can_reflink() {
    local probe="$1/.reflink-probe.$$"
    cp --reflink=always "$_src_dir/buildtools/linux64/gn" "$probe" 2>/dev/null || return 1
    rm -f "$probe"
}

___helium_wt_new() {
    local copy=false name dest
    if [ "${1:-}" = --copy ]; then
        copy=true
        shift
    fi

    name=${1:?usage: he wt new [--copy] <name>}
    dest=$(___helium_wt_path "$name")
    if [ ! -f "$_root_dir/patches/series.merged" ] || [ ! -d "$_src_dir/.pc" ]; then
        echo "$_src_dir must be set up with merged patches applied" >&2
        return 1
    fi

    if git -C "$_root_dir" rev-parse -q --verify "refs/heads/$name" >/dev/null \
        || git -C "$_main_repo" rev-parse -q --verify "refs/heads/$name" >/dev/null; then
        echo "branch $name already exists" >&2
        return 1
    fi

    mkdir -p "$(dirname "$dest")"
    if [ "$copy" = false ] && ! ___helium_wt_can_reflink "$(dirname "$dest")"; then
        echo "$(dirname "$dest") doesn't support reflinks, so $_src_dir would be copied in full" >&2
        echo "use 'he wt new --copy $name' to do that anyway" >&2
        return 1
    fi

    git -C "$_root_dir" worktree add -b "$name" "$dest" HEAD
    git -C "$_main_repo" worktree add -b "$name" "$dest/helium-chromium" HEAD

    git -C "$_root_dir" diff --binary HEAD -- . ":!patches" ":!helium-chromium" \
        | git -C "$dest" apply --allow-empty
    git -C "$_main_repo" diff --binary HEAD -- . ":!patches" \
        | git -C "$dest/helium-chromium" apply --allow-empty

    rm -rf "$dest/patches"
    cp -a --reflink=auto "$_root_dir/patches" "$dest/patches"

    mkdir -p "$dest/build"
    ln -s "$_dl_cache" "$dest/build/download_cache"
    cp -a --reflink=auto "$_src_dir" "$dest/build/src"
    for f in "$_subs_cache" "$_namesubs_cache"; do
        [ ! -f "$f" ] || cp -a --reflink=auto "$f" "$dest/build/"
    done

    printf '%s\n' "$dest/patches" > "$dest/build/src/.pc/.quilt_patches"
    (cd "$dest" && . scripts/dev.sh && gn_gen)
}

___helium_wt_rm() {
    local dest
    dest=$(___helium_wt_path "${1:?usage: he wt rm <name>}")
    [ -f "$dest/.git" ] || { echo "$dest is not a worktree" >&2; return 1; }
    rm -rf "$dest/build"
    git -C "$_main_repo" worktree remove --force "$dest/helium-chromium" || true
    git -C "$_root_dir" worktree remove --force "$dest"
}

___helium_wt() {
    case "${1:-}" in
        new) shift; ___helium_wt_new "$@";;
        rm) shift; ___helium_wt_rm "$@";;
        ls) git -C "$_root_dir" worktree list;;
        *)
            echo "usage: he wt <new [--copy] <name>|rm <name>|ls>" >&2
            return 1
    esac
}

___helium_pull() {

    if [ -f "$_subs_cache" ]; then
        echo "source files are substituted, please run 'he unsub' first" >&2
        return 1
    fi

    cd "$_src_dir" && quilt pop -a || true
    "$_root_dir/devutils/update_patches.sh" unmerge || true

    for dir in "$_root_dir" "$_main_repo"; do
        git -C "$dir" stash \
        && git -C "$dir" fetch \
        && git -C "$dir" rebase origin/main \
        && git -C "$dir" stash pop \
        || true
    done

    "$_root_dir/devutils/update_patches.sh" merge
    cd "$_src_dir" && quilt push -a --refresh
}

___helium_patches_merge() {
    "$_root_dir/devutils/update_patches.sh" merge
}

___helium_patches_unmerge() {
    "$_root_dir/devutils/update_patches.sh" unmerge
}

___helium_quilt_push() {
    cd "$_src_dir" && quilt push -a --refresh
}

___helium_quilt_pop() {
    cd "$_src_dir" && quilt pop -a
}

___helium_validate() {
    if [ "$1" = "config" ]; then
        python3 "$_main_repo/devutils/validate_config.py"
    elif [ "$1" = "patches" ]; then
        if [ ! -f "patches/series.merged" ]; then
            echo "patches/series.merged doesn't exist. did you forget to merge?" >&2
            return 1
        fi
        python3 "$_main_repo/devutils/validate_patches.py" \
            -l "$_src_dir" \
            -s patches/series.merged
    elif [ "$1" = "series" ]; then
        "$_root_dir/devutils/check_patch_files.sh"
    else
        echo "unknown validate action. usage: he validate <config|patches|series>" >&2
    fi
}

___helium_format() {
    cd "$_src_dir"
    quilt diff | "$_src_dir/third_party/clang-format/script/clang-format-diff.py" \
    -p1 -i -style=file
}

___helium_find_tidy_diff() {
    if [ -n "$_tidy_diff_script" ]; then
        return
    elif command -v clang-tidy-diff >/dev/null 2>&1; then
        _tidy_diff_script=$(command -v clang-tidy-diff)
    elif command -v clang-tidy-diff.py >/dev/null 2>&1; then
        _tidy_diff_script=$(command -v clang-tidy-diff.py)
    else
        _tidy_diff_script=$(find /opt/homebrew/Cellar/llvm -name clang-tidy-diff.py | head -1)
    fi

    if [ -z "$_tidy_diff_script" ]; then
        echo "could not find clang-tidy-diff.py script." >&2
        echo "ensure that you have llvm installed on your system" >&2
        return 1
    fi
}

___helium_strip_compile_commands() {
    _ccmd_path="$_out_dir/compile_commands.json"
    [ "$_ccmd_stripped" = 1 ] && return;
    _ccmd_stripped=1

    echo "normalizing compile_commands.json, this will take a while..."
    cp "$_ccmd_path" "$_ccmd_path.orig";
    gsed -Ei 's/^(\s*"command": ").*?\s(\S+bin\/clang)/\1\2/g' "$_ccmd_path"
}

___helium_tidy() {
    ___helium_find_tidy_diff || return;
    ___helium_strip_compile_commands;
    quilt diff | "$_tidy_diff_script" \
        -regex '.*\.(cc|mm)' \
        -use-color \
        -p1 \
        -path "$_out_dir" \
        -quiet \
        -j$(nproc)
}

___helium_lint() {
    ___helium_format;
    ___helium_tidy;
}

___helium_menu() {
    set -e
    case $1 in
        setup) shift; ___helium_setup "$@";;
        presetup) shift; ___helium_setup_presetup "$@";;
        configure) gn_gen --export-compile-commands;;
        resources) helium_resources;;

        sub|unsub) ___helium_substitution "$1";;
        namesub|nameunsub) ___helium_name_substitution "$1";;
        translate) ___helium_apply_translations;;
        transgen) ___helium_generate_translations;;

        merge) ___helium_patches_merge;;
        unmerge) ___helium_patches_unmerge;;
        push) ___helium_quilt_push;;
        pop) ___helium_quilt_pop;;
        pull) ___helium_pull;;

        validate) ___helium_validate "$2";;
        format) ___helium_format;;
        tidy) ___helium_tidy;;
        lint) ___helium_lint;;

        build) shift; ___helium_build "$@";;
        run) shift; ___helium_run "$@";;
        reset) ___helium_reset;;
        wt) shift; ___helium_wt "$@";;
        *)
            printf 'usage: he <command>\n' >&2
            printf '\tsetup [-c] - sets up the dev environment, optionally cloning Chromium\n' >&2
            printf '\t         equivalent of: [presetup, merge, push, configure]\n' >&2
            printf '\tpresetup [-c] - prepares sources and dependencies, optionally cloning Chromium\n' >&2
            printf '\tconfigure - generates build configuration and tools\n' >&2
            printf '\tresources - generates and copies helium resources (such as icons)\n' >&2

            printf '\n\n' >&2
            printf '\tsub - apply google domain and name substitutions\n' >&2
            printf '\tunsub - undo google domain and name substitutions\n' >&2
            printf '\tnamesub - apply only name substitutions\n' >&2
            printf '\tnameunsub - undo only name substitutions\n' >&2
            printf '\ttranslate - apply translations from i18n directory\n' >&2
            printf '\ttransgen - generate source strings for translation\n' >&2

            printf '\n\n' >&2
            printf '\tmerge - merges all patches\n' >&2
            printf '\tunmerge - unmerges all patches\n' >&2
            printf '\tpush - applies all patches\n' >&2
            printf '\tpop - undoes all patches\n' >&2
            printf '\tpull - undoes all patches, pulls from git, redoes all patches\n' >&2

            printf '\n\n' >&2
            printf '\tvalidate config - validates the build configuration\n' >&2
            printf '\tvalidate patches - validates that patches are applied correctly\n' >&2
            printf '\tvalidate series - checks the consistency of the series file\n' >&2
            printf '\tformat - formats the topmost patch according to Chromium coding style\n' >&2
            printf '\ttidy - runs clang-tidy on the topmost patch\n' >&2
            printf '\tlint - he format + he tidy\n' >&2

            printf '\n\n' >&2
            printf '\tbuild - builds a development binary\n' >&2
            printf '\trun [args] - runs a development build of helium with dev data dir & ui devtools enabled\n' >&2
            printf '\treset - nukes everything\n' >&2

            printf '\n\n' >&2
            printf '\twt new <name> - creates a worktree with an APFS clone of the current source tree\n' >&2
            printf '\twt rm <name> - removes a worktree and its source tree, keeping its branches\n' >&2
            printf '\twt ls - lists worktrees\n' >&2
    esac
}

he() {
    (___helium_menu "$@")
}

if ! (return 0 2>/dev/null); then
    printf "usage:\n\t$ source dev.sh\n\t$ he\n" 2>&1
    exit 1
else
    if [ "${__helium_loaded:-}" = "" ]; then
        __helium_loaded=1
        PS1="🎈 $PS1"
    fi
fi
