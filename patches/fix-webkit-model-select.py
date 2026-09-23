#!/usr/bin/env python3
"""
Fix: 0.1.6-alpha.1 -> 0.1.6-alpha.2 回归 —— WebKit（桌面端 WKWebView / Safari）下模型菜单
鼠标点选无反应、且无任何报错。

根因（已由实测确认：键盘可选中、鼠标无网络请求、控制台无异常）：
  alpha.2 新增了菜单焦点管理 + onBlur 关菜单；WebKit 在 mousedown 阶段触发 blur
  (relatedTarget 为 null) -> 菜单被 close() 卸载 -> 紧随其后的 click 落在已移除的
  元素上 -> onClick/choose() 从未执行 -> 没有请求、没有提示、没有写入。
  Chromium 时序不同，所以 Chrome 里一直正常。

本补丁做两件事：
  1) 菜单容器 onMouseDown preventDefault —— mousedown 不再转移焦点/触发 blur，
     菜单不会在 click 之前被卸载（WebKit 关键修复）。
  2) 恢复 alpha.1 的 rejected 兜底：select() 的 promise 被拒绝/抛错时，
     把状态从 "selecting" 复位为 "error" 并弹 toast —— 避免状态永久卡死导致
     所有模型行 disabled（"点了没反应"的第二重故障）。

用法：
  python3 patches/fix-webkit-model-select.py apply     # 打补丁（自动备份）
  python3 patches/fix-webkit-model-select.py verify    # 只校验是否已打
  python3 patches/fix-webkit-model-select.py revert    # 回滚到备份
"""
import sys
import shutil
import time
from pathlib import Path

TARGET = Path(
    "/Users/mi/.npm-global/lib/node_modules/@deepseek-ai/dsh/"
    "node_modules/@deepseek-ai/dsh-client-ui-model-selection/lib/client.js"
)
BACKUP = TARGET.with_suffix(".js.pre-webkit-fix")

# --- 锚点 A：菜单 portal 容器（全文件唯一） ---
ANCHOR_A = "ref: menuRef,"
INSERT_A = (
    "ref: menuRef,\n"
    "\t\t\t\t\t\tonMouseDown: (event) => {\n"
    "\t\t\t\t\t\t\tevent.preventDefault();\n"
    "\t\t\t\t\t\t},"
)

# --- 锚点 B：两处 choose/chooseEffort 的裸 .then（alpha.2 移除了 rejected 兜底） ---
ANCHOR_B = "select(selection).then(settleSelection);"
REPLACEMENT_B = (
    "select(selection).then(settleSelection, (error) => {\n"
    "\t\t\t\t\tconst message = error && error.message ? error.message : String(error);\n"
    "\t\t\t\t\tdirectory.update((s) => {\n"
    "\t\t\t\t\t\ts.status = \"error\";\n"
    "\t\t\t\t\t\ts.error = message;\n"
    "\t\t\t\t\t});\n"
    "\t\t\t\t\ttoastSeq.current += 1;\n"
    "\t\t\t\t\tsetToast({\n"
    "\t\t\t\t\t\tseq: toastSeq.current,\n"
    "\t\t\t\t\t\ttext: t(\"error.action\", { message })\n"
    "\t\t\t\t\t});\n"
    "\t\t\t\t});"
)

MARK_A = "onMouseDown: (event) => {"
MARK_B = "then(settleSelection, (error) => {"


def fail(msg: str) -> None:
    print(f"[FAIL] {msg}")
    sys.exit(1)


def apply() -> None:
    if not TARGET.exists():
        fail(f"target not found: {TARGET}")
    src = TARGET.read_text(encoding="utf-8")

    if MARK_A in src and src.count(MARK_B) >= 2:
        print("[OK] 已经打过补丁，无需重复。")
        return

    if src.count(ANCHOR_A) != 1:
        fail(f"锚点 A 命中 {src.count(ANCHOR_A)} 次（期望 1 次），版本可能已变，请人工确认")
    if src.count(ANCHOR_B) != 2:
        fail(f"锚点 B 命中 {src.count(ANCHOR_B)} 次（期望 2 次），版本可能已变，请人工确认")

    if not BACKUP.exists():
        shutil.copy2(TARGET, BACKUP)
        print(f"[备份] {BACKUP}")
    else:
        print(f"[备份] 已存在，沿用: {BACKUP}")

    out = src.replace(ANCHOR_A, INSERT_A, 1)
    out = out.replace(ANCHOR_B, REPLACEMENT_B)

    if MARK_A not in out or out.count(MARK_B) < 2:
        fail("补丁未正确写入")

    tmp = TARGET.with_suffix(".js.tmp")
    tmp.write_text(out, encoding="utf-8")
    tmp.replace(TARGET)
    print(f"[应用] {TARGET}")
    print(f"[信息] 原文件 {len(src)} 字节 -> 新文件 {len(out)} 字节")
    print("[下一步] 在桌面端按 ⌘R 刷新页面（或重启 App），然后用鼠标点模型验证。")


def verify() -> None:
    src = TARGET.read_text(encoding="utf-8")
    a = MARK_A in src
    b = src.count(MARK_B) >= 2
    print(f"[{'OK' if a else 'NO'}] 锚点 A（onMouseDown 防 blur 卸载）")
    print(f"[{'OK' if b else 'NO'}] 锚点 B（rejected 兜底 + 状态复位） x{src.count(MARK_B)}")
    sys.exit(0 if (a and b) else 1)


def revert() -> None:
    if not BACKUP.exists():
        fail(f"没有备份: {BACKUP}")
    shutil.copy2(BACKUP, TARGET)
    print(f"[回滚] 已还原 {TARGET}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "apply"
    commands = {"apply": apply, "verify": verify, "revert": revert}
    if cmd not in commands:
        fail(f"unknown command: {cmd} (use apply|verify|revert)")
    commands[cmd]()
