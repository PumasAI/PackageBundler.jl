# Implementation.

struct PackageWorkItem
    package_path::String
    temp_dir::String
    julia_files::Vector{Dict{String,Any}}
    package_name::String
    version::String
    project_toml::Dict{String,Any}
    output_dir::String
end

function _generate_stripped_bundle(;
    root_dir::AbstractString,
    project_dirs::Union{AbstractString,Vector{String}},
    output_dir::AbstractString,
    stripped::Dict{String,String},
    registries::Dict{String,String},
    name::AbstractString,
    uuid::Union{AbstractString,Integer,Base.UUID},
    key_pair::@NamedTuple{private::String, public::String},
    handlers::Dict,
    multiplexers::Vector{String},
    arch::Union{Symbol,Nothing} = nothing,
    arch_explicit::Bool = false,
)
    output_dir = abspath(output_dir)

    # Phase 1: Collect work items grouped by Julia version.
    work_by_version = Dict{String,Vector{PackageWorkItem}}()
    project_dirs = vcat(project_dirs)
    for project_dir in project_dirs
        project_dir = abspath(project_dir)

        julia_version, items = _process_project_env(;
            root_dir = root_dir,
            project_dir = project_dir,
            output_dir = output_dir,
            stripped = stripped,
            registries = registries,
            key_pair = key_pair,
            multiplexers = multiplexers,
            arch = arch,
            arch_explicit = arch_explicit,
        )

        append!(get!(Vector{PackageWorkItem}, work_by_version, julia_version), items)
    end

    # Phase 2: Execute batch serialization per Julia version.
    pkg_version_info = Dict{String,Any}()
    for (julia_version, items) in work_by_version
        new_pkg_version_info = _execute_batch_serialization(
            julia_version,
            items,
            key_pair,
            handlers,
            multiplexers,
            arch,
        )
        for (k, v) in new_pkg_version_info
            current_pkg_version_info = get!(Dict{String,Any}, pkg_version_info, k)
            pkg_version_info[k] = merge(current_pkg_version_info, v)
        end
    end

    # We then merge each of these versioned directories into a single
    # git-tracked repo with the correct ordering of stripped package versions.
    @info "Committing stripped packages to new git repositories."
    for versions in values(pkg_version_info)
        mktempdir() do temp_dir
            paths_to_remove = Set{String}()
            cd(temp_dir) do
                gitcmd = "git"

                if isdir(".git")
                    error("Unreachable reached, this shouldn't be a git repo already.")
                else
                    run(`$gitcmd init`)
                    run(`$gitcmd config user.name "PackageBundler"`)
                    run(`$gitcmd config user.email ""`)
                    run(`$gitcmd config core.autocrlf false`)
                end

                # Ensure that the versions are sorted first before committing,
                # otherwise commit order will not be chronological.
                for version in sort!(collect(keys(versions)); by = VersionNumber)
                    pkg_info = versions[version]
                    path = pkg_info["path"]
                    push!(paths_to_remove, dirname(path))
                    version = pkg_info["project"]["version"]

                    # Between each version that we include we make sure that all
                    # files from the previous version are removed first (except
                    # for the `.git`) otherwise we can end up with serialized
                    # files for versions of `julia` that are not valid for the
                    # version of the package that is serialized.
                    for item in readdir(temp_dir)
                        item in (".git",) && continue
                        rm(joinpath(temp_dir, item); recursive = true, force = true)
                    end
                    # Next we copy over the new files.
                    for item in readdir(path)
                        cp(joinpath(path, item), joinpath(temp_dir, item); force = true)
                    end
                    run(`$gitcmd add .`)
                    msg = "Set version to $version"
                    run(Cmd([gitcmd, "commit", "-m", msg]))
                    run(Cmd([gitcmd, "tag", "-a", "v$version", "-m", msg]))

                    # Interestingly, using `tree_hash` failed on Windows with a
                    # `git object <commit> could not be found` error when attempting to
                    # clone the stripped packages. It would appear that the tree hash
                    # doesn't match what it should be on that platform, whereas it works
                    # correctly on macOS and Linux, both locally and on GitHub runners.
                    #
                    # ```
                    # sha = bytes2hex(Pkg.GitTools.tree_hash(temp_dir))
                    # ```
                    #
                    # To get around this we use the `rev-parse` and `^{tree}` to get the
                    # "real" tree hash.
                    rev = readchomp(`$gitcmd rev-parse HEAD`)
                    sha = readchomp(Cmd([gitcmd, "rev-parse", "$rev^{tree}"]))
                    pkg_info["git-tree-sha1"] = sha
                end
                run(`$gitcmd log`)
            end
            stripped_package_path = only(paths_to_remove)
            rm(stripped_package_path; recursive = true)
            cp(temp_dir, stripped_package_path; force = true)
        end
    end

    _generate_stripped_registry(;
        output_dir = output_dir,
        name = name,
        uuid = uuid,
        pkg_version_info = pkg_version_info,
    )
