load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")

def _prune_flags(flags):
    # Some flags might be used by GCC, but not understood by Clang. Other flags
    # may not be useful for ClangTidy.
    # Remove them here, to allow users to run clang-tidy, without having a
    # clang toolchain configured (that would produce a good command line with
    # --compiler clang)

    unsupported = [
        "-fno-canonical-system-headers",
        "-fstack-usage",
    ]

    unsupported_prefix = [
        "--sysroot",
    ]

    valid = lambda flag: (
        (not flag in unsupported) and
        not any([flag.startswith(prefix) for prefix in unsupported_prefix])
    )

    return [
        flag
        for flag in flags
        if valid(flag)
    ]

def _run_tidy(
        ctx,
        wrapper,
        exe,
        additional_deps,
        config,
        flags,
        compilation_context,
        infile,
        discriminator):
    exe_input = []
    if exe.files_to_run.executable:
        exe_input = [exe.files_to_run.executable] + exe.data_runfiles.files.to_list()

    inputs = depset(
        direct = (
            [infile, config] +
            additional_deps.files.to_list() +
            exe_input
        ),
        transitive = [compilation_context.headers],
    )

    args = ctx.actions.args()

    # specify the output file - twice
    outfile = ctx.actions.declare_file(
        infile.path + "." + discriminator + ".clang-tidy.yaml",
    )

    # this is consumed by the wrapper script
    if len(exe.files.to_list()) == 0:
        args.add("clang-tidy")
    else:
        args.add(exe.files_to_run.executable)

    args.add(outfile.path)  # this is consumed by the wrapper script

    args.add(config.path)

    args.add("--export-fixes", outfile.path)

    # add source to check
    args.add(infile.path)

    # start args passed to the compiler
    args.add("--")

    # add args specified by the toolchain, on the command line and rule copts
    args.add_all(_prune_flags(flags))

    # add defines
    for define in compilation_context.defines.to_list():
        args.add("-D" + define)

    for define in compilation_context.local_defines.to_list():
        args.add("-D" + define)

    # add includes
    for i in compilation_context.framework_includes.to_list():
        args.add("-F" + i)

    for i in compilation_context.includes.to_list():
        args.add("-I" + i)

    args.add_all(
        compilation_context.quote_includes.to_list(),
        before_each = "-iquote",
    )

    args.add_all(
        compilation_context.system_includes.to_list(),
        before_each = "-isystem",
    )

    ctx.actions.run(
        inputs = inputs,
        outputs = [outfile],
        executable = wrapper,
        arguments = [args],
        mnemonic = "ClangTidy",
        use_default_shell_env = True,
        progress_message = "Run clang-tidy on {}".format(infile.short_path),
    )
    return outfile

def _rule_sources(ctx):
    srcs = []
    if hasattr(ctx.rule.attr, "srcs"):
        for src in ctx.rule.attr.srcs:
            srcs += [src for src in src.files.to_list() if src.is_source]
    return srcs

def _toolchain_flags(ctx):
    cc_toolchain = find_cpp_toolchain(ctx)

    system_includes = [
        "-isystem" + include_dir
        for include_dir in cc_toolchain.built_in_include_directories
    ]

    # Clang C++ standard library headers must be found first:
    # https://github.com/llvm/llvm-project/commit/8cedff10a18d8eba9190a645626fa6a509c1f139
    #
    # We expect to find directories such as:
    # include/c++/v1
    # include/x86_64-unknown-linux-gnu/c++/v1
    # lib/clang/16/include
    # lib/clang/16/share
    top = []
    bot = []
    for inc in system_includes:
        if "lib/clang/" in inc or "c++/v1" in inc:
            top.append(inc)
        else:
            bot.append(inc)
    system_includes = top + bot

    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
    )
    compile_variables = cc_common.create_compile_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        user_compile_flags = ctx.fragments.cpp.cxxopts + ctx.fragments.cpp.copts,
    )
    return system_includes + cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = "c++-compile",  # tools/build_defs/cc/action_names.bzl CPP_COMPILE_ACTION_NAME
        variables = compile_variables,
    )

def _clang_tidy_aspect_impl(target, ctx):
    # if not a C/C++ target, we are not interested
    if not CcInfo in target:
        return []

    wrapper = ctx.attr._clang_tidy_wrapper.files_to_run
    exe = ctx.attr._clang_tidy_executable
    additional_deps = ctx.attr._clang_tidy_additional_deps
    config = ctx.attr._clang_tidy_config.files.to_list()[0]
    flags = _toolchain_flags(ctx) + getattr(ctx.rule.attr, "copts", [])
    compilation_context = target[CcInfo].compilation_context

    outputs = [
        _run_tidy(
            ctx,
            wrapper,
            exe,
            additional_deps,
            config,
            flags,
            compilation_context,
            src,
            target.label.name,
        )
        for src in _rule_sources(ctx)
    ]

    return [
        OutputGroupInfo(report = depset(direct = outputs)),
    ]

def make_clang_tidy_aspect(binary = None, config = None):
    return aspect(
        implementation = _clang_tidy_aspect_impl,
        fragments = ["cpp"],
        attrs = {
            "_cc_toolchain": attr.label(default = Label("@bazel_tools//tools/cpp:current_cc_toolchain")),
            "_clang_tidy_wrapper": attr.label(default = Label("//clang_tidy:clang_tidy")),
            "_clang_tidy_executable": attr.label(default = Label(binary or "//:clang_tidy_executable")),
            "_clang_tidy_additional_deps": attr.label(default = Label("//:clang_tidy_additional_deps")),
            "_clang_tidy_config": attr.label(default = Label(config or "//:clang_tidy_config")),
        },
        toolchains = ["@bazel_tools//tools/cpp:toolchain_type"],
    )

clang_tidy_aspect = make_clang_tidy_aspect()
