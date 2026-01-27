using PackageBundler
using Test

@testset "code_stripping" begin
    @testset "_ensure_binary_gitattributes!" begin
        mktempdir() do dir
            # Initialize git repo
            git = `git -C $dir`
            run(`$git init -q`)
            run(`$git config user.name "PackageBundler"`)
            run(`$git config user.email ""`)
            # Force autocrlf to true to simulate Windows behavior where text files are normalized
            if Sys.iswindows()
                run(`$git config core.autocrlf true`)
                foreign_newline = "\n"
            else
                run(`$git config core.autocrlf input`)
                foreign_newline = "\r\n"
            end

            # Create content that looks like text to git (no null bytes) but has
            # line endings that would be normalized if treated as text.
            content_jls = Vector{UInt8}("binary$(foreign_newline)content$(foreign_newline)")
            content_sign = Vector{UInt8}("signature$(foreign_newline)content$(foreign_newline)")

            write(joinpath(dir, "test.jls"), content_jls)
            write(joinpath(dir, "test.jls.sign"), content_sign)

            # Ensure attributes are set
            PackageBundler._ensure_binary_gitattributes!(dir)

            # Commit files
            run(`$git add .`)
            run(`$git commit -q -m "Add binary files"`)

            # Delete files and checkout to force git to restore them
            rm(joinpath(dir, "test.jls"))
            rm(joinpath(dir, "test.jls.sign"))
            run(`$git checkout -q .`)

            # Verify content is identical (no EOL conversion occurred)
            @test read(joinpath(dir, "test.jls")) == content_jls
            @test read(joinpath(dir, "test.jls.sign")) == content_sign
        end
    end
end
