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
    openssl = OpenSSL_jll.openssl
    cmd = Cmd(["genrsa", "-out", private, "4096"])
    run(`$openssl $cmd`)
    cmd = Cmd(["rsa", "-in", private, "-pubout"])
    write(public, readchomp(`$openssl $cmd`))

    return (; private, public)
end

function _sign_file(file, private_key)
    openssl = OpenSSL_jll.openssl
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
    openssl = OpenSSL_jll.openssl
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
