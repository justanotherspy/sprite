#!/usr/bin/env python3
"""Claude Code status line — rich, dense, no-emoji."""

import json
import subprocess
import sys
from datetime import datetime, timezone

# ── ANSI ─────────────────────────────────────────────────────────────────────
RESET = "\033[0m"
DIM   = "\033[2m"
FW    = "\033[97m"   # bright white
FC    = "\033[36m"   # cyan
FG    = "\033[32m"   # green
FY    = "\033[33m"   # yellow
FM    = "\033[35m"   # magenta
FR    = "\033[31m"   # red
FB    = "\033[34m"   # blue
FX    = "\033[90m"   # dark gray


def c(color: str, text: str) -> str:
    return f"{color}{text}{RESET}"


def d(text: str) -> str:
    return f"{DIM}{text}{RESET}"


# ── Progress bar ──────────────────────────────────────────────────────────────

def bar(pct: float, width: int = 12) -> str:
    filled = round(pct / 100 * width)
    return "[" + "#" * filled + "-" * (width - filled) + "]"


def pct_color(pct: float) -> str:
    if pct >= 90:
        return FR
    if pct >= 70:
        return FY
    return FG


def pct_bar(pct: float, label: str, width: int = 12) -> str:
    col = pct_color(pct)
    return f"{d(label)} {c(col, bar(pct, width))} {c(col, f'{int(pct)}%')}"


def fmt_tokens(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.2f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)


def fmt_rate_limit(data: dict, label: str) -> str:
    pct = float(data.get("used_percentage", 0))
    col = pct_color(pct)
    s = f"{d(label)} {c(col, bar(pct, 10))} {c(col, f'{int(pct)}%')}"
    resets_at = data.get("resets_at")
    if resets_at:
        dt = datetime.fromtimestamp(resets_at, tz=timezone.utc).astimezone()
        s += f"  {d('resets ' + dt.strftime('%H:%M'))}"
    return s


# ── Git ───────────────────────────────────────────────────────────────────────

