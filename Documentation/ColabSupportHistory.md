# History of Swift Support in Google Colab

In the last meeting of the original Swift for TensorFlow team (accessed from the [Open Design Meeting Notes](https://docs.google.com/document/d/1Fm56p5rV1t2Euh6WLtBFKGqI43ozC3EIjReyLk-LCLU/edit)), there was a Google Slides presentation titled ["S4TF History - The [Incomplete] Insider Edition"](https://drive.google.com/file/d/1vxSIRq7KEmrFNAV_E0Wr7Pivn728Wcvs/view). On slide 21, they announced that "Swift support in Colab will sunset over the next few weeks". The presentation occurred on February 12, which means support ended in March 2021.


![Screenshot of the last official S4TF presentation, highlighting the statement indicating an end to Swift support on Colab](./ColabSupportSunsets.png)

The official Swift support came from a built-in Jupyter kernel, cloned from [google/swift-jupyter](https://github.com/google/swift-jupyter). Based on that repository's README, Google may have pre-installed the latest custom S4TF toolchain on their Colab servers, ready to be accessed by the kernel. Once the Jupyter kernel was removed, Colab could not execute notebooks written in Swift. Instead, it attempted to run them using the Python kernel.

When Swift [came back](https://forums.swift.org/t/swift-for-tensorflow-resurrection-swift-running-on-colab-again/54158) to Colab in January 2022, it used a new Jupyter kernel written in Swift, hosted at [philipturner/swift-colab](https://github.com/philipturner/swift-colab). Fine-tuned for its primary use case (Google Colaboratory), the kernel dropped support for Docker and non-Linux platforms. Since the repository compiled itself using the downloaded toolchain, it was optimized for JIT compilation.

The initial release of Swift-Colab suffered from a long startup time because it downloaded unnecessary dependencies. In addition, it was a literal translation of the Python code in [google/swift-jupyter](https://github.com/google/swift-jupyter), with very few optimizations or changes to functionality. In April 2022, Swift-Colab was rewritten from scratch using the [philipturner/swift-colab-dev](https://github.com/philipturner/swift-colab-dev) repository.

Swift-Colab 2.0 made several enhancements to the user experience. It slashed startup time almost in half, from 54 to 31 seconds. The user could switch between the Swift kernel and the built-in Python kernel - something required for [mounting a Google Drive](https://github.com/google/swift-jupyter/issues/100) into the file system. Toolchains and package build products could be cached, allowing someone to restart a notebook without downloading anything twice. The new kernel permitted execution of `%install` directives in any notebook cell, linking Swift packages dynamically at runtime.

In the future, Swift-Colab could gain more features. As discussed on a [Swift Forums thread](https://forums.swift.org/t/violet-python-vm-written-in-swift/56945/7), Swift packages could be pre-compiled in TAR files and downloaded by the Jupyter kernel. This feature could make using S4TF easier, as it takes 3 minutes to compile under default build options. Compiled packages would be hosted in the "releases" section of the [s4tf/s4tf](https://github.com/s4tf/s4tf) repository, where development continues after Google stopped contributing.