end

function _generate_stripped_registry(;
    output_dir::AbstractString,
    name::AbstractString,
    uuid::Union{AbstractString,Integer,Base.UUID},
    clean::Bool = false,
    create::Bool = true,
    pkg_version_info::Dict = Dict(),
)
    output_dir = abspath(output_dir)

    uuid = isa(uuid, Base.UUID) ? uuid : Base.UUID(uuid)

    Base.is_valid_identifier(name) ||
        error("Invalid registry name: $(repr(name)). Valid Julia identifiers are required.")

    packages = Dict()
    registry_toml = Dict(
        "name" => name,
        "uuid" => string(uuid),
        "description" => "Stripped readonly registry.",
        "packages" => packages,
    )
    registry_contents = Dict("Registry.toml" => registry_toml)

    registries = Pkg.Registry.reachable_registries()
    registry_info = Dict()
    for (package_name, versions) in pkg_version_info
        for (version, pkg_info) in versions
            package_uuid_str = pkg_info["project"]["uuid"]
            package_uuid = Base.UUID(package_uuid_str)
            tree_hash = pkg_info["git-tree-sha1"]

            found = false
            for reg in registries
                if haskey(reg, package_uuid)
                    info = get!(() -> _process_reg_info(reg), registry_info, reg.uuid)
                    pkg_entry = reg[package_uuid]
                    pkg_path = pkg_entry.path

                    # Package versions may be split across multiple registries
                    # if they have been migrated from closed source to open, for
                    # example. We verify that the registry we're currently
                    # looking through has the package version that we want.
                    if haskey(
                        get(Dict{String,Any}, get(Dict, info, pkg_path), "Versions.toml"),
                        version,
                    )
                        if found
                            error(
                                "Package version found in multiple registries: $package_name $uuid",
                            )
                        end

                        found = true

                        stripped_info = get!(Dict, registry_contents, pkg_path)
                        for (k, v) in info[pkg_path]
                            k == "Versions.toml" && continue
                            stripped_info[k] = v
                        end

                        versions_toml =
                            get!(Dict{String,Any}, stripped_info, "Versions.toml")
                        versions_toml[version] =
                            Dict{String,Any}("git-tree-sha1" => tree_hash)

                        project_toml = get!(Dict{String,Any}, stripped_info, "Package.toml")
                        project_toml["repo"] = "{{PACKAGES}}/$package_name"

                        packages[string(package_uuid)] =
                            Dict("name" => pkg_entry.name, "path" => pkg_path)
                    end
                end
            end
            if !found
                error("Package not found in any registry: $package_name $uuid")
            end
        end
    end

    stripped_registry = joinpath(output_dir, "registry")
    if clean && isdir(stripped_registry)
        rm(stripped_registry; recursive = true)
    end
    create && _write_stripped_registry(stripped_registry, registry_contents)

    return nothing
end

