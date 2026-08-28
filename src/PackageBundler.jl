module PackageBundler

# Imports.

import Artifacts
import Base64
import CodecZlib
import OpenSSL_jll
import Pkg
import SHA
import Scratch
import Serialization
import TOML
import Tar

# Public API.

"""
    bundle(config = "PackageBundler.toml"; clean = false)

Bundle a set of packages into a single readonly registry. The packages are
stripped of their source code and only the serialized version of the code is
included in the bundle. The bundled files are signed with a private key and the
public key is included in the bundle. The bundle can be verified with the public
key.

```toml
name = "PackageBundle"                        # default: "PackageBundle"
uuid = "00000000-0000-0000-0000-000000000000" # required
environments = ["env1", "env2"]               # required
outputs = "PackageBundle"                     # default: same as `name`
key = "key"                                   # default: "key"
clean = false                                 # default: false
multiplexers = ["asdf", "juliaup"]            # default: []
handlers = []                                 # default: []

[packages]
"<uuid>" = "<name>"

[registries]
"<uuid>" = "<name>"
```

The `environments` field is a list of paths to Julia environments that should be
included in the bundle as global environments. A `Project.toml` and a matching
`Manifest.toml` file must exist in each environment. `LocalPreferences.toml`
could also, if required by the environment, be included in the environment
directory. When bundled these environments will have the modifications applied
to them such that the required extra packages are available and the versions of
all packages within the environment are locked to the original version and
cannot be adjusted:

  - `Serialization` is installed into the direct dependencies of the environment.
    This is required for stripped code to be able to be loaded.
  - All packages are added to the `compat` and `extras` sections to ensure their
    versions remain fixed should an end-user add anything to the environment after
    installation.

The `packages` field provides the UUIDs and names of all packages that should be
stripped of source code and included in the bundle. They must be valid Julia
packages available in the environments listed in `environments`.

The `registries` field provides the UUIDs and names of all registries that
should be stripped of source code and included in the bundle. `packages` and
`registries` get merged together into a single list of packages to strip. The
`registries` field is useful for including entire registries in the bundle to
avoid the chance of missing any packages that are not listed in `packages`
should your dependencies change.

The `outputs` field is the target for the bundle. It can be a directory, a
tarball, or an `Artifacts.toml` file. Or it can be an array of multiple targets.
For `Artifacts.toml` files the `artifacts_url` field must be specified, which
points at the URL where the tarball can be downloaded from.

The `key` field is the name of the private and public key files. The private key
is used to sign the bundled packages and the public key is included in the
bundle. The public key is used to verify the bundle. The private key is expected
to be a PEM encoded RSA private key. The public key is expected to be a PEM
encoded RSA public key. A key size of 4096 bits is recommended. Ensure that you
do not lose the private key, it cannot be recovered.

The `clean` field is a boolean flag that determines whether the output directory
should be cleaned before generating the bundle. If `clean` is `true` and the
output directory exists it will be deleted before generating the bundle. `clean`
has no effect if the output is a tarball or an `Artifacts.toml` file.

The `multiplexers` field sets the allowed multiplexer programs to use to select
specific versions of Julia for each environment based on it's `julia_version`.
`"juliaup"`, `"asdf"`, and `"mise"` are supported. This is an ordered list of
options, each of which are tried in turn until one is found that can be used to
select the correct Julia version. If no multiplexer is found then the current
`julia` is used.

The `handlers` field is a list of paths to handler scripts that are used to
inject or transform code in the bundled packages. The handler scripts must be
valid Julia files that return a `Function` accepting the required arguments as
listed below. The valid names for handlers are:

  - `code_loader.jl`: A function that generates the `String` of code used to
    load the serialized code. Takes `filename`, `jls`, `xorshift`,
    `entry_point`, and `context` as arguments.
  - `code_transformer.jl`: A function that transforms the parsed code before it
    is serialized. Takes `filename`, `expr`, and `context` as arguments.
  - `code_injector.jl`: A function that injects extra code into the bundled
    packages. Takes `filename` and `context` as arguments.
  - `data_decoder.jl`: A function that generates the `Expr` of a `Function`
    used to decode the serialized code. Takes `filename`, `xorshift`, and
    `context` as arguments.
  - `data_encoder.jl`: A function that encodes the serialized code. Takes
    `filename`, `data`, and `context` as arguments.  
  - `post_process.jl`: A function that is called after the code is stripped from
    all files. Takes the `context` as it's argument.
"""
function bundle(
    config::AbstractString = "PackageBundler.toml";
    clean::Bool = false,
    artifacts_url::Union{String,Nothing} = nothing,
)
    config = abspath(config)
    endswith(config, ".toml") || error("Config file must be a TOML file: `$config`.")
    isfile(config) || error("Config file not found: `$config`. Is your current working directory the correct directory?")

    dir = dirname(config)

    config = TOML.parsefile(config)

    clean = get(config, "clean", clean)::Bool

    # Package environment targets to bundle.
    envs = get(Vector{String}, config, "environments")::Union{String,Vector}
    envs = String.(vcat(envs))
    envs = normpath.(joinpath.(dir, envs))
    isempty(envs) && error("No environments specified.")
    for each in envs
        isdir(each) || error("Environment directory not found: $each")

        project_toml = joinpath(each, "Project.toml")
        isfile(project_toml) || error("Project file not found: $project_toml")

        manifest_toml = joinpath(each, "Manifest.toml")
        isfile(manifest_toml) || error("Manifest file not found: $manifest_toml")
    end

    # Packages from the environments to strip source code from in the bundle.
    packages = Dict{String,String}(get(Dict, config, "packages")::Dict)

    # All packages from these registries will be stripped.
    registries = Dict{String,String}(get(Dict, config, "registries")::Dict)

    for (k, v) in _packages_from_registries(registries)
        if haskey(packages, k) && packages[k] != v
            error("Duplicate package ID with different names.")
        end
        packages[k] = v
    end
    isempty(packages) && error("No packages specified.")

    # Bundle name and bundled registry UUID.
    name = get(config, "name", "PackageBundle")::AbstractString
    uuid = get(config, "uuid", "")::AbstractString
    isempty(uuid) && error("UUID must be specified.")
    uuid = Base.UUID(uuid)

    # Public and private key pair for signing the bundled packages.
    key = get(config, "key", "key")::String
    private = normpath(joinpath(dir, "$key.pem"))
    isfile(private) || error("Private key not found: $private")
    public = normpath(joinpath(dir, "$key.pub"))
    isfile(public) || error("Public key not found: $public")

    # Output target for the bundle. Can be a directory, tarball, or
    # `Artifacts.toml` file. Default to a directory with the same name as the
    # bundle.
    outputs = get(config, "outputs", name)::Union{AbstractString,Vector}
    outputs = String.(vcat(outputs))
    outputs = isempty(outputs) ? [name] : outputs

    # Artifact URL for `Artifacts.toml` files.
    artifacts_url = get(config, "artifacts_url", artifacts_url)::Union{String,Nothing}

    # Multiplexers. The list of multiplexer programs to try to use to select
    # specific versions of Julia for each environment based on it's
    # `julia_version`.
    multiplexers = String.(get(Vector{String}, config, "multiplexers"))

    # Ensure handler scripts valid files and adjust paths to be absolute.
    handlers = Dict{String,String}()
    for file in String.(get(Vector{String}, config, "handlers"))
        file = normpath(joinpath(dir, file))
        isfile(file) || error("Handler file not found: $file")
        key = basename(first(splitext(file)))
        if key in ("code_loader", "code_transformer", "code_injector", "data_decoder", "data_encoder", "post_process")
            handlers[key] = file
        else
            error("Invalid handler key: $key")
        end
    end

    mktempdir() do temp_dir
        # Generate the bundle in a temp directory, afterwhich copy the result
        # into the required output targets.
        _generate_stripped_bundle(;
            root_dir = dir,
            project_dirs = envs,
            output_dir = temp_dir,
            stripped = packages,
            registries = registries,
            name = name,
            uuid = uuid,
            key_pair = (; private, public),
            handlers = handlers,
            multiplexers = multiplexers,
        )
        for output in outputs
            output = normpath(joinpath(dir, output))
            is_tarball = endswith(output, ".tar.gz")
            is_artifacts = endswith(output, "Artifacts.toml")
            is_directory = !is_tarball && !is_artifacts
            if is_directory
                @info "Generating directory bundle." output
                if clean && isdir(output)
                    @warn "Cleaning directory." output
                    rm(output; recursive = true)
                end
                isdir(output) || mkpath(output)
                cp(temp_dir, output; force = true)
            elseif is_tarball
                @info "Generating tarball bundle." output
                isdir(dirname(output)) || mkpath(dirname(output))
                tar_gz = open(output, write = true)
                tar = CodecZlib.GzipCompressorStream(tar_gz)
                Tar.create(temp_dir, tar)
                close(tar)
            elseif is_artifacts
                @info "Generating Artifacts.toml bundle." output
                if isnothing(artifacts_url)
                    error("`artifacts_url` must be specified for Artifacts.toml output.")
                end
                artifact_toml = joinpath(temp_dir, "Artifacts.toml")
                product_hash = Pkg.Artifacts.create_artifact() do artifact_dir
                    cp(temp_dir, artifact_dir; force = true)
                end
                artifact_name = "$name.tar.gz"
                temp_artifact = joinpath(temp_dir, artifact_name)
                download_hash = _archive_artifact(product_hash, temp_artifact)
                Pkg.Artifacts.bind_artifact!(
                    artifact_toml,
                    name,
                    product_hash,
                    force = true,
                    download_info = Tuple[("$artifacts_url/$artifact_name", download_hash)],
                )
                isdir(dirname(output)) || mkpath(dirname(output))
                cp(artifact_toml, output; force = true)
                cp(temp_artifact, joinpath(dirname(output), artifact_name); force = true)
            else
                error("Invalid output target: $output")
            end
        end
    end
