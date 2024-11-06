using Test

import LocalRegistry
import PackageBundler
import TOML
import Pkg

if get(ENV, "CI", "false") == "true"
    @info "Running in CI"
    run(`git config --global user.email "test@example.com"`)
    run(`git config --global user.name "test"`)
end

function with_temp_depot(f)
    orginal = deepcopy(DEPOT_PATH)
    empty!(DEPOT_PATH)
    try
        mktempdir() do temp_depot
            pushfirst!(DEPOT_PATH, temp_depot)
            Pkg.Registry.add(Pkg.Registry.DEFAULT_REGISTRIES)
            f()
        end
    finally
        empty!(DEPOT_PATH)
        append!(DEPOT_PATH, orginal)
    end
end

function with_pkg_server(f; server = "pkg.julialang.org")
    original = get(ENV, "JULIA_PKG_SERVER", nothing)
    ENV["JULIA_PKG_SERVER"] = server
    Pkg.UPDATED_REGISTRY_THIS_SESSION[] = true
    try
        f()
    finally
        ENV["JULIA_PKG_SERVER"] = original
    end
end

function with_testdir(f::Function)
    mktempdir() do testdir
        f(testdir)
    end
end

# Windows requires file:/// while Unix requires file:// prefixes for the `git`
# commands to work correctly.
function local_url(path::AbstractString)
    prefix = "file://"
    return @static Sys.iswindows() ? "$(prefix)/$(path)" : "$(prefix)$(path)"
end

function prepare_package(packages_dir::String, project_dir::String)
    project_file = joinpath(project_dir, "Project.toml")
    project_data = TOML.parsefile(project_file)
    name = project_data["name"]
    version = project_data["version"]

    package_dir = joinpath(packages_dir, name)
    repo = local_url(package_dir)
    mkpath(joinpath(package_dir, "src"))

    git = LocalRegistry.gitcmd(package_dir, TEST_GITCONFIG)
    if !isdir(joinpath(package_dir, ".git"))
        run(`$(git) init -q`)
        run(`$git remote add origin $repo`)
    end

    write(joinpath(package_dir, "Project.toml"), read(project_file, String))

    entry_point = joinpath("src", "$(name).jl")
    write(
        joinpath(package_dir, entry_point),
        read(joinpath(project_dir, entry_point), String),
    )

    run(`$git add --all`)
    commit_message = "Version $(version)"
    run(`$git commit -qm $(commit_message)`)

    return nothing
end

TEST_GITCONFIG = Dict(
    "user.name" => "PackageBundlerTests",
    "user.email" => "package-bundler-tests@example.com",
)

function with_empty_registry(f::Function)
    with_testdir() do testdir
        with_pkg_server() do
            with_temp_depot() do
                upstream_dir = joinpath(testdir, "upstream_registry")
                mkpath(upstream_dir)
                upstream_git = LocalRegistry.gitcmd(upstream_dir, TEST_GITCONFIG)
                run(`$upstream_git init -q --bare`)

                downstream_dir = joinpath(testdir, "PackageBundlerTestRegistry")
                repo = local_url(upstream_dir)
                LocalRegistry.create_registry(
                    downstream_dir,
                    repo;
                    push = true,
                    gitconfig = TEST_GITCONFIG,
                )
                Pkg.Registry.add(Pkg.Registry.RegistrySpec(; url = repo))

                packages_dir = joinpath(testdir, "packages")

                f(downstream_dir, packages_dir)
            end
        end
    end
end

