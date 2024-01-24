# Loader script that finds the paths of all packages in the current environment
# and writes them to a TOML file which is then read back by the main package
# code during the bundling process. We run this as a completely isolated process
# to avoid having the package dependencies effect the bundled environment
# package versions.
#
# See the `_sniff_versions` function in the `PackageBundler` module for the call
# site that runs this script.

pushfirst!(LOAD_PATH, "@stdlib")
import Pkg
import Pkg.MiniProgressBars
import TOML
popfirst!(LOAD_PATH)

function main()
    Pkg.instantiate()

    # This is needed to ensure that all bundled packages are able to `require`
    # the `Serialization` package. There are other ways to make it work that
    # modify the registry content and package `Project.toml` files directly, but
    # this is the simplest way to do it. The other approaches had edge cases
    # that where `Serialization` was not located correctly.
    packages = ["Serialization"]
    @info "Adding required packages to environment" packages
    Pkg.add(packages; preserve = Pkg.PRESERVE_ALL_INSTALLED)

    output = ARGS[1]

    project = Base.active_project()
    manifest = Base.project_file_manifest_path(project)

    toml = TOML.parsefile(manifest)
    deps = toml["deps"]

    MP = MiniProgressBars
    progress = MP.MiniProgressBar(;
        header = "Loading packages:",
        color = Base.info_color(),
        max = mapreduce(length, +, values(deps)),
    )
    MP.start_progress(stdout, progress)
    data = Dict()
    for (k, v) in deps, each in v
        MP.show_progress(stdout, progress)
        pkgid = Base.PkgId(Base.UUID(each["uuid"]), k)
        Base.require(pkgid)
        progress.current += 1
        mod = Base.loaded_modules[pkgid]
        path = Base.pkgdir(mod)
        data[each["uuid"]] = Dict("path" => path, "name" => k, "uuid" => each["uuid"])
    end
    MP.end_progress(stdout, progress)

    open(output, "w") do io
        TOML.print(io, data)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
