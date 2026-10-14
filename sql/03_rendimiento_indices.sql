-- =========================================================================
-- 03. RENDIMIENTO: PLANES DE EJECUCIÓN (EXPLAIN ANALYZE) Y USO DE ÍNDICES
-- =========================================================================

-- Limpieza preventiva por si el script se ejecuta más de una vez
DROP INDEX IF EXISTS idx_sales_created_at;
DROP INDEX IF EXISTS idx_sales_updated_at;
ANALYZE sales;

-- -------------------------------------------------------------------------
-- CASO 1: Consulta por rango de fecha de creación (created_at) SIN índice
-- -------------------------------------------------------------------------
-- Observación esperada: Seq Scan on sales (escanea las 50.000 filas completas)
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, order_id, customer_id, amount, created_at
FROM sales
WHERE created_at >= NOW() - INTERVAL '7 days';

-- -------------------------------------------------------------------------
-- Creación del índice B-Tree sobre created_at y actualización de estadísticas
-- -------------------------------------------------------------------------
CREATE INDEX idx_sales_created_at ON sales(created_at);
ANALYZE sales;

-- -------------------------------------------------------------------------
-- CASO 2: Misma consulta por rango de fecha (created_at) CON índice
-- -------------------------------------------------------------------------
-- Observación esperada: Index Scan / Bitmap Index Scan usando idx_sales_created_at
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, order_id, customer_id, amount, created_at
FROM sales
WHERE created_at >= NOW() - INTERVAL '7 days';

-- -------------------------------------------------------------------------
-- CASO 3: Índice para soportar la Extracción Incremental por updated_at
-- -------------------------------------------------------------------------
-- Sin índice en updated_at:
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, order_id, customer_id, amount, created_at, updated_at
FROM sales
WHERE updated_at >= NOW() - INTERVAL '2 days'
  AND updated_at < NOW();

-- Creando índice en updated_at para optimizar lecturas incrementales (CDC / Watermark):
CREATE INDEX idx_sales_updated_at ON sales(updated_at);
ANALYZE sales;

-- Con índice en updated_at:
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, order_id, customer_id, amount, created_at, updated_at
FROM sales
WHERE updated_at >= NOW() - INTERVAL '2 days'
  AND updated_at < NOW();