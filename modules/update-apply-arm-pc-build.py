# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
# Build the drive's apply script FROM the shipped one, by replacing exactly one function and
# exactly one line.
#
# The rule this exists to keep: the released and shipped box version is not altered at all,
# ever - the drive gets its own version instead. So the shipped script is an input here and is
# never edited: this reads it, swaps `regen_default` for the drive's, drops the one Pi-only
# file from the candidate check, and writes a second file. The shipped file's bytes, its store path and the box version's
# images are untouched.
#
# Generated rather than copied so there is no second 182-line script to keep in step. Every
# substitution must match exactly once, and the result is checked for what matters rather
# than for whether it parses: the first version of this splice parsed fine and still did not
# work, because the drive's function was indented four spaces and Python read it as a function
# nested inside the one before it — main() could never reach it. So the result's module-level
# functions must be exactly the shipped script's, regen_default among them.
import ast
import sys

box_path, pc_func_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
box = open(box_path).read()
pc_func = open(pc_func_path).read()

lines = box.split("\n")
start = end = None
for i, line in enumerate(lines):
    if line.strip().startswith("def regen_default("):
        if start is not None:
            sys.exit("found 'def regen_default(' more than once in the shipped script")
        start = i
    if start is not None and line.strip() == "def main():":
        end = i
        break
if start is None or end is None:
    sys.exit("could not find regen_default ... def main() in the shipped script")
if not pc_func.startswith("def regen_default("):
    sys.exit("the drive's function must start at column 0 with 'def regen_default('")

before = "\n".join(lines[:start])
after = "\n".join(lines[end:])

# main() lists what a candidate's system folder must contain. `dtbs` is the Pi's device
# trees; an x86-64 system has none, so the shipped list would refuse every drive candidate
# before the boot file was even looked at ("update image incomplete (dtbs)").
PI_LIST = '        for n in ("init", "kernel", "initrd", "kernel-params", "dtbs"):'
PC_LIST = '        for n in ("init", "kernel", "initrd", "kernel-params"):'
if after.count(PI_LIST) != 1:
    sys.exit("expected the candidate file list exactly once after regen_default, found %d"
             % after.count(PI_LIST))
after_pc = after.replace(PI_LIST, PC_LIST)

result = before + "\n" + pc_func.rstrip("\n") + "\n\n" + after_pc

# Outside the function, the result must equal the shipped script except for that one line.
if result == box:
    sys.exit("the substitution changed nothing — the drive's function is the shipped one?")
if not result.startswith(before + "\n"):
    sys.exit("the substitution changed something before regen_default")
if not result.endswith(after_pc) or after_pc.replace(PC_LIST, PI_LIST, 1) != after:
    sys.exit("the substitution changed something after regen_default beyond the file list")

# What matters: the drive's script defines the same top-level functions the shipped one does,
# so main() finds regen_default where it calls it.
def top_level(src):
    return [n.name for n in ast.parse(src).body if isinstance(n, ast.FunctionDef)]
want, got = top_level(box), top_level(result)
if got != want:
    sys.exit("module-level functions differ: shipped %s, drive's %s" % (want, got))
if "regen_default" not in got:
    sys.exit("regen_default is not a module-level function in the drive's script")

print("swapped regen_default: shipped %d lines, drive's %d lines; dropped dtbs from the "
      "candidate check; module-level functions unchanged: %s"
      % (end - start, pc_func.rstrip("\n").count("\n") + 1, ", ".join(got)))
open(out_path, "w").write(result)
