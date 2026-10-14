-- =========================================================================
-- 04. EXTRACCIÓN INCREMENTAL, IDEMPOTENCIA Y TRANSACCIONES
-- =========================================================================

-- 1. Preparación: Tabla de control de marca de agua (Watermark) y tabla destino (Staging/DWH)
CREATE TABLE IF NOT EXISTS etl_watermarks (
    pipeline_name   VARCHAR(80) PRIMARY KEY,
    last_watermark  TIMESTAMPTZ NOT NULL,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS sales_curated (
    order_id          VARCHAR(40) PRIMARY KEY, -- Clave de negocio única para garantizar idempotencia
    customer_id       BIGINT NOT NULL,
    product_category  VARCHAR(40) NOT NULL,
    amount            NUMERIC(12, 2) NOT NULL,
    status            VARCHAR(20) NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL,
    updated_at        TIMESTAMPTZ NOT NULL,
    loaded_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Inicializamos la marca de agua 5 días atrás (de forma idempotente)
INSERT INTO etl_watermarks (pipeline_name, last_watermark, updated_at)
VALUES ('sales_incremental_load', NOW() - INTERVAL '5 days', NOW())
ON CONFLICT (pipeline_name) DO NOTHING;

-- -------------------------------------------------------------------------
-- 2. DEMOSTRACIÓN DE IDEMPOTENCIA (UPSERT REPETIBLE SIN DUPLICADOS)
-- -------------------------------------------------------------------------
-- Ejecutamos dos veces seguidas la inserción/actualización de la orden 'ORD-DEMO-0001'
-- Primera ejecución (Inserta el registro con estado 'pending' y monto 100000):
INSERT INTO sales (order_id, customer_id, product_category, amount, status, created_at, updated_at)
VALUES ('ORD-DEMO-0001', 1, 'Tecnología', 100000.00, 'pending', NOW() - INTERVAL '1 hour', NOW() - INTERVAL '1 hour')
ON CONFLICT (order_id) DO UPDATE SET
    amount = EXCLUDED.amount,
    status = EXCLUDED.status,
    updated_at = EXCLUDED.updated_at;

-- Segunda ejecución / Reintento o actualización (Cambia a 'paid' y monto 125000.00):
INSERT INTO sales (order_id, customer_id, product_category, amount, status, created_at, updated_at)
VALUES ('ORD-DEMO-0001', 1, 'Tecnología', 125000.00, 'paid', NOW() - INTERVAL '1 hour', NOW())
ON CONFLICT (order_id) DO UPDATE SET
    amount = EXCLUDED.amount,
    status = EXCLUDED.status,
    updated_at = EXCLUDED.updated_at;

-- Verificación de idempotencia: Debe existir exactamente 1 fila para 'ORD-DEMO-0001' con el estado actualizado
SELECT
    order_id,
    COUNT(*) AS cantidad_filas,
    MAX(amount) AS monto_actual,
    MAX(status) AS estado_actual
FROM sales
WHERE order_id = 'ORD-DEMO-0001'
GROUP BY order_id;

-- -------------------------------------------------------------------------
-- 3. EXTRACCIÓN INCREMENTAL + TRANSACCIÓN EXITOSA (COMMIT)
-- -------------------------------------------------------------------------
-- Decisión técnica: La carga de los registros en el intervalo semiabierto [inicio, fin)
-- y la actualización del watermark se envuelven en un mismo bloque BEGIN...COMMIT.
-- Así la marca de agua SOLO avanza si los datos se escribieron con éxito.
BEGIN;

WITH ventana_extraccion AS (
    SELECT
        last_watermark AS fecha_inicio,
        NOW() AS fecha_fin
    FROM etl_watermarks
    WHERE pipeline_name = 'sales_incremental_load'
),
datos_extraidos AS (
    SELECT
        s.order_id, s.customer_id, s.product_category, s.amount, s.status, s.created_at, s.updated_at
    FROM sales s
    CROSS JOIN ventana_extraccion v
    -- Intervalo [inicio, fin) + lookback de 5 minutos para capturar registros tardíos (late arriving data)
    WHERE s.updated_at >= (v.fecha_inicio - INTERVAL '5 minutes')
      AND s.updated_at < v.fecha_fin
)
INSERT INTO sales_curated (
    order_id, customer_id, product_category, amount, status, created_at, updated_at, loaded_at
)
SELECT
    order_id, customer_id, product_category, amount, status, created_at, updated_at, NOW()
FROM datos_extraidos
ON CONFLICT (order_id) DO UPDATE SET
    amount = EXCLUDED.amount,
    status = EXCLUDED.status,
    updated_at = EXCLUDED.updated_at,
    loaded_at = NOW();

-- Avanzamos la marca de agua únicamente al finalizar la escritura sin errores
UPDATE etl_watermarks
SET last_watermark = NOW(),
    updated_at = NOW()
WHERE pipeline_name = 'sales_incremental_load';

COMMIT;

-- Comprobación tras el COMMIT exitoso:
SELECT
    w.pipeline_name,
    w.last_watermark AS watermark_confirmado,
    (SELECT COUNT(*) FROM sales_curated) AS total_registros_en_curated
FROM etl_watermarks w
WHERE w.pipeline_name = 'sales_incremental_load';

-- -------------------------------------------------------------------------
-- 4. TRANSACCIÓN FALLIDA Y RECUPERACIÓN (ROLLBACK)
-- -------------------------------------------------------------------------
-- Simulamos un fallo durante una carga en lote: modificamos un monto e intentamos
-- avanzar la marca de agua al año 2099, pero revertimos con ROLLBACK.
BEGIN;

UPDATE sales_curated
SET amount = 99999999.99
WHERE order_id = 'ORD-DEMO-0001';

UPDATE etl_watermarks
SET last_watermark = '2099-01-01 00:00:00+00'
WHERE pipeline_name = 'sales_incremental_load';

-- Detectamos anomalía/error en el pipeline y revertimos toda la transacción:
ROLLBACK;

-- Comprobación post-ROLLBACK: El monto de ORD-DEMO-0001 sigue en 125000.00 y el watermark NO quedó en 2099
SELECT
    c.order_id,
    c.amount AS monto_intacto_post_rollback,
    w.last_watermark AS watermark_intacto_post_rollback
FROM sales_curated c
CROSS JOIN etl_watermarks w
WHERE c.order_id = 'ORD-DEMO-0001'
  AND w.pipeline_name = 'sales_incremental_load';