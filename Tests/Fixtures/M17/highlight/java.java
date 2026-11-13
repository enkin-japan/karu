package dev.example.reports;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Renders HTML reports.
 *
 * <p>Javadoc that looks like code: {@code String s = "x"; return s;}
 * and a fake terminator inside text: "*" "/" written apart.
 */
public final class ReportRenderer {

    private static final String TEMPLATE = """
        <html>
          <body class="report">
            <h1>%s</h1>
            <!-- an HTML comment inside a text block -->
            <p>Escapes: \t tab, \"quote\", and a line \
        continuation.</p>
            // not a Java comment, /* not a block either */
          </body>
        </html>
        """;

    private static final String SQL = """
        SELECT id, total
        FROM orders
        WHERE status = 'open' -- SQL comment, still a string
        """;

    private static final char QUOTE = '"';
    private static final char BACKSLASH = '\\';
    private static final String PLAIN = "/* not a comment */ // nor this";

    private final List<String> rows = new ArrayList<>();

    /* Block comment
       across two lines */
    public ReportRenderer add(String row) {
        rows.add(row);
        return this;
    }

    public String render(String title) {
        StringBuilder body = new StringBuilder();
        for (int i = 0; i < rows.size(); i++) {
            body.append("<li>").append(i + 1).append(": ").append(rows.get(i)).append("</li>");
        }
        return TEMPLATE.formatted(title) + body + QUOTE + BACKSLASH;
    }

    public double ratio(int a, int b) {
        return (double) a / b / 2; // two divisions
    }

    public Map<String, Integer> counts() {
        return Map.of("rows", rows.size(), "sqlLength", SQL.length());
    }

    @Override
    public String toString() {
        return "ReportRenderer{rows=" + rows.size() + ", plain='" + PLAIN + "'}";
    }

    public static void main(String[] args) {
        var renderer = new ReportRenderer().add("alpha").add("beta");
        System.out.println(renderer.render("Weekly"));
        System.out.println(renderer.ratio(10, 4) + " " + renderer.counts());
    }
}
