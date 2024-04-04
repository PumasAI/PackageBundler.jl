pushfirst!(LOAD_PATH, "@stdlib")
import Serialization
import TOML
popfirst!(LOAD_PATH)

tomlfile = ARGS[1]
isfile(tomlfile) || error("missing tomlfile")
toml = TOML.parsefile(tomlfile)

function _extract_module_doc(expr::Expr, name::Symbol)
    if Meta.isexpr(expr, :macrocall, 4) && expr.args[1] == GlobalRef(Core, Symbol("@doc"))
        docs = expr.args[3]
        modexpr = expr.args[4]
        push!(modexpr.args[end].args, :(@doc $docs $name))
        return modexpr
    end
    return expr
end

function _stripcode(
    filename::AbstractString,
    julia_version::VersionNumber;
    entry_point = nothing,
    handlers::Dict,
)
    isfile(filename) || error("File not found: $filename")
    xorshift = unsafe_trunc(UInt8, length(filename))

    # Create a serialized version of the parsed code to, somewhat, obfuscate it.
    jls = "$(filename).$(julia_version).jls"
    jls_unescaped = "$(filename).\$(VERSION).jls"
    open(jls, "w") do io
        expr = Meta.parseall(read(filename, String))
        Meta.isexpr(expr, :toplevel) || error("Expected toplevel expr. $expr")

        # If we have an entry-point we need to strip the wrapper module syntax.
        if !isnothing(entry_point)
            expr = expr.args[end]

            expr = _extract_module_doc(expr, Symbol(entry_point))

            Meta.isexpr(expr, :module) ||
                error("Expected module expr for entrypoint. $expr")

            expr = expr.args[end]
            Meta.isexpr(expr, :block) ||
                error("Expected block expr in module expression. $expr")

            # Code injection handlers. For builder-provided extra code that
            # should be added to packages.
            code_injector = get(handlers, "code_injector") do
                function (filename)
                    quote
                        function __init__()
                            @debug "Loading serialized code."
                        end
                    end
                end
            end
            extra_code = :(module $(gensym())
            $(code_injector(filename))
            end)

            expr = Expr(:toplevel, expr.args..., extra_code)
        end
        # TODO: perform more aggressive obfuscation here, like renaming local
        # variables, etc. There really isn't a way to fully hide the code, a
        # determined attacker will always be able to reverse engineer it. We
        # just want to make it non-obvious.

        code_transformer = get(handlers, "code_transformer") do
            function (filename, expr)
                return expr
            end
        end
        expr = code_transformer(filename, expr)

        # Serialized expressions are expected to be wrapped in a `toplevel`.
        Meta.isexpr(expr, :toplevel) || error("Expected toplevel expr. $expr")
        buffer = IOBuffer()
        Serialization.serialize(buffer, expr)
        bytes = take!(buffer)
        write(io, xor.(bytes, xorshift))
    end

    # Create a shim file that will load the serialized code and evaluate it at
    # precompilation time. Working directory is set to the directory of the shim
    # file so that macros like `@__DIR__` and `@__FILE__` work as expected.
    open(filename, "w") do io
        isnothing(entry_point) || println(io, "module $entry_point")
        code_loader = get(handlers, "code_loader") do
            function (jls, xorshift)
                """
                cd(@__DIR__) do
                    pkgid = Base.PkgId(Base.UUID("9e88b42a-f829-5b0c-bbe9-9e923198166b"), "Serialization")
                    buffer = seekstart(IOBuffer(xor.(read(\"$(basename(jls))\"), $(repr(xorshift)))))
                    for x in Base.require(pkgid).deserialize(buffer).args
                        Core.eval(@__MODULE__, x)
                    end
                end
                """
            end
        end
        print(io, code_loader(jls_unescaped, xorshift))
        isnothing(entry_point) || println(io, "end")
    end

    return nothing
end

handlers = Dict{String,Function}()
for (key, file) in toml["handlers"]
    handlers[key] = include(file)
end

for file in toml["julia_files"]
    filename = file["filename"]
    entry_point = file["entry_point"]
    entry_point = isempty(entry_point) ? nothing : entry_point
    _stripcode(filename, VERSION; entry_point, handlers)
end
