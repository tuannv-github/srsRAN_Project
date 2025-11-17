
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR=$SCRIPT_DIR/..

cd $PROJECT_DIR

mkdir build
cd build
cmake -DENABLE_DPDK=True -DASSERT_LEVEL=MINIMAL ..
make -j $(nproc)
# make test -j $(nproc)
