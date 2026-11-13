/*
 * Monthly revenue report.
 * Code-looking comment text: SELECT * FROM users WHERE id = 1;
 */
-- Line comment with a /* that must not open a block
CREATE TABLE IF NOT EXISTS orders (
    id          BIGINT PRIMARY KEY,
    customer    VARCHAR(120) NOT NULL,
    note        TEXT DEFAULT 'it''s fine',   -- doubled quote escape
    total_cents INTEGER NOT NULL CHECK (total_cents >= 0),
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO orders (id, customer, note, total_cents) VALUES
    (1, 'Ada', 'multi-line
note with -- not a comment
and /* not a block */ either', 1250),
    (2, 'Grace', 'plain', 990);

/* A block comment
   spanning lines between statements */
SELECT
    customer,
    COUNT(*)                     AS order_count,
    SUM(total_cents) / 100.0     AS revenue,
    AVG(total_cents) / 100 / 2   AS half_avg -- divisions
FROM orders
WHERE created_at >= DATE '2026-01-01'
  AND note NOT LIKE '%--%'
GROUP BY customer
HAVING SUM(total_cents) > 1000
ORDER BY revenue DESC;

CREATE OR REPLACE FUNCTION order_label(o orders) RETURNS TEXT AS $$
BEGIN
    -- body is a dollar-quoted string in PostgreSQL
    RETURN o.customer || ': ' || (o.total_cents / 100.0)::TEXT;
END;
$$ LANGUAGE plpgsql;

UPDATE orders SET note = "quoted identifier style" WHERE id = 2; /* trailing */
