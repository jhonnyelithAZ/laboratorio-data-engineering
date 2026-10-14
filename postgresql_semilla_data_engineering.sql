-- ============================================================
-- Semilla de datos para la clase: PostgreSQL para Data Engineering
-- Compatible con PostgreSQL 14+
-- Genera: 200 clientes y 50.000 ventas reproducibles.
-- Uso: psql -U usuario -d base_de_datos -f postgresql_semilla_data_engineering.sql
-- ============================================================

BEGIN;

DROP TABLE IF EXISTS sales CASCADE;
DROP TABLE IF EXISTS customers CASCADE;

CREATE TABLE customers (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name    VARCHAR(120) NOT NULL,
    email        VARCHAR(180) NOT NULL UNIQUE,
    city         VARCHAR(80) NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE sales (
    id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id          VARCHAR(40) NOT NULL UNIQUE,
    customer_id       BIGINT NOT NULL REFERENCES customers(id),
    product_category  VARCHAR(40) NOT NULL,
    amount            NUMERIC(12, 2) NOT NULL CHECK (amount >= 0),
    status            VARCHAR(20) NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL,
    updated_at        TIMESTAMPTZ NOT NULL
);

-- 200 clientes ficticios.
INSERT INTO customers (full_name, email, city, created_at, updated_at)
SELECT
    'Cliente ' || LPAD(g::text, 4, '0'),
    'cliente' || g || '@example.com',
    (ARRAY['Bogotá', 'Medellín', 'Cali', 'Barranquilla', 'Cartagena', 'Bucaramanga'])[((g - 1) % 6) + 1],
    NOW() - ((g % 700) || ' days')::interval,
    NOW() - ((g % 90) || ' days')::interval
FROM generate_series(1, 200) AS g;

-- 50.000 ventas con fechas distribuidas en los últimos 18 meses.
-- Se fija la semilla de random() para facilitar una demostración repetible.
SELECT setseed(0.42);

INSERT INTO sales (
    order_id, customer_id, product_category, amount, status, created_at, updated_at
)
SELECT
    'ORD-' || LPAD(g::text, 8, '0'),
    1 + floor(random() * 200)::BIGINT,
    (ARRAY['Tecnología', 'Hogar', 'Deportes', 'Ropa', 'Libros'])[(1 + floor(random() * 5))::int],
    ROUND((10000 + random() * 990000)::numeric, 2),
    (ARRAY['paid', 'paid', 'paid', 'pending', 'cancelled'])[(1 + floor(random() * 5))::int],
    NOW() - (random() * INTERVAL '540 days'),
    NOW() - (random() * INTERVAL '180 days')
FROM generate_series(1, 50000) AS g;

-- Asegura que updated_at nunca sea anterior a created_at.
UPDATE sales
SET updated_at = created_at + (random() * INTERVAL '30 days')
WHERE updated_at < created_at;

-- Índices iniciales para relaciones y consultas comunes.
CREATE INDEX idx_sales_customer_id ON sales(customer_id);
CREATE INDEX idx_sales_category_created_at ON sales(product_category, created_at);

COMMIT;

ANALYZE customers;
ANALYZE sales;