-- =========================================================================
-- 02. SQL ANALÍTICO: CTEs Y FUNCIONES DE VENTANA
-- =========================================================================

-- 1. CTE + ROW_NUMBER(): Obtener la venta más reciente de cada cliente
-- Decisión técnica: Se utiliza ROW_NUMBER() particionado por customer_id y ordenado
-- por created_at DESC, id DESC (para desempate determinista).
WITH ventas_numeradas AS (
    SELECT
        s.customer_id,
        c.full_name,
        s.order_id,
        s.product_category,
        s.amount,
        s.status,
        s.created_at,
        ROW_NUMBER() OVER (
            PARTITION BY s.customer_id
            ORDER BY s.created_at DESC, s.id DESC
        ) AS rn
    FROM sales s
    INNER JOIN customers c ON c.id = s.customer_id
)
SELECT
    customer_id,
    full_name,
    order_id,
    product_category,
    amount,
    status,
    created_at AS fecha_ultima_compra
FROM ventas_numeradas
WHERE rn = 1
ORDER BY customer_id
LIMIT 15;

-- 2. CTE + RANK() y DENSE_RANK(): Top 3 clientes con mayor facturación por ciudad
WITH facturacion_clientes AS (
    SELECT
        c.city,
        c.id AS customer_id,
        c.full_name,
        SUM(s.amount) AS total_comprado,
        COUNT(s.id) AS cantidad_ordenes
    FROM customers c
    INNER JOIN sales s ON s.customer_id = c.id
    WHERE s.status = 'paid'
    GROUP BY c.city, c.id, c.full_name
),
ranking_por_ciudad AS (
    SELECT
        city,
        customer_id,
        full_name,
        total_comprado,
        cantidad_ordenes,
        RANK() OVER (PARTITION BY city ORDER BY total_comprado DESC) AS posicion_rank,
        DENSE_RANK() OVER (PARTITION BY city ORDER BY total_comprado DESC) AS posicion_dense_rank
    FROM facturacion_clientes
)
SELECT
    city,
    posicion_rank,
    customer_id,
    full_name,
    total_comprado,
    cantidad_ordenes
FROM ranking_por_ciudad
WHERE posicion_dense_rank <= 3
ORDER BY city, posicion_rank;

-- 3. LAG() y Cálculo de Acumulados (Running Total):
-- Comparación de cada venta con la venta anterior del mismo cliente y acumulado histórico
WITH historial_cliente AS (
    SELECT
        s.customer_id,
        s.order_id,
        s.created_at::date AS fecha_venta,
        s.amount AS monto_actual,
        LAG(s.amount) OVER (
            PARTITION BY s.customer_id
            ORDER BY s.created_at, s.id
        ) AS monto_venta_anterior,
        SUM(s.amount) OVER (
            PARTITION BY s.customer_id
            ORDER BY s.created_at, s.id
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS acumulado_historico_cliente
    FROM sales s
    WHERE s.customer_id = 1 AND s.status = 'paid'
)
SELECT
    customer_id,
    order_id,
    fecha_venta,
    monto_actual,
    COALESCE(monto_venta_anterior, 0.00) AS monto_anterior,
    monto_actual - COALESCE(monto_venta_anterior, monto_actual) AS diferencia_vs_anterior,
    acumulado_historico_cliente
FROM historial_cliente
ORDER BY fecha_venta, order_id
LIMIT 15;