function _packages_from_registries(registries::Dict{String,String})
    packages = Dict{String,String}()
    isempty(registries) && packages

    for reg in Pkg.Registry.reachable_registries()
        if haskey(registries, string(reg.uuid))
            expected_name = registries[string(reg.uuid)]
            if reg.name != expected_name
                error("Registry name mismatch: $(reg.name), $expected_name")
            end
            for pkg in values(reg.pkgs)
                packages[string(pkg.uuid)] = pkg.name
            end
        end
    end
    return packages
end

function _write_stripped_registry(stripped_registry, registry_contents)
    isdir(stripped_registry) || mkpath(stripped_registry)

    cd(stripped_registry) do
        for (path, data) in registry_contents
            if endswith(path, ".toml")
                mkpath(dirname(path))
                open(path, "w") do io
                    TOML.print(io, data)
                end
            else
                mkpath(path)
                for (k, v) in data
                    if endswith(k, ".toml")
                        open(joinpath(path, k), "w") do io
                            TOML.print(io, v; sorted = true)
                        end
                    else
                        error("Unknown file type: $k")
                    end
                end
            end
        end
        install = read(joinpath(@__DIR__, "install.jl"), String)
        write("install.jl", install)
        remove = read(joinpath(@__DIR__, "remove.jl"), String)
        write("remove.jl", remove)
    end
end

function _process_reg_info(reg)
    dict = Dict()

    # Potentially is `nothing`.
    mem = reg.in_memory_registry
    if isnothing(mem)
        for (root, _, files) in walkdir(reg.path)
            for file in files
                file in ("Registry.toml", "Project.toml") && continue
                _, ext = splitext(file)
                if ext == ".toml"
                    fullpath = joinpath(root, file)
                    parts = splitpath(relpath(fullpath, reg.path))
                    path = join(parts[1:end-1], '/')
                    file = parts[end]
                    pkg = get!(Dict, dict, path)
                    pkg[file] = TOML.parsefile(fullpath)
                end
            end
        end
    else
        for key in keys(reg.in_memory_registry)
            key == "Registry.toml" && continue

            parts = split(key, '/')
            path = join(parts[1:end-1], '/')
            file = parts[end]

            path == ".ci" && continue
            file == "Project.toml" && continue

            if endswith(file, ".toml")
                pkg = get!(Dict, dict, path)
                pkg[file] = TOML.parse(reg.in_memory_registry[key])
            end
        end
    end

    # Filter out folders that don't have a `Package.toml` file since those are
    # not package folders.
    for (k, v) in dict
        if !haskey(v, "Package.toml")
            delete!(dict, k)
        end
    end

    return dict
end

function _process_reg_info_uuid_mapping(reg)
    dict = _process_reg_info(reg)
    output = Dict()
    for each in values(dict)
        uuid = each["Package.toml"]["uuid"]
        output[uuid] = each
    end
    return output
end