def git_info(cwd: str) -> dict:
    env = {
        "GIT_OPTIONAL_LOCKS": "0",
        "HOME": "/home/sprite",
        "PATH": "/usr/bin:/bin:/usr/local/bin",
    }

    def run(*args: str) -> str:
        try:
            return subprocess.check_output(
                list(args), cwd=cwd, env=env,
                stderr=subprocess.DEVNULL, text=True,
            ).strip()
        except Exception:
            return ""

    result: dict = {}
    branch = run("git", "rev-parse", "--abbrev-ref", "HEAD")
    if not branch:
        return result

    result["branch"] = branch
    sha = run("git", "rev-parse", "--short", "HEAD")
    result["sha"] = sha

    st = run("git", "status", "--porcelain")
    result["dirty"] = bool(st)
    result["staged"]    = sum(1 for l in st.splitlines() if l and l[0] not in (" ", "?"))
    result["unstaged"]  = sum(1 for l in st.splitlines() if len(l) > 1 and l[1] not in (" ", "?"))
    result["untracked"] = sum(1 for l in st.splitlines() if l.startswith("??"))

    ab = run("git", "rev-list", "--left-right", "--count", "HEAD...@{upstream}")
    if ab:
        parts = ab.split()
        if len(parts) == 2:
            result["ahead"]  = int(parts[0])
            result["behind"] = int(parts[1])

    remote = run("git", "remote", "get-url", "origin")
    if remote:
        result["repo"] = remote.rstrip("/").split("/")[-1].removesuffix(".git")

    return result


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return

    cwd       = data.get("cwd", "")
    model     = data.get("model", {})
    ctx       = data.get("context_window", {})
    limits    = data.get("rate_limits", {})
    effort    = data.get("effort", {})
    thinking  = data.get("thinking", {})
    vim_data  = data.get("vim", {})
    worktree  = data.get("worktree", {})
    agent     = data.get("agent", {})
    version   = data.get("version", "")
    out_style = data.get("output_style", {})

    try:
        user = subprocess.check_output(["whoami"], text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        user = "user"
    try:
        host = subprocess.check_output(["hostname", "-s"], text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        host = "host"

    now       = datetime.now()
    short_cwd = cwd.replace("/home/sprite", "~") if cwd else "?"
    sep       = d("-" * 72)
    lines: list[str] = []

    # Row 1: identity + cwd + timestamp
    lines.append(
        f"  {c(FG, user)}{d('@')}{c(FG, host)}"
        f"  {c(FB, short_cwd)}"
        f"  {d(now.strftime('%a %b %d  %H:%M:%S'))}"
    )

    # Row 2: git status
    git = git_info(cwd) if cwd else {}
    if git:
        repo   = git.get("repo", "")
        branch = git.get("branch", "")
        sha    = git.get("sha", "")
        rb     = f"{c(FC, repo)}/{c(FM, branch)}" if repo else c(FM, branch)

        sp: list[str] = []
        if git.get("staged"):
            sp.append(c(FG, f"+{git['staged']} staged"))
        if git.get("unstaged"):
            sp.append(c(FY, f"~{git['unstaged']} modified"))
        if git.get("untracked"):
            sp.append(c(FX, f"?{git['untracked']} untracked"))
        if not git.get("dirty"):
            sp.append(c(FG, "clean"))

        ab: list[str] = []
        if git.get("ahead"):
            ab.append(c(FC, f"^{git['ahead']} ahead"))
        if git.get("behind"):
            ab.append(c(FY, f"v{git['behind']} behind"))

        git_line = f"  {d('git')}  {rb}  {d(sha)}  {' '.join(sp)}"
        if ab:
            git_line += f"  {'  '.join(ab)}"
        if worktree:
            wt_name   = worktree.get("name", "")
            wt_branch = worktree.get("branch", "")
            git_line += f"  {d('worktree:')} {c(FY, wt_name)}"
            if wt_branch:
                git_line += f"/{c(FM, wt_branch)}"
        lines.append(git_line)

    # Row 3: model + active flags
    model_name = model.get("display_name") or model.get("id") or "unknown"
    model_line = f"  {d('model')}  {c(FW, model_name)}"

    flags: list[str] = []
    if effort:
        flags.append(f"{d('effort:')} {c(FC, effort.get('level', ''))}")
    if thinking.get("enabled"):
        flags.append(c(FC, "thinking-on"))
    if vim_data:
        flags.append(f"{d('vim:')} {c(FY, vim_data.get('mode', ''))}")
    if agent:
        flags.append(f"{d('agent:')} {c(FM, agent.get('name', ''))}")
    style_name = out_style.get("name", "")
    if style_name and style_name.lower() != "default":
        flags.append(f"{d('style:')} {c(FX, style_name)}")
    if version:
        flags.append(d(f"cc-v{version}"))
    if flags:
        model_line += f"  {'  '.join(flags)}"
    lines.append(model_line)

    # Row 4: context window usage
    used_pct  = ctx.get("used_percentage")
    ctx_size  = ctx.get("context_window_size", 0)
    total_in  = ctx.get("total_input_tokens", 0)
    total_out = ctx.get("total_output_tokens", 0)
    current   = ctx.get("current_usage") or {}

    if used_pct is not None:
        ctx_line = f"  {pct_bar(float(used_pct), 'context')}"
        if ctx_size:
            ctx_line += f"  {d('window:')} {c(FW, fmt_tokens(ctx_size))}"
        if total_in:
            ctx_line += f"  {d('in:')} {c(FX, fmt_tokens(total_in))}"
        if total_out:
            ctx_line += f"  {d('out:')} {c(FX, fmt_tokens(total_out))}"
        if current:
            cw = current.get("cache_creation_input_tokens", 0)
            cr = current.get("cache_read_input_tokens", 0)
            if cw or cr:
                ctx_line += f"  {d('cache w/r:')} {c(FX, fmt_tokens(cw))}/{c(FX, fmt_tokens(cr))}"
    else:
        ctx_line = f"  {d('context')}  {d('(no messages yet)')}"
        if ctx_size:
            ctx_line += f"  {d('window:')} {c(FW, fmt_tokens(ctx_size))}"
    lines.append(ctx_line)

    # Row 5: plan rate limits (5hr and 7day)
    five_hour = limits.get("five_hour")
    seven_day = limits.get("seven_day")
    if five_hour or seven_day:
        rl: list[str] = []
        if five_hour:
            rl.append(fmt_rate_limit(five_hour, "plan 5hr"))
        if seven_day:
            rl.append(fmt_rate_limit(seven_day, "plan 7day"))
        lines.append(f"  {'  |  '.join(rl)}")

    # Output
    print(sep)
    for line in lines:
        print(line)
    print(sep)


if __name__ == "__main__":
    main()
