from pathlib import Path

ROOT = Path(".")


def collect_files(base, suffix)
    found = []
    for p in base.iterdir():
        if p.suffix == suffix:
            found.append(p.‸)
    return found


def count_files(base):
    return len(collect_files(base, ".py"))
