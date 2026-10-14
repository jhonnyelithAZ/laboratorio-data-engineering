# Evidencias y Análisis de Rendimiento en PostgreSQL

Este documento presenta el análisis comparativo de planes de ejecución obtenidos mediante `EXPLAIN (ANALYZE, BUFFERS)` sobre la tabla `sales` (50.000 registros), evaluando el impacto real de la creación de índices B-Tree en consultas de filtrado temporal y extracción incremental.

---

## 1. Caso de Estudio A: Filtrado por Fecha de Creación (`created_at`)

### Contexto Técnico
La semilla inicial incluye un índice compuesto `idx_sales_category_created_at ON sales(product_category, created_at)`. Sin embargo, cuando una consulta filtra únicamente por `created_at` sin incluir la columna líder (`product_category`), el optimizador de PostgreSQL no puede aprovechar eficientemente dicho índice compuesto y recurre a un escaneo secuencial completo (`Seq Scan`).

### Consulta Evaluada
    EXPLAIN (ANALYZE, BUFFERS)
    SELECT id, order_id, customer_id, amount, created_at
    FROM sales
    WHERE created_at >= NOW() - INTERVAL '7 days';

### Plan de Ejecución ANTES del Índice
    Seq Scan on sales  (cost=0.00..1616.00 rows=656 width=45) (actual time=1.326..5.249 rows=672 loops=1)
      Filter: (created_at >= (now() - '7 days'::interval))
      Rows Removed by Filter: 49328
      Buffers: shared hit=741
    Planning:
      Buffers: shared hit=39
    Planning Time: 4.285 ms
    Execution Time: 5.716 ms

### Solución Aplicada
    CREATE INDEX idx_sales_created_at ON sales(created_at);
    ANALYZE sales;

### Plan de Ejecución DESPUÉS del Índice
    Bitmap Heap Scan on sales  (cost=13.30..772.57 rows=646 width=45) (actual time=0.124..0.260 rows=672 loops=1)
      Recheck Cond: (created_at >= (now() - '7 days'::interval))
      Heap Blocks: exact=118
      Buffers: shared hit=120 read=2
      ->  Bitmap Index Scan on idx_sales_created_at  (cost=0.00..13.14 rows=646 width=0) (actual time=0.111..0.112 rows=672 loops=1)
            Index Cond: (created_at >= (now() - '7 days'::interval))
            Buffers: shared hit=2 read=2
    Planning:
      Buffers: shared hit=27 read=3
    Planning Time: 0.693 ms
    Execution Time: 0.593 ms

---

## 2. Caso de Estudio B: Extracción Incremental por `updated_at`

### Contexto Técnico
Los procesos ETL/ELT incrementales consultan periódicamente la columna `updated_at` usando una ventana semiabierta `[inicio, fin)`. Sin un índice sobre `updated_at`, cada ejecución del pipeline obliga a leer toda la tabla histórica en disco/memoria.

### Plan de Ejecución ANTES del Índice (`idx_sales_updated_at`)
    Seq Scan on sales  (cost=0.00..1866.00 rows=517 width=53) (actual time=0.033..5.721 rows=650 loops=1)
      Filter: ((updated_at < now()) AND (updated_at >= (now() - '2 days'::interval)))
      Rows Removed by Filter: 49350
      Buffers: shared hit=741
    Planning:
      Buffers: shared hit=3
    Planning Time: 0.093 ms
    Execution Time: 5.759 ms

### Plan de Ejecución DESPUÉS del Índice (`idx_sales_updated_at`)
    Bitmap Heap Scan on sales  (cost=14.04..749.73 rows=560 width=53) (actual time=0.309..0.660 rows=650 loops=1)
      Recheck Cond: ((updated_at >= (now() - '2 days'::interval)) AND (updated_at < now()))
      Heap Blocks: exact=406
      Buffers: shared hit=406 read=3
      ->  Bitmap Index Scan on idx_sales_updated_at  (cost=0.00..13.90 rows=560 width=0) (actual time=0.258..0.258 rows=650 loops=1)
            Index Cond: ((updated_at >= (now() - '2 days'::interval)) AND (updated_at < now()))
            Buffers: shared read=3
    Planning:
      Buffers: shared hit=26 read=1
    Planning Time: 0.905 ms
    Execution Time: 0.736 ms

---

## 3. Tabla Comparativa y Conclusiones Basadas en Evidencia

| Escenario | Operador del Plan | Filas Descartadas | Bloques Leídos (Buffers) | Costo Estimado | Execution Time | Mejora |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: |
| **`created_at` SIN índice** | `Seq Scan` | 49.328 | 741 | 1616.00 | **5.716 ms** | Base |
| **`created_at` CON índice** | `Bitmap Index Scan` | 0 | 122 | 772.57 | **0.593 ms** | **-89.6% tiempo (9.6x más rápido)** |
| **`updated_at` SIN índice** | `Seq Scan` | 49.350 | 741 | 1866.00 | **5.759 ms** | Base |
| **`updated_at` CON índice** | `Bitmap Index Scan` | 0 | 409 | 749.73 | **0.736 ms** | **-87.2% tiempo (7.8x más rápido)** |

### Conclusiones Técnicas
1. **Eliminación de lectura inútil:** Sin índice, PostgreSQL descarta más del **98.6% de la tabla** (49.328 y 49.350 filas respectivamente) tras haberlas leído en memoria (`shared hit=741`). Con los índices B-Tree, el motor localiza directamente los punteros a las filas que cumplen la condición (`Index Cond`).
2. **Por qué eligió `Bitmap Heap Scan`:** Como las consultas retornan entre 650 y 672 filas distribuidas en distintas páginas de datos, PostgreSQL construye primero un mapa de bits en memoria (`Bitmap Index Scan`) para ordenar las lecturas físicas de bloques (`Heap Blocks`) de forma secuencial, evitando saltos aleatorios de E/S.
3. **Cuándo NO ayudan los índices:** Si una consulta solicitara un porcentaje alto de la tabla (por ejemplo, el 80% de los registros), un `Seq Scan` sería más eficiente que leer el índice más la tabla. Además, cada índice adicional agrega una pequeña sobrecarga en operaciones `INSERT/UPDATE`.