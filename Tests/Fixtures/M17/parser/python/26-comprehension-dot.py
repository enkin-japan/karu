# Work in progress: comprehension dot
# Notes: this module is still being drafted;
# names and signatures may change before review.
# Keep helpers small and avoid side effects at import time.
# See the tracking issue for open questions.
def column_names(rows, wanted):
    names = [row.‸ for row in rows if row]
    return [n for n in names if n in wanted]


def pick_columns(rows, wanted):
    picked = []
    for row in rows:
        picked.append([c for c in row if c in wanted])
    return picked
