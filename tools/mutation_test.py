#!/usr/bin/env python3
"""Generate mutants of the game rules by operator and run the tests against each.

Mutants are generated from the source, not from a hand-written list. Each
operator rewrites one site inside a function body (comments, strings, and
test blocks are skipped). A mutant is KILLED when the domain tests fail or
crash, SURVIVED when they pass, and STILLBORN when it does not compile;
stillborn mutants are left out of the score.

By default a reproducible sample is run; --all runs every mutant. Mutants
judged equivalent (no test could tell them apart) are listed by id in
tools/mutants.ignore with a reason.
"""

import argparse
import concurrent.futures
from dataclasses import dataclass
import hashlib
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import tempfile

# Files in src/core, the functional core: rules, use cases, codecs, and the journal.
TARGETS = (
    "colony.zig", "fleet.zig", "ferry.zig", "bridge.zig", "charter.zig", "roads.zig",
    "expedition.zig", "gameplay.zig", "queries.zig", "save.zig", "journal.zig",
)
# The core's own tests, then the shell's property tests that drive the core.
TEST_ROOTS = (
    ("core-tests", ["src/core/root.zig"]),
    ("shell-tests", ["--dep", "core", "-Mroot=src/shell/root.zig", "-Mcore=src/core/root.zig"]),
)


@dataclass(frozen=True)
class Mutant:
    file: str
    line: int          # 1-based, for display
    operator: str
    original: str      # the whole original line
    changed: str       # the whole mutated line, or "" for a deletion
    ident: str

    def describe(self):
        before = self.original.strip()
        after = self.changed.strip() or "(deleted)"
        return f"{self.ident}  {self.file}:{self.line}  {self.operator}\n    - {before}\n    + {after}"


# ---------------------------------------------------------------- scanning

