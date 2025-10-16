"""
    instantiate(environments::String)

Scan the directory `environments` for subdirectories containing a
`Manifest.toml` file and instantiate them all using the appropriate `julia`
version as specified in the `Manifest.toml` file. This uses either `juliaup` or
`asdf` to switch between `julia` versions as needed. Make sure to have either of
those installed, as well as the expected `julia` versions.
"""
function instantiate(environments::String)
    if ispath(environments)
        if isfile(environments)
            error("The path '$environments' is a file, not a directory.")
        end
    else
        error("The path '$environments' does not exist.")
    end
    for each in readdir(environments; join = true)
        manifest = joinpath(each, "Manifest.toml")
        if isfile(manifest)
            @info "Instantiating $each"
            toml = TOML.parsefile(manifest)
            julia_version = toml["julia_version"]

            # Check for a per-environment `PackageBundler.toml` file and use
            # that Juliaup channel if it exists.
            packagebundler_file = joinpath(each, "PackageBundler.toml")
            packagebundler_toml =
                isfile(packagebundler_file) ? TOML.parsefile(packagebundler_file) :
                Dict{String,Any}()
            julia_version = get(
                get(Dict{String,Any}, packagebundler_toml, "juliaup"),
                "channel",
                julia_version,
            )

            if !isnothing(Sys.which("juliaup"))
                @info "Checking whether Julia '$julia_version' is installed, if not, installing it."
                if !any(channel -> channel == julia_version, collect(first(split(l[9:end])) for l in readlines(`juliaup status`)[3:end]))
                    run(`juliaup add $julia_version`)
                end
                withenv("JULIA_PKG_PRECOMPILE_AUTO" => 0) do
                    run(
                        `julia +$(julia_version) --project=$each -e 'import Pkg; Pkg.instantiate()'`,
                    )
                end
            elseif !isnothing(Sys.which("asdf"))
                # Using the `ASDF_JULIA_VERSION` environment variable to control the
                # `julia` version used doesn't appear to have an effect. Instead
                # compute the exact path to the binary and use that instead.
                asdf_dir = get(
                    ENV,
                    "ASDF_DATA_DIR",
                    get(ENV, "ASDF_DIR", joinpath(homedir(), ".asdf")),
                )
                if isdir(asdf_dir)
                    julia_path = joinpath(
                        asdf_dir,
                        "installs",
                        "julia",
                        "$(julia_version)",
                        "bin",
                        "julia",
                    )
                    if !isfile(julia_path)
                        @info "Installing Julia '$julia_version', since it does not appear to be installed."
                        run(`asdf install julia $julia_version`)
                    end
                    if isfile(julia_path)
                        withenv("JULIA_PKG_PRECOMPILE_AUTO" => 0) do
                            run(
                                `$julia_path --project=$each -e 'import Pkg; Pkg.instantiate()'`,
                            )
                        end
                    else
                        error(
                            "The `julia` binary for version $julia_version failed to install.",
                        )
                    end
                else
                    error("`asdf` is not installed in a known location. $asdf_dir")
                end
            else
                error("`asdf` or `juliaup` is required to instantiate the environments.")
            end
        end
    end
end

function generate(
    directory::AbstractString;
    name::AbstractString = basename(directory),
    uuid::Base.UUID = Base.UUID(rand(UInt128)),
)
    Base.isidentifier(name) || error("'$name' is not valid. Must be a Julia identifier.")
    ispath(directory) && error("The path '$directory' already exists.")
    mkpath(directory)
    run(
        `$(Base.julia_cmd()) --project=$directory -e 'pushfirst!(LOAD_PATH, "@stdlib"); import Pkg; Pkg.add(; url = "https://github.com/PumasAI/PackageBundler.jl")'`,
    )
    mkpath(joinpath(directory, "environments"))
    write(
        joinpath(directory, "PackageBundler.toml"),
        """
        name = "$name"
        uuid = "$uuid"
        environments = [
            # Add your environments here.
            "environments/...",
        ]
        outputs = ["build"]
        key = "key"
        clean = true
        multiplexers = ["juliaup", "asdf"]

        # Registries that you want to strip code from.
        # [registries]

        # Packages that you want to strip code from.
        # [packages]
        """,
    )
    write(
        joinpath(directory, "bundle.jl"),
        """
        import PackageBundler
        PackageBundler.bundle(joinpath(@__DIR__, "PackageBundler.toml"))
        """,
    )
    write(
        joinpath(directory, "instantiate.jl"),
        """
        import PackageBundler
        PackageBundler.instantiate(joinpath(@__DIR__, "environments"))
        """,
    )
    write(
        joinpath(directory, ".gitignore"),
        """
        *.pem
        *.pub
        /build/
        """,
    )
end
