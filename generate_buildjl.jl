#!/usr/bin/env julia

using GitHub, BinaryBuilder, Pkg, Pkg.PlatformEngines, SHA, Pkg.BinaryPlatforms

"""
    extract_platform_key(path::AbstractString)

Given the path to a tarball, return the platform key of that tarball. If none
can be found, prints a warning and return the current platform suffix.
"""
function extract_platform_key(path::AbstractString)
    try
        return extract_name_version_platform_key(path)[3]
    catch
        @warn("Could not extract the platform key of $(path); continuing...")
        return platform_key_abi()
    end
end

"""
    extract_name_version_platform_key(path::AbstractString)

Given the path to a tarball, return the name, platform key and version of that
tarball. If any of those things cannot be found, throw an error.
"""
function extract_name_version_platform_key(path::AbstractString)
    m = match(r"^(.*?)\.v(.*?)\.([^\.\-]+-[^\.\-]+-([^\-]+-){0,2}[^\-]+).tar.gz$", basename(path))
    if m === nothing
        error("Could not parse name, platform key and version from $(path)")
    end
    name = m.captures[1]
    version = VersionNumber(m.captures[2])
    platkey = platform_key_abi(m.captures[3])
    return name, version, platkey
end

function product_hashes_from_github_release(repo_name::AbstractString, tag_name::AbstractString;
                                            verbose::Bool=true)
    # Get list of files within this release
    release = GitHub.gh_get_json(GitHub.DEFAULT_API, "/repos/$(repo_name)/releases/tags/$(tag_name)", auth=BinaryBuilder.Wizard.github_auth())

    # Try to extract the platform key from each, use that to find all tarballs
    function can_extract_platform(filename)
        # Short-circuit build.jl because that's quite often there.  :P
        if startswith(filename, "build") && endswith(filename, ".jl")
            return false
        end

        unknown_platform = typeof(extract_platform_key(filename)) <: UnknownPlatform
        if unknown_platform && verbose
            @info("Ignoring file $(filename); can't extract its platform key")
        end
        return !unknown_platform
    end
    assets = [a for a in release["assets"] if can_extract_platform(a["name"])]

    # Download each tarball, hash it, and reconstruct product_hashes.
    product_hashes = Dict()
    mktempdir() do d
        for asset in assets
            # For each asset (tarball), download it
            filepath = joinpath(d, asset["name"])
            url = asset["browser_download_url"]
            download(url, filepath)

            # Hash it
            hash = open(filepath) do file
                return bytes2hex(sha256(file))
            end

            println(compat_string_of_platform_key_abi(split(asset["name"], '.')[5]))

            # Then fit it into our product_hashes
            file_triplet = BinaryBuilder.triplet(extract_platform_key(asset["name"]))
            product_hashes[file_triplet] = (asset["name"], hash)

            if verbose
                @info("Calculated $hash for $(asset["name"])")
            end
        end
    end

    return product_hashes
end

# `repr` calls `BinaryBuilder.repr` which does not print the `prefix, `
# first argument that is needed by `BinaryProvider`.
function _repr(p::Product)
    return replace(repr(p), "(" => "(prefix, ")
end

function compat_string_of_platform_key_abi(platform)
    splited = split(platform, '-')
    if length(splited) == 3
        arch, vendor, abi = splited
        cxx = nothing
        fortran = nothing
    elseif length(splited) == 4
        arch, vendor, abi, other = splited
        if startswith(other, "cxx")
            cxx = other
            fortran = nothing
        elseif startswith(other, "libgfortran")
            cxx = nothing
            fortran = other
        end
    else
        arch, vendor, abi, fortran, cxx = splited
        @assert startswith(fortran, "libgfortran")
        @assert startswith(cxx, "cxx")
    end

    if vendor == "linux"
        result = "Linux("
    elseif vendor == "apple" && startswith(abi, "darwin")
        result = "MacOS("
    elseif vendor == "unknown" && startswith(abi, "freebsd")
        result = "FreeBSD("
    elseif vendor == "w64" && abi == "mingw32"
        result = "Windows("
    else
        error("Unknown vendor in platform '$platform'")
    end

    result *= ":$(arch)"

    if vendor == "linux"
        if abi == "gnu"
            result *= ", libc=:glibc"
        elseif abi == "musl"
            result *= ", libc=:musl"
        elseif abi == "gnueabihf"
            result *= ", libc=:glibc, call_abi=:eabihf"
        elseif abi == "musleabihf"
            result *= ", libc=:musl, call_abi=:eabihf"
        else
            error("Platform '$platform' has unknown ABI")
        end
    end

    # check for required compiler ABI
    if !(isnothing(cxx) && isnothing(fortran))
        result *= ", compiler_abi=CompilerABI("
        if fortran == "libgfortran3"
            result *= ":gcc4"
        elseif fortran == "libgfortran4"
            result *= ":gcc7"
        elseif fortran == "libgfortran5"
            result *= ":gcc8"
        else
            result *= ":gcc_any"
        end

        if !isnothing(cxx)
            result *= ", :$cxx"
        end
        result *= ")"
    end

    return result * ")"
end