function _process_project_env(;
    root_dir::AbstractString,
    project_dir::AbstractString,
    output_dir::AbstractString,
    stripped::Dict{String,String},
    registries::Dict{String,String},
    key_pair::@NamedTuple{private::String, public::String},
    multiplexers::Vector{String},
    arch::Union{Symbol,Nothing} = nothing,
    arch_explicit::Bool = false
)
    project_dir = normpath(project_dir)
    output_dir = normpath(output_dir)

    isdir(output_dir) || mkpath(output_dir)

    project_dir = abspath(project_dir)
    isdir(project_dir) || error("Project directory does not exist: $project_dir")

    project_toml = joinpath(project_dir, "Project.toml")
    isfile(project_toml) || error("Project file not found: $project_toml")

    manifest_toml = joinpath(project_dir, "Manifest.toml")
    isfile(manifest_toml) || error("Manifest file not found: $manifest_toml")

    rel_project_path = relpath(project_dir, root_dir)
    project_path_parts = splitpath(rel_project_path)[2:end]
    name = join(project_path_parts, "_")
    isnothing(_match_env_name(name)) && error("Invalid environment name: $(repr(name))")

    environments = joinpath(output_dir, "environments")
    isdir(environments) || mkpath(environments)
    named_environment = joinpath(environments, name)
    cp(project_dir, named_environment; force = true)
    _package_version_locking!(joinpath(environments, name))
    _sign_file(joinpath(named_environment, "Project.toml"), key_pair.private)
    _sign_file(joinpath(named_environment, "Manifest.toml"), key_pair.private)
    write(joinpath(named_environment, basename(key_pair.public)), read(key_pair.public))

    package_paths = _sniff_versions(project_dir, multiplexers, arch)

    packagebundler_file = joinpath(project_dir, "PackageBundler.toml")
    packagebundler_toml =
        isfile(packagebundler_file) ? TOML.parsefile(packagebundler_file) :
        Dict{String,Any}()
    julia_version = TOML.parsefile(manifest_toml)["julia_version"]
    julia_version =
        get(get(Dict{String,Any}, packagebundler_toml, "juliaup"), "channel", julia_version)
    if arch_explicit
        packagebundler_toml = merge(packagebundler_toml, Dict(
            "juliaup" => Dict(
                "channel" => _juliaup_channel(julia_version, arch)
            )
        ))
        open(joinpath(named_environment, "PackageBundler.toml"), "w") do io
            TOML.print(io, packagebundler_toml)
        end
    end

    work_items = PackageWorkItem[]
    for (each_uuid, each_name) in stripped
        if haskey(package_paths, each_uuid)
            if package_paths[each_uuid]["name"] != each_name
                error("mismatched package names $each_name")
            end
            registry = package_paths[each_uuid]["registry"]
            if isempty(registries) || haskey(registries, registry)
                item = _prepare_package_for_stripping(
                    package_paths[each_uuid]["path"],
                    output_dir,
                    key_pair,
                )
                push!(work_items, item)
            end
        end
    end

    return julia_version, work_items
end

# Environment package version sniffer. Returns data of the form:
#
# Dict("<uuid>" => Dict(
#     "name" => "<name>",
#     "uuid" => "<uuid>",
#     "path" => "<path>",
#     "version" => "<version>",
#     "registry" => "<registry>",
#     "julia_version" => v"<version>"
# ))
#
function _sniff_versions(environment::AbstractString, multiplexers, arch::Union{Symbol,Nothing} = nothing)
    registries = Dict(
        reg.uuid => _process_reg_info_uuid_mapping(reg) for
        reg in Pkg.Registry.reachable_registries()
    )
    project = Base.env_project_file(environment)
    env = Pkg.Types.EnvCache(project)
    stdlib_path = _get_stdlib_path(env, environment, multiplexers, arch)
    output = Dict{String,Dict{String,Any}}()
    for (uuid, entry) in env.manifest.deps
        name = "$(entry.name)"
        path = nothing
        if entry.tree_hash === nothing
            # It's a stdlib, search for it there:
            candidate = joinpath(stdlib_path, name)
            if isdir(candidate)
                path = candidate
            else
                error("failed to find $entry")
            end
        else
            # Search for the package in all depots:
            slug = Base.version_slug(uuid, entry.tree_hash)
            for depot in Pkg.depots()
                candidate = joinpath(depot, "packages", name, slug)
                if isdir(candidate)
                    path = candidate
                    break
                end
            end
        end
        if isnothing(path)
            error("failed to find $entry")
        else
            # Find out which registry the package is in with the version that we
            # are looking for.
            registry = nothing
            for (reg, registry_info) in registries
                if haskey(registry_info, "$uuid")
                    versions = registry_info["$uuid"]["Versions.toml"]
                    if haskey(versions, "$(entry.version)")
                        registry = "$reg"
                        break
                    end
                end
            end
            output["$uuid"] = Dict(
                "name" => name,
                "uuid" => "$uuid",
                "path" => path,
                "version" => entry.version,
                "registry" => registry,
                "julia_version" => env.manifest.julia_version,
            )
        end
    end
    _check_required_deps(output; environment)
    return output
