#!/usr/bin/env bash
set -euo pipefail

bazel=$(readlink -f /proc/${PPID}/exe)

args=$(printf " union %s" "${@}" | sed 's/^ union \(.*\)/\1/')
targets="${args:-//...}"

bazel_tidy_config=(\
"--aspects=@@WORKSPACE@//clang_tidy:clang_tidy.bzl%clang_tidy_aspect" \
"--@@WORKSPACE@//:clang_tidy_executable=@TIDY_BINARY@" \
"--@@WORKSPACE@//:clang_tidy_config=@TIDY_CONFIG@" \
"--output_groups=report" \
@EXTRA_CONFIG_ARGS@)

cd $BUILD_WORKSPACE_DIRECTORY

exported_fixes=$("$bazel" aquery \
                          "mnemonic(\"ClangTidy\", kind(\"cc_.* rule\", $targets))" \
                          --noshow_progress \
                          --ui_event_filters=-info \
                          "${bazel_tidy_config[@]}" )

"$bazel" build \
         --noshow_progress \
         --ui_event_filters=-info,-error,-stdout,-stderr \
         --keep_going \
         "${bazel_tidy_config[@]}" \
         "${@:-//...}" || true

for file in $exported_fixes; do
    cat $file
    # get the build directory which is probably some sandbox
    build_dir=$(grep --max-count=1 'BuildDirectory:' "$file" \
                     | sed "s:\s\+BuildDirectory\:\s\+'\(.*\)':\1:" || true)

    # if we didn't find BuildDirectory, it's probably an empty file
    if [ -z "$build_dir" ]; then
        continue
    fi

    # relative path of a fix file copied to BUILD_WORKSPACE_DIRECTORY
    suggested_fixes=$(basename "$file")

    # strip the build_dir prefix
    # and set BuildDirectory to empty
    # so clang-apply-replacements won't look for it
    sed "s:$build_dir/::" "$file" \
        | sed "s:$build_dir::" \
        > "$suggested_fixes"
    echo suggested_fixes_after_sed:
    echo $suggested_fixes
    # resolve symlinks and relative paths
    while path=$(grep --max-count=1 'FilePath.*_virtual_includes\|FilePath.*\./' "$suggested_fixes" \
                  | sed "s:^.*\s\+FilePath\:\s\+'\(.*\)':\1:"); do
        if [ -z "$path" ]; then
            break
        fi
        
        resolved=$(readlink -f $path)
        sed -i "s:$path:$resolved:" "$suggested_fixes"
    done

    # remove the original exported fixes, otherwise they are found by
    # clang-apply-replacements
    rm -f "$file"
done

@APPLY_REPLACEMENTS_BINARY@ .
