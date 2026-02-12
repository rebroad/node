export PATH=$HOME/.local/python3.8/bin:$PATH
export CC=clang-13
export CXX=clang++-13
export CFLAGS="-U__ILP32__"
export CXXFLAGS="-stdlib=libc++ -U__ILP32__"
export LDFLAGS="-stdlib=libc++ -rtlib=compiler-rt"
make -j2
