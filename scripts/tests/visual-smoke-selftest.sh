#!/bin/bash
# visual-smoke.sh 校验器自检（R12）：用合成快照 + 几何旁注驱动校验器，不启动 App。
# 正常图通过；空白文本区、空白行号栏、错误文档路径各自因对应一项失败。
exec /bin/bash "$(dirname "$0")/../visual-smoke.sh" --selftest
