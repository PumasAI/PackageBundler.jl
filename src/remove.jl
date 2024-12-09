# This is a template file that gets copied into a generated environment bundle
# and is used to remove an installed bundled registry from a depot. It goes
# hand-in-hand with the `install.jl` script that is also copied into the
# generated environment bundle.

pushfirst!(LOAD_PATH, "@stdlib")
import Pkg
popfirst!(LOAD_PATH)

function main()
    current_environments = joinpath(@__DIR__, "..", "..", "environments")
    environments_to_remove = strip.(split("{{ENVIRONMENTS}}"))
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
        try
            run(`juliaup remove $(environment)`)
        catch error
            @error "Failed to remove custom channel" environment error
        end
    end
    Pkg.Registry.rm(Pkg.RegistrySpec(; uuid = "{{REGISTRY_UUID}}"))
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
