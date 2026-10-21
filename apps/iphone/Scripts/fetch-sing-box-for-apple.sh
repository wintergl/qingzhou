#!/usr/bin/env bash
set -euo pipefail
cat <<'MSG'
The optional sing-box-for-apple reference app is not a build dependency.
Qingzhou supplies its own PacketTunnel bridge; no Library.xcframework is used.
To prepare the actual pinned dependency, run from the repository root:
  apps/iphone/Scripts/build-sing-box-libbox.sh
Reference only: https://github.com/SagerNet/sing-box-for-apple
MSG
