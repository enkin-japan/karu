// Invoices.cs — C# 11 sample with verbatim, raw and interpolated strings.
using System;
using System.Collections.Generic;
using System.Linq;

/* Block comment spanning lines:
   var s = "not a string"; // nor this
   $"{not.interpolated}"
*/
namespace Billing;

/// <summary>An invoice line.</summary>
public record Line(string Sku, int Quantity, decimal Price)
{
    public decimal Total => Quantity * Price;
}

public sealed class Invoice
{
    private readonly List<Line> _lines = new();
    public string Customer { get; init; } = "unknown";

    public void Add(Line line) => _lines.Add(line);

    public string ExportPath => @"C:\exports\invoices\""quoted"" folder\";

    public string VerbatimMultiline => @"First line
Second line with a ""double quote"" and // no comment
Third line";

    public string Summary()
    {
        var total = _lines.Sum(l => l.Total);
        return $"Invoice for {Customer}: {_lines.Count} lines, total {total:C2} ({(total > 100 ? "large" : "small")})";
    }

    public string RawJson() => """
        {
          "customer": "name",
          "note": "raw strings keep \n and \"quotes\" literally",
          "comment": "/* not a comment */"
        }
        """;

    public string RawInterpolated() => $$"""
        {
          "customer": "{{Customer}}",
          "lines": {{_lines.Count}},
          "braces": "{literal}"
        }
        """;

    public string VerbatimInterpolated(string dir) => $@"{dir}\{Customer}\report.txt
line two {_lines.Count}";

    public IEnumerable<string> Labels()
    {
        foreach (var line in _lines)
        {
            yield return $"{line.Sku,-10}|{line.Quantity,4}|{line.Price,8:F2}|{$"nested {line.Total}"}";
        }
    }

    public decimal Ratio(decimal a, decimal b) => a / b / 2m; // divisions
}

public static class Program
{
    private const char Quote = '"';

    public static void Main()
    {
        var invoice = new Invoice { Customer = "Ada" };
        invoice.Add(new Line("A-100", 2, 9.99m));
        invoice.Add(new Line("B-200", 1, 120m));
        Console.WriteLine(invoice.Summary());
        Console.WriteLine(invoice.RawJson() + Quote + invoice.ExportPath);
        /* trailing block
           comment */
        Console.WriteLine(string.Join(Environment.NewLine, invoice.Labels()));
    }
}
