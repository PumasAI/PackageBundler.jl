import PackageBundler

cd(@__DIR__) do
    PackageBundler.keypair()
    PackageBundler.bundle()
end