def code_mask(text):
    """Return a copy of text with comments and string/char literals blanked,
    so operators never match inside them. Offsets are preserved."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i) or text.startswith("\\\\", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
        elif c == '"' or c == "'":
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            for k in range(i, min(j + 1, n)):
                out[k] = " "
            i = j + 1
        else:
            i += 1
    return "".join(out)


def function_lines(masked_lines):
    """Yield indexes of lines inside non-test function bodies."""
    depth = 0
    fn_depth = None      # depth at which the current function body opened
    in_test = None       # depth at which the current test block opened
    for index, line in enumerate(masked_lines):
        stripped = line.strip()
        opens_fn = re.match(r"^(pub\s+)?(inline\s+)?fn\s", stripped) is not None
        opens_test = stripped.startswith("test ") or stripped.startswith("test{")
        start_depth = depth
        depth += line.count("{") - line.count("}")
        if in_test is None and opens_test and "{" in line:
            in_test = start_depth
        if in_test is None and fn_depth is None and opens_fn and "{" in line:
            fn_depth = start_depth
            continue  # the signature line itself is not mutated
        if fn_depth is not None and in_test is None and start_depth > fn_depth:
            yield index
        if fn_depth is not None and depth <= fn_depth:
            fn_depth = None
        if in_test is not None and depth <= in_test:
            in_test = None


def _swap(mapping):
    return lambda m: mapping[m.group(0)]


# Each operator: (name, regex on comment- and string-free code, replacement).
OPERATORS = (
    ("relational", re.compile(r"(?<![<>=!])(<=|>=|<|>)(?![<>=|])"), _swap({"<": "<=", "<=": "<", ">": ">=", ">=": ">"})),
    ("equality", re.compile(r"(==|!=)"), _swap({"==": "!=", "!=": "=="})),
    ("arithmetic", re.compile(r"(?<=\s)(\+|-)(?=\s)"), _swap({"+": "-", "-": "+"})),
    ("saturating", re.compile(r"(\+\||-\|)(?!=)"), _swap({"+|": "-|", "-|": "+|"})),
    ("compound", re.compile(r"(\+\|=|-\|=|\+=|-=)"), _swap({"+=": "-=", "-=": "+=", "+|=": "-|=", "-|=": "+|="})),
    ("logical", re.compile(r"\b(and|or)\b"), _swap({"and": "or", "or": "and"})),
    ("boolean", re.compile(r"\b(true|false)\b"), _swap({"true": "false", "false": "true"})),
    ("constant", re.compile(r"(?<![\w.])(\d+)(?![\w.])"), lambda m: "0" if m.group(0) == "1" else str(int(m.group(0)) + 1)),
)

# Statements whose deletion is a meaningful mutant: assignments and calls.
DELETABLE = re.compile(
    r"^\s*(?!const |var |return\b|break\b|continue\b|defer\b|errdefer\b|try\b|if\b|else\b|for\b|while\b|switch\b|inline\b|_ = |\})"
    r"[\w.\[\]()*&]+.*;\s*$")


def generate(src_dir):
    mutants = []
    for name in TARGETS:
        text = (src_dir / name).read_text(encoding="utf-8")
        lines = text.split("\n")
        masked = code_mask(text).split("\n")
        for index in function_lines(masked):
            line, code = lines[index], masked[index]
            digest = hashlib.sha1(line.strip().encode()).hexdigest()[:8]
            for operator, pattern, replace in OPERATORS:
                for k, match in enumerate(pattern.finditer(code)):
                    if operator == "constant" and _skip_constant(code, match):
                        continue
                    changed = line[:match.start()] + replace(match) + line[match.end():]
                    if changed != line:
                        mutants.append(Mutant(name, index + 1, operator, line, changed, f"{name}:{operator}:{digest}:{k}"))
            if DELETABLE.match(code) and code.count("(") == code.count(")"):
                mutants.append(Mutant(name, index + 1, "delete", line, "", f"{name}:delete:{digest}:0"))
            negatable = re.match(r"^\s*(?:\} else )?if \(", code)
            if negatable:
                start = code.index("if (") + 3
                end = _matching_paren(code, start)
                if end is not None:
                    changed = line[:start + 1] + "!(" + line[start + 1:end] + ")" + line[end:]
                    mutants.append(Mutant(name, index + 1, "negate", line, changed, f"{name}:negate:{digest}:0"))
    # Identical lines give identical ids; number the repeats in order.
    seen = {}
    unique = []
    for m in mutants:
        count = seen.get(m.ident, 0)
        seen[m.ident] = count + 1
        unique.append(m if count == 0 else Mutant(m.file, m.line, m.operator, m.original, m.changed, f"{m.ident}#{count}"))
    return unique


def _skip_constant(code, match):
    """Skip integer widths in types and array lengths, which only fail to compile."""
    before = code[:match.start()]
    return bool(re.search(r"(\[\s*$|\b[ui]$)", before))


def _matching_paren(code, open_index):
    depth = 0
    for i in range(open_index, len(code)):
        if code[i] == "(":
            depth += 1
        elif code[i] == ")":
            depth -= 1
            if depth == 0:
                return i
    return None


# ---------------------------------------------------------------- running

def run_case(source, zig, timeout, mutant):
    with tempfile.TemporaryDirectory(prefix="archipelagist-mutation-") as scratch:
        work = Path(scratch)
        shutil.copytree(source, work / "src")
        if mutant:
            path = work / "src" / "core" / mutant.file
            lines = path.read_text(encoding="utf-8").split("\n")
            if lines[mutant.line - 1] != mutant.original:
                return "ERROR", "Mutant site not found in the snapshot."
            if mutant.changed:
                lines[mutant.line - 1] = mutant.changed
            else:
                del lines[mutant.line - 1]
            path.write_text("\n".join(lines), encoding="utf-8")
        try:
            for name, args in TEST_ROOTS:
                binary = work / name
                build = subprocess.run(
                    [zig, "test", "-OReleaseSafe", "--test-no-exec", f"-femit-bin={binary}", *args],
                    cwd=work, text=True, capture_output=True, timeout=timeout,
                )
                if build.returncode:
                    return ("STILLBORN" if mutant else "ERROR"), build.stdout + build.stderr
                test = subprocess.run([str(binary)], cwd=work, text=True, capture_output=True, timeout=timeout)
                if test.returncode:
                    break
        except subprocess.TimeoutExpired:
            return ("KILLED" if mutant else "ERROR"), "timed out"
        except OSError as exc:
            return "ERROR", str(exc)
    output = test.stdout + test.stderr
    if test.returncode == 0:
        return ("SURVIVED" if mutant else "PASS"), output
    return ("KILLED" if mutant else "ERROR"), output


def first_failure(output):
    for line in output.splitlines():
        if "FAIL (" in line or "panic:" in line or line == "timed out":
            return line.strip()
    return None


def load_ignored(root):
    """Ids in tools/mutants.ignore, one per line, each followed by a reason."""
    path = root / "tools" / "mutants.ignore"
    if not path.exists():
        return set()
    ids = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            ids.add(line.split()[0])
    return ids


def stratified(mutants, size, seed):
    """Pick a reproducible sample that spreads across files and operators."""
    rng = random.Random(seed)
    buckets = {}
    for m in mutants:
        buckets.setdefault((m.file, m.operator), []).append(m)
    for bucket in buckets.values():
        rng.shuffle(bucket)
    keys = sorted(buckets)
    rng.shuffle(keys)
    picked = []
    while len(picked) < size and any(buckets.values()):
        for key in keys:
            if buckets[key] and len(picked) < size:
                picked.append(buckets[key].pop())
    return sorted(picked, key=lambda m: (m.file, m.line, m.operator))


def main():
    cli = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    cli.add_argument("--zig", default="zig", help="Zig executable to use")
    cli.add_argument("--jobs", type=int, default=2, help="maximum concurrent mutants")
    cli.add_argument("--timeout", type=int, default=300, help="seconds allowed per compile or run")
    cli.add_argument("--sample", type=int, default=40, help="mutants to run, spread across files and operators")
    cli.add_argument("--seed", type=int, default=1, help="seed for the sample")
    cli.add_argument("--all", action="store_true", help="run every mutant")
    cli.add_argument("--file", action="append", help="only mutate this source file (repeatable)")
    cli.add_argument("--operator", action="append", help="only use this operator (repeatable)")
    cli.add_argument("--id", action="append", help="run only the mutant with this id, as printed (repeatable)")
    cli.add_argument("--list", action="store_true", help="list the selected mutants and exit")
    cli.add_argument("--threshold", type=float, default=0.8, help="minimum kill ratio among compiled mutants")
    options = cli.parse_args()
    if options.jobs < 1 or options.timeout < 1 or options.sample < 1:
        cli.error("--jobs, --timeout, and --sample must be positive")

    root = Path(__file__).resolve().parents[1]
    # Work from a snapshot so editing the sources during a run cannot mix versions.
    snapshot_dir = tempfile.TemporaryDirectory(prefix="archipelagist-mutation-source-")
    source = Path(snapshot_dir.name) / "src"
    shutil.copytree(root / "src", source)
    ignored = load_ignored(root)
    mutants = [m for m in generate(source / "core") if m.ident not in ignored]
    if options.file:
        mutants = [m for m in mutants if m.file in options.file]
    if options.operator:
        mutants = [m for m in mutants if m.operator in options.operator]
    counts = {}
    for m in mutants:
        counts[m.operator] = counts.get(m.operator, 0) + 1
    print(f"{len(mutants)} mutants generated ({len(ignored)} ignored as equivalent): "
          + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())), flush=True)
    if options.id:
        selected = [m for m in mutants if m.ident in options.id]
    elif options.all:
        selected = mutants
    else:
        selected = stratified(mutants, options.sample, options.seed)
    if options.list:
        for m in selected:
            print(m.describe())
        return 0

    zig = shutil.which(options.zig)
    if zig is None:
        cli.error(f"Zig executable not found: {options.zig}")
    zig = str(Path(zig).resolve())
    baseline, output = run_case(source, zig, options.timeout, None)
    print(f"{baseline} unmutated baseline", flush=True)
    if baseline != "PASS":
        print(output, file=sys.stderr)
        return 1

    tally = {"KILLED": 0, "SURVIVED": 0, "STILLBORN": 0, "ERROR": 0}
    survivors = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=options.jobs) as pool:
        results = pool.map(lambda m: run_case(source, zig, options.timeout, m), selected)
        for mutant, (status, output) in zip(selected, results, strict=True):
            tally[status] += 1
            print(f"{status:9} {mutant.ident}  {mutant.file}:{mutant.line}", flush=True)
            if status == "KILLED":
                reason = first_failure(output)
                if reason:
                    print(f"          {reason}", flush=True)
            elif status == "SURVIVED":
                survivors.append(mutant)
            elif status == "ERROR":
                print(output, file=sys.stderr)
    judged = tally["KILLED"] + tally["SURVIVED"]
    score = tally["KILLED"] / judged if judged else 1.0
    if survivors:
        print("\nSurviving mutants (add a test, or list an equivalent one in tools/mutants.ignore):")
        for m in survivors:
            print(m.describe())
    print(f"\n{tally['KILLED']}/{judged} compiled mutants killed ({score:.0%}); "
          f"{tally['STILLBORN']} did not compile; threshold {options.threshold:.0%}.", flush=True)
    return int(tally["ERROR"] > 0 or score < options.threshold)


if __name__ == "__main__":
    sys.exit(main())
