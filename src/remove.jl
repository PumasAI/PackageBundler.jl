# This is a template file that gets copied into a generated environment bundle
# and is used to remove an installed bundled registry from a depot. It goes
# hand-in-hand with the `install.jl` script that is also copied into the
# generated environment bundle.

pushfirst!(LOAD_PATH, "@stdlib")
import Pkg
import TOML
popfirst!(LOAD_PATH)

function main()
    artifacts = "{{ARTIFACTS}}"
    environments = normpath(joinpath(artifacts, "environments"))
    packages = normpath(joinpath(artifacts, "packages"))
    registry = normpath(joinpath(artifacts, "registry"))

    current_environments = joinpath(@__DIR__, "..", "..", "environments")
    environments_to_remove = readdir(environments)
    @info "Removing environments" environments_to_remove
    for environment in environments_to_remove
        current_environment = joinpath(current_environments, environment)
        if isdir(current_environment)
            try
                rm(current_environment; recursive = true)
            catch error
                @error "Failed to remove environment" environment error
            end
        else
            @warn "Environment not found" environment
        end
    end

    resistry_toml_file = joinpath(registry, "Registry.toml")
    registry_toml = TOML.parsefile(resistry_toml_file)
    registry_uuid = registry_toml["uuid"]
    Pkg.Registry.rm(Pkg.RegistrySpec(; uuid = registry_uuid))
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
