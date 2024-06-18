using Test

@testset "Remove Bundles" begin
    count = 0
    for depot in DEPOT_PATH
        path = joinpath(depot, "registries", "LocalCustomRegistry", "remove.jl")
        if isfile(path)
            run(`julia --startup-file=no $path`)
            count += 1
        end
    end
    @test count == 1
end
