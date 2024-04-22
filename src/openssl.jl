"""
    keypair(dir::AbstractString = pwd())

Generate a new RSA key pair for signing stripped packages. The private key is
saved as `key.pem` and the public key is saved as `key.pub` in the directory
specified by `dir`.

If the keys already exist they are not overwritten. A key size of 4096 bits is
used. Do not commit the private key to version control.

Reference the paths to the key in your `PackageBundler.toml` file to use them.
"""
function keypair(dir::AbstractString = pwd())
    private = joinpath(dir, "key.pem")
    public = joinpath(dir, "key.pub")
    isfile(private) && isfile(public) && return (; private, public)

    @info "Generating key pair for signing stripped packages." dir
    dir = abspath(dir)
    openssl = OpenSSL_jll.openssl()
    cmd = Cmd(["genrsa", "-out", private, "4096"])
    run(`$openssl $cmd`)
    cmd = Cmd(["rsa", "-in", private, "-pubout"])
    write(public, readchomp(`$openssl $cmd`))

    return (; private, public)
end

function print_base64_keypair(path::String)
    pri = read("$path.pem", String)
    pub = read("$path.pub", String)
    println("PRIVATE_KEY_BASE64 = \"$(Base64.base64encode(pri))\"\n")
    println("PUBLIC_KEY_BASE64 = \"$(Base64.base64encode(pub))\"\n")
end

"""
    import_keypair(;
        file="key",
        base64=true,
        private="PRIVATE_KEY_BASE64",
        public="PUBLIC_KEY_BASE64",
    )

Import a key pair from environment variables and save them to files. The private
key is saved as `\$file.pem` and the public key is saved as `\$file.pub`. The
private key is decoded from the environment variable specified by `private` and
the public key is decoded from the environment variable specified by `public`.

When not running in CI, this function does nothing.
"""
function import_keypair(;
    file::String = "key",
    base64::Bool = true,
    private::String = "PRIVATE_KEY_BASE64",
    public::String = "PUBLIC_KEY_BASE64",
)
    if get(ENV, "CI", "false") == "false"
        @warn "This function is only useful in CI."
        return nothing
    end

    pri = haskey(ENV, private) ? ENV[private] : error("Private key `$private` not found.")
    pub = haskey(ENV, public) ? ENV[public] : error("Public key `$public` not found.")

    pri = base64 ? Base64.base64decode(pri) : pri
    pub = base64 ? Base64.base64decode(pub) : pub

    private_file = "$file.pem"
    public_file = "$file.pub"

    write(private_file, pri)
    write(public_file, pub)

    atexit() do
        try
            rm(private_file, force = true)
        catch error
            @error "Failed to remove private key file." error
        end
        try
            rm(public_file, force = true)
        catch error
            @error "Failed to remove public key file." error
        end
    end

    return nothing
end

function _sign_file(file, private_key)
    openssl = OpenSSL_jll.openssl()
    cmd = Cmd([
        "dgst",
        "-sign",
        private_key,
        "-keyform",
        "PEM",
        "-sha512",
        "-out",
        "$file.sign",
        "-binary",
        file,
    ])
    run(`$openssl $cmd`)
end

function _verify_file(file, public_key)
    openssl = OpenSSL_jll.openssl()
    cmd = Cmd([
        "dgst",
        "-verify",
        public_key,
        "-keyform",
        "PEM",
        "-sha512",
        "-signature",
        "$file.sign",
        "-binary",
        file,
    ])
    run(`$openssl $cmd`)
end
