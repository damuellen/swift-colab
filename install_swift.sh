#!/bin/bash
if [[ ! -d /opt/swift ]]; then
  mkdir /opt/swift
  mkdir /opt/swift/include
  mkdir /opt/swift/internal-modules
  mkdir /opt/swift/lib
  mkdir /opt/swift/packages
  mkdir /opt/swift/pipes
  mkdir /opt/swift/progress
  mkdir /opt/swift/toolchains
  touch /opt/swift/toolchains/index
  echo "swift" > /opt/swift/runtime
fi

old_IFS=$IFS
IFS='.'
read -a strarr <<< "$1"
component_count=${#strarr[*]}

if [[ $component_count -ge 2 ]]; then
  # First argument is two components separated by a period like "5.6" or three
  # components like "5.5.3".
  toolchain_type="release"
else
  IFS='-'
  read -a strarr <<< "$1"
  component_count=${#strarr[*]}

  if [[ $component_count == 3 ]]; then
    # First argument is three components in the format "YYYY-MM-DD".
    toolchain_type="snapshot"
  else
    # First argument is absent or improperly formatted.
    toolchain_type="invalid"
  fi
fi

version=$1
IFS=$old_IFS

mode="release"

cd /opt/swift
echo $mode > /opt/swift/mode

# Determine whether to reuse cached files

if [[ -e "progress/swift-version" ]]; then
  old_version=`cat "progress/swift-version"`
  
  if [[ $version == $old_version ]]; then
    using_cached_swift=true
  elif [[ -d "toolchains/$version" ]]; then
    using_cached_swift=true
    mv "toolchain" "toolchains/$old_version"
    mv "toolchains/$version" "toolchain"
    echo $version > "progress/swift-version"  
  else
    using_cached_swift=false
    mv "toolchain" "toolchains/$old_version"
  fi
else
  using_cached_swift=false
fi

if [[ $using_cached_swift == false && -e "toolchain" ]]; then
  echo "There should be no 'toolchain' folder unless using cached Swift."
  exit -1
fi

if [[ $using_cached_swift == true && ! -e "toolchain" ]]; then
  echo "There should be a 'toolchain' folder when using cached Swift."
  exit -1
fi

# Download Swift toolchain

if [[ $toolchain_type == "url" ]]; then
  swift_desc="from URL: ${1}"
else
  swift_desc=$version
fi

if [[ $using_cached_swift == true ]]; then
  echo "Using cached Swift $swift_desc"
else
  echo "Downloading Swift $swift_desc"
  
  if [[ $toolchain_type == "release" ]]; then
    branch="swift-$version-release"
    release="swift-$version-RELEASE"
  elif [[ $toolchain_type == "snapshot" ]]; then
    branch="development"
    release="swift-DEVELOPMENT-SNAPSHOT-$version-a"
  fi

  curl "https://docs.google.com/uc?export=download&id=1IBXl5TEw-eOtCp6PID0WS12O1AETQ8HZ" | tar -xz &
  
  apt install gnuplot

  cd /content
  git clone --single-branch -b RELEASE_1.1.4 https://github.com/jmcnamara/libxlsxwriter --quiet
  cd libxlsxwriter
  make
  sudo make install
  sudo ldconfig
  cd /opt/swift
  rm -rf /content/libxlsxwriter

  mv "$release-ubuntu18.04" "toolchain"

  echo $version > "progress/swift-version"
fi

export PATH="/opt/swift/toolchain/usr/bin:$PATH"

# Download Swift-Colab

if [[ $mode == "dev" || ! -e "progress/downloaded-swift-colab" ]]; then
  if [[ -d "swift-colab" ]]; then
    rm -r "swift-colab"
  fi
  
  git clone --depth 1 --branch main \
    "https://github.com/philipturner/swift-colab"
  
  swift_colab_include="/opt/swift/swift-colab/Sources/include"
  for file in $(ls $swift_colab_include)
  do
    src_path="$swift_colab_include/$file"
    dst_path="/opt/swift/include/$file"
    if [[ -e $dst_path ]]; then
      rm $dst_path
    fi
    cp $src_path $dst_path
  done
  
  touch "progress/downloaded-swift-colab"
else
  echo "Using cached Swift-Colab"
fi

# Build LLDB bindings

if [[ $mode == "dev" || ! -e "progress/lldb-compiler-version" ||
  $version != `cat "progress/lldb-compiler-version"` ]]
then
  echo "Compiling Swift LLDB bindings"
  cd swift-colab/Sources/LLDBProcess
  
  if [[ ! -d build ]]; then
    mkdir build
  fi
  cd build
  
  clang++ -Wall -O0 -I../include -c ../LLDBProcess.cpp -fpic
  clang++ -Wall -O0 -L/opt/swift/toolchain/usr/lib -shared -o \
    libLLDBProcess.so LLDBProcess.o -llldb
  
  lldb_process_link="/opt/swift/lib/libLLDBProcess.so"
  if [[ ! -L $lldb_process_link ]]; then
    ln -s "$(pwd)/libLLDBProcess.so" $lldb_process_link
  fi
  
  cd /opt/swift
  echo $version > "progress/lldb-compiler-version"
else
  echo "Using cached Swift LLDB bindings"
fi

# Build JupyterKernel

if [[ $mode == "dev" || ! -e "progress/jupyterkernel-compiler-version" ||
  $version != `cat "progress/jupyterkernel-compiler-version"` ]]
then
  echo "Compiling JupyterKernel"
  
  jupyterkernel_path="internal-modules/JupyterKernel"
  if [[ -d $jupyterkernel_path ]]; then
    echo "\
Previously compiled with a different Swift version. \
Removing existing JupyterKernel build products."
    rm -r $jupyterkernel_path
  fi
  cp -r "swift-colab/Sources/JupyterKernel" $jupyterkernel_path
  
  cd $jupyterkernel_path
  source_files=$(find $(pwd) -name '*.swift')
  
  mkdir build && cd build
  swiftc -Onone $source_files \
    -emit-module -emit-library -module-name "JupyterKernel"
  
  jupyterkernel_lib="/opt/swift/lib/libJupyterKernel.so"
  if [[ ! -L $jupyterkernel_lib ]]; then
    echo "Adding symbolic link to JupyterKernel binary"
    ln -s "$(pwd)/libJupyterKernel.so" $jupyterkernel_lib
  fi
  
  cd /opt/swift
  echo $version > "progress/jupyterkernel-compiler-version"
else
  echo "Using cached JupyterKernel library"
fi

# Overwrite Python kernel

if [[ $mode == "dev" || ! -e "progress/registered-jupyter-kernel" ]]; then
  register_kernel='
import Foundation
let libJupyterKernel = dlopen(
  "/opt/swift/lib/libJupyterKernel.so", RTLD_LAZY | RTLD_GLOBAL)!
let funcAddress = dlsym(libJupyterKernel, "JupyterKernel_registerSwiftKernel")!

let JupyterKernel_registerSwiftKernel = unsafeBitCast(
  funcAddress, to: (@convention(c) () -> Void).self)
JupyterKernel_registerSwiftKernel()
'
  echo "$register_kernel" > register_kernel.swift
  swift register_kernel.swift
  rm register_kernel.swift
  
  touch "progress/registered-jupyter-kernel"
fi

runtime=`cat "/opt/swift/runtime"`
runtime=$(echo $runtime | tr '[:upper:]' '[:lower:]')

if [[ $runtime == "swift" ]]; then
  left="$(printf '\e[0;36m=== \e[0m')"
  right="$(printf '\e[0;36m ===\e[0m')"
  top="$(printf '\e[0;36m=== ------------------------------------------------------------------------ ===\e[0m')"
  
  # Escape single quote by specifying its hex value (0x27).
  button="$(printf '\e[0;32m\x27Runtime > Restart runtime\x27\e[0m')"
  
  # Print each line separately for clarity.
  echo $top
  echo "${left}Swift-Colab overwrote the Python kernel with Swift, but Colab is still  ${right}"
  echo "${left}in Python mode. To enter Swift mode, go to ${button}. ${right}"
  echo $top
fi