end

function _get_stdlib_path(env, environment, multiplexers, arch::Union{Symbol,Nothing} = nothing)
    toml_file = joinpath(environment, "PackageBundler.toml")
    toml = isfile(toml_file) ? TOML.parsefile(toml_file) : Dict()
    juliaup = get(Dict, toml, "juliaup")
    channel = get(juliaup, "channel", nothing)
    version = something(channel, env.manifest.julia_version)
    julia_bin = _process_multiplexers(multiplexers, version, arch)
    return read(
        `$julia_bin --startup-file=no -e 'import Pkg; print(Pkg.stdlib_dir())'`,
        String,
    )
end

# Dependencies that are required for functioning of the bundled code.
function _check_required_deps(deps; environment)
    required_deps = Dict("Serialization" => "9e88b42a-f829-5b0c-bbe9-9e923198166b")
    for (name, uuid) in required_deps
        entry = get(Dict{String,String}, deps, uuid)
        get(entry, "name", nothing) == name ||
            error("`$name` dependency missing from env: $(environment)")
    end
end

_match_env_name(name::AbstractString) = match(r"^[a-zA-Z0-9][a-zA-Z0-9_\-\.\+~@]+$", name)

# In the stripped version of the environments that we want to distribute we
# replace the UUIDs of the packages that we stripped with their stripped
# versions. This is done in the `Project.toml` and `Manifest.toml` files.  The
# project hash is also updated to reflect the changes in that file.
function _env_uuid_replacement!(env_dir::AbstractString, uuids::Dict{String,String})
    project_file = joinpath(env_dir, "Project.toml")
    isfile(project_file) || error("Project file not found: $project_file")

    project_toml = _replace_uuids(TOML.parsefile(project_file), uuids)
    open(project_file, "w") do io
        TOML.print(io, project_toml; sorted = true)
    end

    manifest_file = joinpath(env_dir, "Manifest.toml")
    isfile(manifest_file) || error("Manifest file not found: $manifest_file")

    manifest_toml = _replace_uuids(TOML.parsefile(manifest_file), uuids)
    manifest_toml["project_hash"] = _project_resolve_hash(project_file)

    open(manifest_file, "w") do io
        TOML.print(io, manifest_toml; sorted = true)
    end

    return nothing
end

function _project_resolve_hash(toml::Dict)
    project = Pkg.Types.Project(toml)
    return Pkg.Types.project_resolve_hash(project)
end
_project_resolve_hash(toml::AbstractString) = _project_resolve_hash(TOML.parsefile(toml))

# Take an environment and lock the package versions to the exact versions that
# are currently installed in the environment. This is done by adding a `compat`
# field to the `Project.toml` file. An `extras` field is also added to the since
# just adding a `compat` field will cause the resolver to complain about missing
# package names it doesn't have a UUID for.
function _package_version_locking!(environment)
    manifest_file = joinpath(environment, "Manifest.toml")
    isfile(manifest_file) || error("Manifest file not found: $manifest_file")
    manifest_toml = TOML.parsefile(manifest_file)

    project_file = joinpath(environment, "Project.toml")
    isfile(project_file) || error("Project file not found: $project_file")
    project_toml = TOML.parsefile(project_file)

    compat = get!(Dict{String,Any}, project_toml, "compat")
    delete!(project_toml, "compat")
    extras = get(Dict{String,Any}, project_toml, "extras")
    delete!(project_toml, "extras")

    for (name, deps) in manifest_toml["deps"]
        deps = only(deps)
        version = VersionNumber(get(deps, "version", manifest_toml["julia_version"]))

        # Build numbers have to be stripped otherwise the resolver complains so
        # only include the x.y.z for the `=` compat.
        eq_version = "= $(version.major).$(version.minor).$(version.patch)"
        # If there isn't a version number then it means it is an unversioned
        # stdlib and so we need to add the `< 0.0.1,` part to avoid resolver
        # failures.
        compat[name] = haskey(deps, "version") ? eq_version : "< 0.0.1, $eq_version"

        if !haskey(project_toml["deps"], name)
            extras[name] = deps["uuid"]
        end
    end
    compat["julia"] = "= $(manifest_toml["julia_version"])"

    open(project_file, "w") do io
        TOML.print(io, project_toml; sorted = true)
        println(io)
        TOML.print(io, Dict("extras" => extras, "compat" => compat); sorted = true)
    end

    # We've changed the contents of the `Project.toml` file so we need to
    # recompute the project hash that is stored in the `Manifest.toml` file.
    manifest_toml["project_hash"] = _project_resolve_hash(project_file)

    open(manifest_file, "w") do io
        TOML.print(io, manifest_toml; sorted = true)
    end

    return nothing
