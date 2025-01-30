# This is a template file that gets copied into a generated environment bundle
# and is used to install the bundled packages into a depot. The main goal of the
# file is to replace `{{PACKAGES}}` with the path to the bundled packages which
# cannot be known until the bundle is on the client system since it requires
# hardcoded package paths to be in the bundled registry TOMLs.
#
# This file goes hand-in-hand with the `remove.jl` script that is also copied
# into the generated environment bundle. The `remove.jl` script is used to
# reverse this script, and remove the bundled registry from the depot.

pushfirst!(LOAD_PATH, "@stdlib")
import Pkg
import TOML
popfirst!(LOAD_PATH)

function main()
    has_juliaup = !isnothing(Sys.which("juliaup"))
    has_juliaup || @warn "`juliaup` is not installed. Some functionality may be limited."

    # User configuration for installation. It is a TOML-formatted string passed
    # in to the process via an environment variable. This allows the choice of
    # environments that will be installed to be customized.
    #
    # Current keys that can be provided in this config are:
    #
    #   - `environments`: A list of environment names that should be installed.
    #     When this key is not present, all environments will be installed.
    #   - `precompile`: Should the environments be precompiled automatically?
    user_config_toml = get(ENV, "PACKAGE_BUNDLER_CONFIG", "")
    user_config = TOML.parse(user_config_toml)

    user_environments = get(user_config, "environments", nothing)
    # Installation happens either when no `environments` key is present in the
    # user configuration, or when the environment is listed in the
    # `environments`.
    should_install(env) = isnothing(user_environments) || env in user_environments

    should_precompile = get(user_config, "precompile", true)

    environments = normpath(joinpath(@__DIR__, "..", "environments"))
    packages = normpath(joinpath(@__DIR__, "..", "packages"))
    registry = normpath(joinpath(@__DIR__, "..", "registry"))

    isdir(environments) || error("`environments` not found: `$environments`.")
    isdir(packages) || error("`packages` not found: `$packages`.")
    isdir(registry) || error("`registry` not found: `$registry`.")

    isempty(DEPOT_PATH) && error("`DEPOT_PATH` is empty.")
    depot = first(DEPOT_PATH)

    registry_toml_file = joinpath(registry, "Registry.toml")
    registry_toml = TOML.parsefile(registry_toml_file)
    registry_name = registry_toml["name"]
    registry_uuid = registry_toml["uuid"]

    current_registry = joinpath(depot, "registries", registry_name)
    current_registry_remover = joinpath(current_registry, "remove.jl")
    if isfile(current_registry_remover)
        @info "Removing existing registry" current_registry
        run(`$(Base.julia_cmd()) --startup-file=no $current_registry_remover`)
    end

    # Non-standard depot locations may not have the default registries. So
    # ensure that they are installed before attempting to resolve and
    # precompile.
    if isempty(Pkg.Registry.reachable_registries())
        Pkg.Registry.add(Pkg.Registry.DEFAULT_REGISTRIES)
    end

    new_environments =
        isnothing(user_environments) ? readdir(environments) : user_environments
    depot_environments = joinpath(depot, "environments")
    isdir(depot_environments) || mkpath(depot_environments)
    current_environments = readdir(depot_environments)
    replaced_environments = intersect(new_environments, current_environments)
    if !isempty(replaced_environments)
        @warn(
            "Installing named environments, overwrites matching environments. Confirm? [Y/n]",
            replaced_environments,
            current_environments,
            new_environments,
        )
        if readline() != "Y"
            @info "Aborting installation process."
            return
        end
    end

    @info "Installing environments" new_environments
    for environment in readdir(environments; join = true)
        env_name = basename(environment)
        if isdir(environment) && should_install(env_name)
            for (root, _, files) in walkdir(environment)
                for file in files
                    src = joinpath(root, file)
                    content = read(src, String)
                    relfile = relpath(src, environment)
                    dst = joinpath(depot, "environments", env_name, relfile)
                    mkpath(dirname(dst))
                    write(dst, content)
                end
            end
        end
    end

    @info "Linking bundled packages"
    mktempdir() do temp_dir
        _, without_drive_letter = splitdrive(packages)
        path_parts = isempty(packages) ? [] : split(without_drive_letter, ('/', '\\'))
        norm_package_path = join(path_parts, "/")
        for (root, _, files) in walkdir(registry)
            for file in files
                path = joinpath(root, file)
                content = read(path, String)
                if endswith(file, ".toml")
                    content = replace(content, "{{PACKAGES}}" => norm_package_path)
                end
                if endswith(file, "remove.jl")
                    content = replace(
                        content,
                        "{{ENVIRONMENTS}}" => join(new_environments, " "),
                        "{{REGISTRY_UUID}}" => registry_uuid,
                    )
                end
                destination = normpath(joinpath(temp_dir, relpath(root, registry)))
                isdir(destination) || mkpath(destination)
                write(joinpath(destination, file), content)
            end
        end

        # Deduplicate package versions that are already available in other
        # registries. Since bundled packages retain the same UUID and version
        # numbers, but not git-tree-sha1, `Pkg` would complain if it encounters
        # duplicates. A source-available version of a package always takes
        # precedence over a bundled version, so we remove the bundled versions
        # from the registry we are about to install.
        registry_toml_file = joinpath(temp_dir, "Registry.toml")
        isfile(registry_toml_file) || error("Registry.toml not found: $registry_toml_file")
        registry_toml = TOML.parsefile(registry_toml_file)
        foreach(pairs(registry_toml["packages"])) do (pkg_uuid, pkg_info)
            pkg_uuid = Base.UUID(pkg_uuid)
            for reg in Pkg.Registry.reachable_registries()
                available_in_other_registries = String[]
                isnothing(reg.in_memory_registry) && continue
                if haskey(reg.pkgs, pkg_uuid)
                    path = reg.pkgs[pkg_uuid].path
                    versions_toml_file = join([path, "Versions.toml"], "/")
                    versions_toml = TOML.parse(reg.in_memory_registry[versions_toml_file])
                    temp_versions_toml_file = joinpath(temp_dir, versions_toml_file)
                    temp_versions_toml = TOML.parsefile(temp_versions_toml_file)
                    for version in keys(versions_toml)
                        if haskey(temp_versions_toml, version)
                            push!(available_in_other_registries, version)
                            delete!(temp_versions_toml, version)
                        end
                    end
                    open(temp_versions_toml_file, "w") do io
                        TOML.print(io, temp_versions_toml; sorted = true)
                    end
                end
                if !isempty(available_in_other_registries)
                    @info(
                        "Skipping duplicate package versions.",
                        registry = reg.name,
                        package = pkg_info["name"],
                        versions = join(available_in_other_registries, ", ", ", and "),
                    )
                end
            end
        end

        Pkg.Registry.add(Pkg.RegistrySpec(path = temp_dir))
    end

    if has_juliaup
        @info "Resolving all environments."
        environment_worklist = []
        for environment in readdir(environments)
            path = joinpath(depot, "environments", environment)
            if isdir(path)
                if should_install(environment)
                    package_bundler_toml = let file = joinpath(path, "PackageBundler.toml")
                        isfile(file) ? TOML.parsefile(file) : Dict{String,Any}()
                    end
                    juliaup_toml = get(Dict{String,Any}, package_bundler_toml, "juliaup")
                    pkg_toml = get(Dict{String,Any}, package_bundler_toml, "Pkg")
                    pin = get(pkg_toml, "pin", false)
                    custom_juliaup_channel = !isempty(juliaup_toml)
                    extra_args = get(juliaup_toml, "args", String[])
                    manifest_toml = TOML.parsefile(joinpath(path, "Manifest.toml"))
                    manifest_julia_version = manifest_toml["julia_version"]
                    julia_version = get(juliaup_toml, "channel", manifest_julia_version)
                    push!(
                        environment_worklist,
                        (;
                            path,
                            environment,
                            julia_version,
                            extra_args,
                            custom_juliaup_channel,
                            pin,
                        ),
                    )
                end
            else
                @warn "Environment not found" environment
            end
        end
        for each in environment_worklist
            julia_version = each.julia_version
            try
                run(`juliaup add $(julia_version)`)
            catch error
                @error "Failed to add Julia version via `juliaup`" julia_version error
                continue
            end

            channel = "+$(julia_version)"
            environment = "@$(each.environment)"
            try
                code = "push!(LOAD_PATH, \"@stdlib\"); import Pkg; Pkg.resolve()"
                run(
                    addenv(
                        `julia $(channel) --startup-file=no --project=$(environment) -e $code`,
                        # This stage should only resolve deps, not precompile
                        # them, since after this we may point some deps to
                        # vendored versions, which will trigger further
                        # compilation anyway.
                        "JULIA_PKG_PRECOMPILE_AUTO" => false,
                    ),
                )
            catch error
                @error "Failed to resolve environment" julia_version environment error
                continue
            end

            # When there are packages contained in `<environment>/vendored`
            # then we update the environment's manifest file to point to those
            # packages when they match any dependencies.
            let vendored_dir = joinpath(each.path, "vendored")
                if isdir(vendored_dir)
                    @info "Adding vendored dependencies."
                    manifest_file = joinpath(each.path, "Manifest.toml")
                    manifest_toml = TOML.parsefile(manifest_file)

                    for vendored_package in readdir(vendored_dir; join = true)
                        project_file = joinpath(vendored_package, "Project.toml")
                        if isfile(project_file)
                            project_toml = TOML.parsefile(project_file)
                            deps = manifest_toml["deps"]
                            package_name = project_toml["name"]
                            if haskey(deps, package_name)
                                for entry in deps[package_name]
                                    vendored_package_version =
                                        get(project_toml, "version", nothing)
                                    manifest_package_version =
                                        get(entry, "version", nothing)
                                    if vendored_package_version == manifest_package_version
                                        delete!(entry, "git-tree-sha1")
                                        entry["path"] = relpath(vendored_package, each.path)
                                    else
                                        @error(
                                            "version mismatch between vendored package version and environment",
                                            package_name,
                                            vendored_package_version,
                                            manifest_package_version,
                                        )
                                    end
                                end
                            else
                                @warn(
                                    "vendored package not found in environment",
                                    package = package_name,
                                    environment = each.environment
                                )
                            end
                        end
                    end

                    open(manifest_file, "w") do io
                        TOML.print(io, manifest_toml; sorted = true)
                    end
                end
            end

            if each.pin
                try
                    code = "push!(LOAD_PATH, \"@stdlib\"); import Pkg; Pkg.pin(; all_pkgs = true)"
                    run(
                        addenv(
                            `julia $(channel) --startup-file=no --project=$(environment) -e $code`,
                            # This stage should only resolve deps, not precompile
                            # them, since after this we may point some deps to
                            # vendored versions, which will trigger further
                            # compilation anyway.
                            "JULIA_PKG_PRECOMPILE_AUTO" => false,
                        ),
                    )
                catch error
                    @error "Failed to resolve environment" julia_version environment error
                    continue
                end
            end

            if should_precompile
                @info "Precompiling all environments."
                try
                    code = "push!(LOAD_PATH, \"@stdlib\"); import Pkg; Pkg.precompile()"
                    run(
                        `julia $(channel) --startup-file=no --project=$(environment) -e $code`,
                    )
                catch error
                    @error "Failed to precompile environment" julia_version environment error
                    continue
                end
            end

            if each.custom_juliaup_channel
                juliaup_json = joinpath(dirname(dirname(Sys.BINDIR)), "juliaup.json")
                if !isfile(juliaup_json)
                    @warn "Could not find `juliaup.json` config file. Skipping channel alias step."
                else
                    file = @__FILE__
                    cmd = `juliaup link $(each.environment) $(file) -- $(channel) --project=$(environment) $(each.extra_args...)`
                    if !success(cmd)
                        @warn "failing to run juliaup linking, rerunning with output."
                        run(cmd)
                    end
                    juliaup_json_raw = read(juliaup_json, String)
                    # `juliaup` will store the path with escaped `\`s in the json
                    # configuration. To correctly replace them with the text "julia" on
                    # Windows we need to match against the escaped version of the path.
                    escaped_file =
                        @static Sys.iswindows() ? replace(file, "\\" => "\\\\") : file
                    write(juliaup_json, replace(juliaup_json_raw, escaped_file => "julia"))
                end
            end
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
