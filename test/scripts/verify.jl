using Test
import Pkg
import TOML

@testset "Verify Bundles" begin
    count = 0
    env_dir = joinpath(DEPOT_PATH[1], "environments")
    for named_env in readdir(env_dir)
        if contains(named_env, "Bundle")
            manifest_toml_file = joinpath(env_dir, named_env, "Manifest.toml")
            @assert isfile(manifest_toml_file)
            manifest_toml = TOML.parsefile(manifest_toml_file)
            resolved_version = manifest_toml["julia_version"]
            output = readchomp(
                `julia +$resolved_version --startup-file=no --project=@$named_env -e "import TestPackage; TestPackage.greet()"`,
            )
            package_version = manifest_toml["deps"]["TestPackage"][1]["version"]
            @test contains(output, "Hello, $(package_version)!")
            count += 1
        end
    end
    @test count == 4
end