function print_buildjl(io::IO, products::Vector, product_hashes::Dict,
                       bin_path::AbstractString)
    print(io, """
    using BinaryProvider # requires BinaryProvider 0.3.0 or later

    # Parse some basic command-line arguments
    const verbose = "--verbose" in ARGS
    const prefix = Prefix(get([a for a in ARGS if a != "--verbose"], 1, joinpath(@__DIR__, "usr")))
    """)

    # Print out products
    print(io, "products = [\n")
    for prod in products
        print(io, "    $(_repr(prod)),\n")
    end
    print(io, "]\n\n")

    # Print binary locations/tarball hashes
    print(io, """
    # Download binaries from hosted location
    bin_prefix = "$bin_path"

    # Listing of files generated by BinaryBuilder:
    """)

    println(io, "download_info = Dict(")
    for platform in sort(collect(keys(product_hashes)))
        fname, hash = product_hashes[platform]
        pkey = compat_string_of_platform_key_abi(platform)
        println(io, "    $(pkey) => (\"\$bin_prefix/$(fname)\", \"$(hash)\"),")
    end
    println(io, ")\n")

    print(io, """
    # Install unsatisfied or updated dependencies:
    unsatisfied = any(!satisfied(p; verbose=verbose) for p in products)
    dl_info = choose_download(download_info, platform_key_abi())
    if dl_info === nothing && unsatisfied
        # If we don't have a compatible .tar.gz to download, complain.
        # Alternatively, you could attempt to install from a separate provider,
        # build from source or something even more ambitious here.
        error("Your platform (\\\"\$(Sys.MACHINE)\\\", parsed as \\\"\$(triplet(platform_key_abi()))\\\") is not supported by this package!")
    end

    # If we have a download, and we are unsatisfied (or the version we're
    # trying to install is not itself installed) then load it up!
    if unsatisfied || !isinstalled(dl_info...; prefix=prefix)
        # Download and install binaries
        install(dl_info...; prefix=prefix, force=true, verbose=verbose)
    end

    # Write out a deps.jl file that will contain mappings for our products
    write_deps_file(joinpath(@__DIR__, "deps.jl"), products, verbose=verbose)
    """)
end



if length(ARGS) < 1 || length(ARGS) > 3
	@error("Usage: generate_buildjl.jl path/to/build_tarballs.jl [<repo_name> <tag_name>]")
    exit(1)
end

function registered_paths(ctx, uuid)
    @static if VERSION < v"1.5.0-DEV.863"
        return Pkg.Operations.registered_paths(ctx.env, uuid)
    else
        return Pkg.Operations.registered_paths(ctx, uuid)
    end
end

build_tarballs_path = ARGS[1]
@info "Build tarballs script: $(build_tarballs_path)"
src_name = basename(dirname(build_tarballs_path))
if 2 <= length(ARGS) <= 3
    repo_name = ARGS[2]
else
    repo_name = "JuliaBinaryWrappers/$(src_name)_jll.jl"
end
@info "Repo name: $(repo_name)"

if length(ARGS) == 3
    tag_name = ARGS[3]
else
    ctx = Pkg.Types.Context()
    # Force-update the registry here, since we may have pushed a new version recently
    BinaryBuilder.update_registry(ctx)
    versions = VersionNumber[]
    paths = registered_paths(ctx, BinaryBuilder.jll_uuid("$(src_name)_jll"))
    if any(p -> isfile(joinpath(p, "Package.toml")), paths)
        # Find largest version number that matches ours in the registered paths
        for path in paths
            append!(versions, Pkg.Operations.load_versions(ctx, joinpath(path, "Versions.toml")))
        end
    end
    if !isempty(versions)
        last_version = maximum(versions)
        tag_name = "$(src_name)-v$(last_version)"
    else
        @error("""Unable to determine latest version of $(src_name),
               please specify it as third argument to this script:
                   generate_buildjl.jl $(build_tarballs_path) $(repo_name) <tag_name>""")
        exit(1)
    end
end
@info "Tag name: $(tag_name)"

# First, snarf out the Product variables:
if !isfile(build_tarballs_path)
    @error("Unable to open $(build_tarballs_path)")
    exit(1)
end

m = Module(:__anon__)

# Setup anonymous module
Core.eval(m, quote
    eval(x) = $(Expr(:core, :eval))(__anon__, x)
    include(x) = $(Expr(:top, :include))(__anon__, x)
    include(mapexpr::Function, x) = $(Expr(:top, :include))(mapexpr, __anon__, x)
end)
Core.eval(m, quote
    using BinaryBuilder, Pkg.BinaryPlatforms

    # Override BinaryBuilder functionality so that it doesn't actually do anything
	# it just saves the inputs so that we can mess around with them:
	_name = nothing
	_version = nothing
	_products = nothing
    function build_tarballs(A, name, version, sources, script, platforms, products, dependencies; kwargs...)
		global _name = name
		global _version = version

        # Peel off the functionalization of Products
        if isa(products, Function)
            products = products(Prefix("."))
        end
		global _products = products
		return nothing
	end
end)
include_string(m, String(read(build_tarballs_path)))
name, version, products = Core.eval(m, quote
    _name, _version, _products
end)

product_hashes = product_hashes_from_github_release(repo_name, tag_name)

mkpath(joinpath(@__DIR__, "build"))
buildjl_path = joinpath(@__DIR__, "build", "build_$(name).v$(version).jl")
bin_path = "https://github.com/$(repo_name)/releases/download/$(tag_name)"
@info("Writing out to $(buildjl_path)")
open(buildjl_path, "w") do io
    print_buildjl(io, products, product_hashes, bin_path)
end
