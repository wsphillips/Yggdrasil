name = "LLVM"
llvm_full_version = v"11.0.1+0"
libllvm_version = v"11.0.1+0"

# Include common LLVM stuff
include("../common.jl")
build_tarballs(ARGS, configure_extraction(ARGS, llvm_full_version, name, libllvm_version; experimental_platforms=true, assert=true)...; skip_audit=true)