@testset "PackageBundler" begin
    with_empty_registry() do registry_dir, packages_dir
        # Register our test package at two different versions:
        for version in ["0.1.0", "0.2.0"]
            prepare_package(
                packages_dir,
                joinpath(@__DIR__, "packages", "TestPackage", version),
            )
            LocalRegistry.register(
                joinpath(packages_dir, "TestPackage");
                registry = registry_dir,
                gitconfig = TEST_GITCONFIG,
                push = true,
            )
        end
        # Note: We have to update the registry to make the new packages
        # available.
        Pkg.Registry.update()

        @testset "Registry Consistency" begin
            reg = nothing
            regs = Pkg.Registry.reachable_registries()
            for r in regs
                if r.name == "PackageBundlerTestRegistry"
                    reg = r
                    break
                end
            end
            @test !isnothing(reg)

            @test length(reg.pkgs) == 1
            pkg_entry = reg.pkgs[Base.UUID("8346427c-08d3-4941-a1ec-6285c85e2ad6")]
            @test pkg_entry.name == "TestPackage"

            test_package_tomls = joinpath(reg.path, "T", "TestPackage")
            @test isdir(test_package_tomls)
            versions_file = joinpath(test_package_tomls, "Versions.toml")
            @test isfile(versions_file)
            versions = TOML.parsefile(versions_file)
            @test keys(versions) == Set(["0.1.0", "0.2.0"])
        end

        # Manifest files aren't committed to the repo for the environments
        # listed in the `environments` directory. These are the environments
        # that we will bundled. Before we begin bundling them we need to
        # instantiate them.
        environments_dir = joinpath(@__DIR__, "environments")
        for each_version in readdir(environments_dir)
            run(`juliaup add $each_version`)
            for project in readdir(joinpath(environments_dir, each_version); join = true)
                run(
                    addenv(
                        `julia +$each_version --startup-file=no --project=$project -e "import Pkg; Pkg.update()"`,
                        "JULIA_DEPOT_PATH" => DEPOT_PATH[1],
                    ),
                )

                # The `each_version` might not be the `julia_version`.
                manifest_toml_file = joinpath(project, "Manifest.toml")
                @test isfile(manifest_toml_file)
                manifest_toml = TOML.parsefile(manifest_toml_file)
                resolved_version = manifest_toml["julia_version"]
                run(`juliaup add $resolved_version`)

                output = readchomp(
                    addenv(
                        `julia +$each_version --startup-file=no --project=$project -e "import TestPackage; TestPackage.greet()"`,
                        "JULIA_DEPOT_PATH" => DEPOT_PATH[1],
                    ),
                )
                version = last(split(basename(project), "@"))
                @test contains(output, "Hello, $(version)!")
            end
        end

        cd(@__DIR__) do
            @testset "Package Bundling" begin
                key = PackageBundler.keypair()
                @test isfile(key.private)
                @test isfile(key.public)

                PackageBundler.bundle()
            end

            mktempdir() do isolated_depot
                @testset "Bundle Installation" begin
                    install = joinpath(
                        @__DIR__,
                        "build",
                        "LocalCustomRegistry",
                        "registry",
                        "install.jl",
                    )
                    run(
                        addenv(
                            `julia --startup-file=no $(install)`,
                            "JULIA_DEPOT_PATH" => isolated_depot,
                        ),
                    )

                    environments_dir = joinpath(isolated_depot, "environments")
                    count = 0
                    for named_environment in readdir(environments_dir)
                        if contains(named_environment, "Bundle")
                            manifest_toml_file = joinpath(
                                environments_dir,
                                named_environment,
                                "Manifest.toml",
                            )

                            @test isfile(manifest_toml_file)
                            manifest_toml = TOML.parsefile(manifest_toml_file)

                            resolved_version = manifest_toml["julia_version"]
                            named_environment = "@$named_environment"
                            output = readchomp(
                                addenv(
                                    `julia +$resolved_version --startup-file=no --project=$(named_environment) -e "import TestPackage; TestPackage.greet()"`,
                                    "JULIA_DEPOT_PATH" => isolated_depot,
                                ),
                            )

                            test_package_version =
                                manifest_toml["deps"]["TestPackage"][1]["version"]
                            @test contains(output, "Hello, $(test_package_version)!")

                            @test success(
                                addenv(
                                    `julia +$resolved_version --startup-file=no --project=$(named_environment) -e "import TestPackage; isnothing(first(functionloc(TestPackage.greet))) || exit(1)"`,
                                    "JULIA_DEPOT_PATH" => isolated_depot,
                                ),
                            )

                            count += 1
                        end
                    end
                    @test count == 6
                end
            end
        end
    end
end
