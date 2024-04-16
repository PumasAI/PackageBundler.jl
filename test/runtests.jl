using Test, TOML, PackageBundler

@testset "PackageBundler" begin
    key = PackageBundler.keypair()
    @test isfile(key.private)
    @test isfile(key.public)

    PackageBundler.bundle()

    registry_path = joinpath(@__DIR__, "build", "LocalCustomRegistry", "registry")
    @test isdir(registry_path)

    install_script = joinpath(registry_path, "install.jl")
    @test isfile(install_script)

    remove_script = joinpath(registry_path, "remove.jl")
    @test isfile(remove_script)

    artifact_toml = TOML.parsefile(
        joinpath(@__DIR__, "build", "LocalCustomRegistryArtifacts", "Artifacts.toml"),
    )
    @test artifact_toml["LocalCustomRegistry"]["download"][1]["url"] ==
          "URL_GOES_HERE/LocalCustomRegistry.tar.gz"

    mktempdir() do temp_depot
        withenv("JULIA_DEPOT_PATH" => temp_depot, "JULIA_PKG_SERVER" => "") do
            run(
                `$(Base.julia_cmd()) --startup-file=no -e 'push!(LOAD_PATH, "@stdlib"); import Pkg; Pkg.update()'`,
            )
            run(`$(Base.julia_cmd()) --startup-file=no $install_script`)
            run(
                `$(Base.julia_cmd()) --startup-file=no --project=@CustomEnv -e 'push!(LOAD_PATH, "@stdlib"); import Pkg; Pkg.resolve(); Pkg.precompile("CairoMakie")'`,
            )
            result = readchomp(
                `$(Base.julia_cmd()) --startup-file=no --project=@CustomEnv -e 'import CairoMakie; print(first(functionloc(CairoMakie.best_font, Tuple{Char})))'`,
            )
            @test result == "nothing"
        end
    end
end
