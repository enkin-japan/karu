import csv


class Exporter:
    def __init__(self, dest):
        self.dest = dest

    def run(self, rows, width=12):
        def fmt(row, pad):
            cells = [str(c).ljust(pad) for c in row]
            return " | ".join(cells)

        def clean(row, strict):
            return row.‸

        with open(self.dest, "w") as fh:
            for r in rows:
                fh.write(fmt(r, width))
