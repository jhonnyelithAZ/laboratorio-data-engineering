-- =========================================================================
-- 01. SQL RELACIONAL: JOINS, AGREGACIONES Y TRATAMIENTO DE NULLS
-- =========================================================================

-- 1. Métricas comerciales por cliente (LEFT JOIN + COALESCE para manejo de NULL)
-- Decisión técnica: Usamos LEFT JOIN desde 'customers' hacia 'sales' para asegurar
-- que cualquier cliente sin compras no sea descartado del análisis.
-- Aplicamos COALESCE(..., 0) porque las funciones SUM() y AVG() devuelven NULL
-- cuando un cliente no tiene filas coincidentes en 'sales'.
SELECT
    c.id AS customer_id,
    c.full_name,
    c.city,
    COUNT(s.id) AS total_ordenes,
    COALESCE(SUM(s.amount), 0.00) AS ingresos_brutos,
    ROUND(COALESCE(AVG(s.amount), 0.00), 2) AS ticket_promedio,
    COALESCE(SUM(CASE WHEN s.status = 'paid' THEN s.amount ELSE 0 END), 0.00) AS ingresos_netos_pagados
FROM customers c
LEFT JOIN sales s ON s.customer_id = c.id
GROUP BY c.id, c.full_name, c.city
ORDER BY ingresos_netos_pagados DESC
LIMIT 10;

-- 2. Demostración de diferencia entre INNER JOIN y LEFT JOIN + tratamiento de NULL
-- Para demostrar el caso en que un cliente existe pero aún no registra ventas,
-- usamos una CTE con un cliente simulado en memoria (id = 999) y comparamos:
WITH catalogo_clientes AS (
    SELECT id, full_name, city FROM customers
    UNION ALL
    SELECT 999, 'Cliente Nuevo Sin Compras', 'Barranquilla'
)
SELECT
    'INNER JOIN (Excluye clientes sin ventas)' AS tipo_join,
    COUNT(DISTINCT c.id) AS clientes_en_resultado,
    COUNT(s.id) AS ventas_contabilizadas
FROM catalogo_clientes c
INNER JOIN sales s ON s.customer_id = c.id

UNION ALL

SELECT
    'LEFT JOIN (Conserva al cliente sin ventas con NULL/0)' AS tipo_join,
    COUNT(DISTINCT c.id) AS clientes_en_resultado,
    COUNT(s.id) AS ventas_contabilizadas
FROM catalogo_clientes c
LEFT JOIN sales s ON s.customer_id = c.id;

-- 3. Inspección directa del registro con NULL en LEFT JOIN y su conversión con COALESCE
WITH catalogo_clientes AS (
    SELECT 999 AS id, 'Cliente Nuevo Sin Compras' AS full_name, 'Barranquilla' AS city
)
SELECT
    c.id,
    c.full_name,
    s.order_id AS order_id_original_null,
    COALESCE(s.order_id, 'SIN_ORDENES') AS order_id_tratado,
    s.amount AS monto_original_null,
    COALESCE(s.amount, 0.00) AS monto_tratado
FROM catalogo_clientes c
LEFT JOIN sales s ON s.customer_id = c.id;

-- 4. Métricas comerciales agregadas por ciudad y categoría (solo órdenes pagadas)
SELECT
    c.city,
    s.product_category,
    COUNT(s.id) AS cantidad_ventas,
    ROUND(SUM(s.amount), 2) AS total_ventas,
    ROUND(AVG(s.amount), 2) AS promedio_venta
FROM customers c
INNER JOIN sales s ON s.customer_id = c.id
WHERE s.status = 'paid'
GROUP BY c.city, s.product_category
ORDER BY c.city, total_ventas DESC
LIMIT 15;