end

function _archive_artifact(
    hash::Base.SHA1,
    tarball_path::String;
    honor_overrides::Bool = false,
)
    if !honor_overrides
        if Pkg.Artifacts.query_override(hash) !== nothing
            error(
                "Will not archive an overridden artifact unless `honor_overrides` is set!",
            )
        end
    end

    if !Pkg.Artifacts.artifact_exists(hash)
        error("Unable to archive artifact $(bytes2hex(hash.bytes)): does not exist!")
    end

    # Package it up
    local tar
    try
        tar_gz = open(tarball_path, write = true)
        tar = CodecZlib.GzipCompressorStream(tar_gz)
        Tar.create(Pkg.Artifacts.artifact_path(hash), tar)
    finally
        close(tar)
    end

    # Calculate its sha256 and return that
    return open(tarball_path, "r") do io
        return bytes2hex(Pkg.Artifacts.sha256(io))
    end
end

"""
    install_bundle(artifact_path::AbstractString)

Install a bundle that was generated with `bundle` into the current Julia depot.
The `artifact_path` is the path to the directory containing the bundle. The
bundle must be a directory containing `registry`, `packages`, and
`environ`environments` directories. The `registry` directory must contain a
`install.jl` script.

This will add all named `environments` in the bundle as global environments and
`Pkg.Registry.add` the bundled registry.

Use `remove_bundle` to remove the bundle from the depot and undo this operation.
"""
function install_bundle(artifact_path::AbstractString)
    install = joinpath(artifact_path, "registry", "install.jl")
    isfile(install) || error("Install script not found: $install")
    run(`$(Base.julia_cmd()) --startup-file=no $(install)`)
end

"""
    remove_bundle(registry_path::AbstractString)

Remove a bundle that was installed with `install_bundle` from the current Julia
depot. The `registry_path` is the path to the added registry directory in the
`.julia` directory. The registry directory must contain a `remove.jl` script.

This will remove all named `environments` from the depot that this bundle
installed. It will also `Pkg.Registry.rm` the bundled registry. This undoes the
effect of `install_bundle`.
"""
function remove_bundle(registry_path::AbstractString)
    remove = joinpath(registry_path, "remove.jl")
    isfile(remove) || error("Remove script not found: $remove")
    run(`$(Base.julia_cmd()) --startup-file=no $(remove)`)
end

include("openssl.jl")
include("code_stripping.jl")
include("utilities.jl")

end # module PackageBundler