end

# Entire package source code stripping.

function _prepare_package_for_stripping(
    package::AbstractString,
    output::AbstractString,
    key_pair::@NamedTuple{private::String, public::String},
)
    package = abspath(package)
    output = abspath(output)

    # Create temp directory that persists until batch execution completes.
    temp = mktempdir(; cleanup = false)

    # Remove the readonly permissions from the package so that we can copy
    # it and strip code from it.
    for (root, _, files) in walkdir(package)
        for file in files
            content = read(joinpath(root, file))
            path = joinpath(replace(root, package => temp), file)
            mkpath(dirname(path))
            write(path, content)
        end
    end

    # Remove the `.git` folder, since we are generating a new git repo
    # instead and we do not want to include the git history of the package.
    git_path = joinpath(temp, ".git")
    isdir(git_path) && rm(git_path; recursive = true)

    # Sign Project.toml and copy public key.
    project = joinpath(temp, "Project.toml")
    isfile(project) || error("Project file not found: $project")
    toml = TOML.parsefile(project)
    open(project, "w") do io
        TOML.print(io, toml; sorted = true)
    end
    _sign_file(project, key_pair.private)
    write(joinpath(temp, basename(key_pair.public)), read(key_pair.public))

    version = toml["version"]
    package_name = toml["name"]
    entry_point = joinpath(temp, "src", "$package_name.jl")

    # Capture all the files that we want to serialize.
    julia_files = Dict{String,Any}[]
    function _add_to_code_stripping_list!(filename; entry_point = nothing)
        push!(
            julia_files,
            Dict("filename" => filename, "entry_point" => something(entry_point, "")),
        )
    end

    _add_to_code_stripping_list!(entry_point; entry_point = package_name)

    # Collect all other files in src/.
    src = joinpath(temp, "src")
    for (root, _, files) in walkdir(src)
        for file in files
            path = joinpath(root, file)
            if endswith(file, ".jl") && path != entry_point
                _add_to_code_stripping_list!(path)
            end
        end
    end

    # Strip extension code as well.
    ext = joinpath(temp, "ext")
    if isdir(ext)
        extensions = get(Dict{String,Any}, toml, "extensions")
        maybe_entry_point = Dict{String,String}()
        for ext_name in keys(extensions)
            maybe_entry_point[joinpath(ext, "$ext_name.jl")] = ext_name
            maybe_entry_point[joinpath(ext, "$ext_name", "$ext_name.jl")] = ext_name
        end
        for (root, _, files) in walkdir(ext)
            for file in files
                path = joinpath(root, file)
                if endswith(file, ".jl")
                    entry_point = get(maybe_entry_point, path, nothing)
                    _add_to_code_stripping_list!(path; entry_point)
                end
            end
        end
    end

    return PackageWorkItem(package, temp, julia_files, package_name, version, toml, output)
end

