"""
clang-tidy apply fixes rule and configurable aspect
"""

load("//clang_tidy:clang_tidy.bzl", _make_clang_tidy_aspect = "make_clang_tidy_aspect")

make_clang_tidy_aspect = _make_clang_tidy_aspect

def _clang_tidy_apply_fixes_impl(ctx):
    apply_fixes = ctx.actions.declare_file(
        "clang_tidy.{}.sh".format(ctx.attr.name),
    )

    config = ctx.attr._tidy_config.files.to_list()
    if len(config) != 1:
        fail(":config ({}) must contain a single file".format(config))

    apply_replacements = ctx.attr.apply_replacements_binary or ctx.attr._apply_replacements_binary
    tidy_binary = ctx.attr.tidy_binary or ctx.attr._tidy_binary
    tidy_config = ctx.attr.tidy_config or ctx.attr._tidy_config

    apply_bin = apply_replacements.files_to_run.executable
    apply_path = apply_bin.path if apply_bin else "clang-apply-replacements"

    # get the workspace of bazel_clang_tidy, not where this update rule is
    # defined
    workspace = ctx.attr._template.label.workspace_name

    from_string_list = lambda args: (
        "{}".format(" ".join(
            [
                "'{}'".format(arg)
                for arg in args
            ],
        ))
    )

    ctx.actions.expand_template(
        template = ctx.attr._template.files.to_list()[0],
        output = apply_fixes,
        substitutions = {
            "@APPLY_REPLACEMENTS_BINARY@": apply_path,
            "@TIDY_BINARY@": str(tidy_binary.label),
            "@TIDY_CONFIG@": str(tidy_config.label),
            "@WORKSPACE@": workspace,
            "@EXTRA_CONFIG_ARGS@": from_string_list(ctx.attr.extra_config_args),
        },
    )

    tidy_bin = tidy_binary.files_to_run.executable

    runfiles = ctx.runfiles(
        (
            [apply_bin] if apply_bin else [] +
            [tidy_bin] if tidy_bin else [] +
            tidy_config.files.to_list()
        ),
    )

    return [
        DefaultInfo(
            executable = apply_fixes,
            runfiles = runfiles,
        ),
        # support use of a .bazelrc config containing `--output_groups=report`
        # for example, bazel run @bazel_clang_tidy//:apply_fixes --config=clang-tidy ...
        # with
        # build:clang-tidy --aspects @bazel_clang_tidy...
        # build:clang-tidy --@bazel_clang_tidy//:clang_tidy_config=...
        # build:clang-tidy --output_groups=report
        OutputGroupInfo(report = depset(direct = [apply_fixes])),
    ]

clang_tidy_apply_fixes = rule(
    implementation = _clang_tidy_apply_fixes_impl,
    fragments = ["cpp"],
    attrs = {
        "_template": attr.label(default = Label("//clang_tidy:apply_fixes_template")),
        "_tidy_config": attr.label(default = Label("//:clang_tidy_config")),
        "_tidy_binary": attr.label(default = Label("//:clang_tidy_executable")),
        "_apply_replacements_binary": attr.label(
            default = Label("//:clang_apply_replacements_executable"),
        ),
        "apply_replacements_binary": attr.label(
            doc = "Set clang-apply-replacements binary to use. Overrides //:clang_apply_replacements_executable.",
        ),
        "tidy_binary": attr.label(
            doc = "Set clang-tidy binary to use. Overrides //:clang_tidy_executable.",
        ),
        "tidy_config": attr.label(
            doc = "Set clang-tidy config to use. Overrides //:clang_tidy_config.",
        ),
        "extra_config_args": attr.string_list(
            doc = "Extra Bazel config arguments to pass.",
        )
    },
    toolchains = ["@bazel_tools//tools/cpp:toolchain_type"],
    executable = True,
)
