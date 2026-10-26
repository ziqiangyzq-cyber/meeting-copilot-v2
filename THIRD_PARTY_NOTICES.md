# Third-Party Notices

This repository contains application source code only. It does not include the
Qwen model weights, Python virtual environment, or third-party inference source
tree.

## Qwen3-ASR-1.7B

The local speech workflow is designed for the MLX model distribution:

- Model: `mlx-community/Qwen3-ASR-1.7B-bf16`
- Pinned revision: `e1f6c266914abc5a46e8756e02580f834a6cf8a7`
- Model card license: Apache License 2.0

Model weights are downloaded and installed separately by the user. They are not
licensed under this repository's MIT license.

## qwen3-asr-mlx reference runtime

The optional local Qwen runtime uses the separately installed
`qwen3-asr-mlx` package and reference source tree:

- Package version: `0.2.0`
- Reference revision: `7f8b420ad4188c6a2be038ba8e24d9f00cfedb72`
- License observed in the installed reference: MIT
- Copyright: 2025-2026 Soroush Yousefpour

The runtime is not included in this repository. If redistributed with a binary,
retain its MIT copyright and permission notice.

## Apple frameworks

Apple Speech, Translation, AVFoundation, Core Audio, SwiftUI, and other Apple
system frameworks are supplied by macOS and are governed by Apple's terms.