function _execute_batch_serialization(
    julia_version::Union{String,VersionNumber},
    items::Vector{PackageWorkItem},
    key_pair::@NamedTuple{private::String, public::String},
    handlers::Dict,
    multiplexers::Vector{String},
    arch::Union{Symbol,Nothing} = nothing,
)
    @info "Stripping source code." arch julia_version n_packages = length(items)

    # Build batch payload with all packages for this Julia version.
    packages_payload = [
        Dict(
            "package_name" => item.package_name,
            "package_version" => item.version,
            "temp_directory" => item.temp_dir,
            "julia_files" => item.julia_files,
        ) for item in items
    ]

    payload = Dict(
        "private_key" => key_pair.private,
        "public_key" => key_pair.public,
        "handlers" => handlers,
        "packages" => packages_payload,
    )

    try
        mktempdir() do toml_temp
            toml_file = joinpath(toml_temp, "payload.toml")
            open(toml_file, "w") do io
                TOML.print(io, payload)
            end
            script = joinpath(@__DIR__, "serializer.jl")
            binary = _process_multiplexers(multiplexers, julia_version, arch)
            run(`$(binary) --startup-file=no $(script) $(toml_file)`)
        end

        # Sign and copy all packages to output.
        pkg_version_info = Dict{String,Any}()
        for item in items
            # Sign all files created during serialization.
            for (root, _, files) in walkdir(item.temp_dir)
                for file in files
                    if endswith(file, ".jl") || endswith(file, ".jls")
                        _sign_file(joinpath(root, file), key_pair.private)
                    end
                end
            end

            # Copy to output directory.
            package_dir = joinpath(item.output_dir, "packages", item.package_name, item.version)
            isdir(package_dir) || mkpath(package_dir)

            for (root, _, files) in walkdir(item.temp_dir)
                for file in files
                    src_file = joinpath(root, file)
                    dst_file = joinpath(package_dir, relpath(root, item.temp_dir), file)
                    if isfile(dst_file) && read(src_file) != read(dst_file)
                        error("identical file paths, mismatched content: $src_file $dst_file")
                    end
                    dst_dir = dirname(dst_file)
                    isdir(dst_dir) || mkpath(dst_dir)
                    write(dst_file, read(src_file))
                end
            end

            # Build result info.
            versions = get!(Dict{String,Any}, pkg_version_info, item.package_name)
            versions[item.version] = Dict("path" => package_dir, "project" => item.project_toml)
        end

        return pkg_version_info
    finally
        # Clean up temp directories.
        for item in items
            rm(item.temp_dir; recursive = true, force = true)
        end
    end
end

function _stripped_source_path(
    package_name::AbstractString,
    version::AbstractString,
    project_toml::AbstractString,
    source_file::AbstractString,
)
    project_root = dirname(project_toml)
    return joinpath("[bundled]", package_name, version, relpath(source_file, project_root))
end

function _process_multiplexers(
    multiplexers::Vector{String},
    julia_version::Union{String,VersionNumber},
    arch::Union{Symbol,Nothing} = nothing,
)
    for multiplexer in multiplexers
        exists = Sys.which(multiplexer)
        if !isnothing(exists)
            if multiplexer == "juliaup"
                return `julia +$(_juliaup_channel(julia_version, arch))`
            elseif multiplexer == "asdf"
                return withenv("ASDF_JULIA_VERSION" => "$(julia_version)") do
                    path = readchomp(`asdf which julia`)
                    return `$(path)`
                end
            elseif multiplexer == "mise"
                return withenv("MISE_JULIA_VERSION" => "$(julia_version)") do
                    path = readchomp(`mise which julia`)
                    return `$(path)`
                end
            else
                error("Unsupported multiplexer: $multiplexer")
            end
        end
    end
    if isempty(multiplexers)
        return Base.julia_cmd()
    else
        error("no multiplexers found: $(repr(multiplexers))")
    end
end

function _juliaup_channel(julia_version::Union{String,VersionNumber}, arch::Union{Symbol,Nothing} = nothing)
    if isnothing(arch)
        return julia_version
    end

    juliaup_arch = if arch == :i686; :x86; elseif arch == :x86_64; :x64; else arch; end
    return "$(julia_version)~$juliaup_arch"
end
