export class ReportBuilder {
  private rows: string[][] = [];

  constructor(private readonly title: string) {}

  render(width: number): string {
    function pad(cell: string, size: number) {
      return cell.padEnd(size);
    }
    function joinRow(cells: string[], sep: string) {
      return cells.‸
    }
    return this.rows.map(r => pad(r.join(","), width)).join("\n");
  }
}
