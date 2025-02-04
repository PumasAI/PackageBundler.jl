# `PackageBundler.jl`

*Experimental* bundling of Julia packages and environments into a single
artifact that can be installed as a custom Julia package registry by users.

## Goals

  - best user experience possible while still achieving the goals below
  - strip original source code from selected packages
  - strip out package commit history
  - strip out package source unrelated to runtime usage by end users
  - generate custom manifests that can load these bundled packages
  - allow multiple versions of the same package to be bundled
  - sign bundled packages and environments to allow verification of integrity
  - easy distribution of bundled packages
  - easy installation of bundled packages
  - native compilation of bundled packages
  - rely on existing package manager infrastructure as much as possible
  - rely on `Pkg.Registry` for adding bundled packages to user systems
  - don't bundle publicly available package artifacts, just use `Pkg`
  - minimize the bundled package size
  - declarative configuration using TOML

## Non-Goals

  - encrypting bundled source code
  - compiling to native code that is shipped in the bundles

## Usage

You can use the below code to generate a starter bundler project

```julia
import Pkg
Pkg.activate(; temp = true)
Pkg.add(; url = "https://github.com/PumasAI/PackageBundler.jl")
import PackageBundler
PackageBundler.generate("path/to/my/project")
```

This will create a new project with some starter configuration to get you
started. See below for how to configure a project manually.

Create a `PackageBundler.toml` file. This file contains the list of project
environments to bundle and the specific packages that should have their source
code stripped and bundled instead as serialized AST artifacts.

```toml
name = "MyCustomBundle"
uuid = "00000000-0000-0000-0000-000000000000"
environments = [
    "environments/one",
    "environments/two",
]
outputs = ["build/MyCustomBundle"]
key = "signing-key"

[packages]
"<uuid>" = "<package name>"
```

Next, generate a new public/private keypair with:

```julia
import PackageBundler
PackageBundler.keypair(pwd())
```

Then, generate a bundle with:

```julia
import PackageBundler
PackageBundler.bundle("PackageBundler.toml")
```
