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

    new_environments = readdir(environments)
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
        if isdir(environment)
            for file in readdir(environment; join = true)
                file_name = basename(file)
                content = read(file, String)
                destination = joinpath(depot, "environments", env_name, file_name)
                mkpath(dirname(destination))
                write(destination, content)
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
        Pkg.Registry.add(Pkg.RegistrySpec(path = temp_dir))
    end

    if has_juliaup
        @info "Resolving and precompiling all environments."
        environment_worklist = []
        for environment in readdir(environments)
            path = joinpath(depot, "environments", environment)
            if isdir(path)
                manifest_toml = TOML.parsefile(joinpath(path, "Manifest.toml"))
                julia_version = manifest_toml["julia_version"]
                push!(environment_worklist, (; path, environment, julia_version))
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
                code = "push!(LOAD_PATH, \"@stdlib\"); import Pkg; Pkg.resolve(); Pkg.precompile();"
                run(`julia $(channel) --startup-file=no --project=$(environment) -e $code`)
            catch error
                @error "Failed to resolve and precompile environment" julia_version environment error
                continue
            end
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
