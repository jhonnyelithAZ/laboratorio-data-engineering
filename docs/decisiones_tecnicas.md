# Decisiones Técnicas: SQL, Extracción Incremental, Idempotencia y Transacciones

Este documento detalla la estrategia de ingeniería de datos implementada en los scripts de la carpeta `/sql`.

---

## 1. SQL Relacional y Analítico

### Selección de Tipos de JOIN y Tratamiento de `NULL`
* **`LEFT JOIN` vs `INNER JOIN`:** Para los reportes de clientes (`sql/01_sql_relacional.sql`), se eligió `LEFT JOIN` partiendo de la tabla maestra `customers` hacia `sales`. Un `INNER JOIN` omitiría silenciosamente a los clientes recién registrados que aún no tienen compras (como se demostró en la prueba con el cliente `id = 999`, pasando de 200 a 201 clientes), sesgando métricas como el total de clientes o el ticket promedio por usuario registrado.
* **Manejo de `NULL` con `COALESCE`:** En un `LEFT JOIN`, las columnas de la tabla derecha (`s.amount`, `s.order_id`) toman valor `NULL` cuando no existe coincidencia. Funciones agregadas como `SUM()` o `AVG()` devuelven `NULL` para esos grupos. Se utilizó `COALESCE(SUM(s.amount), 0.00)` y `COALESCE(s.order_id, 'SIN_ORDENES')` para asegurar salidas limpias aptas para herramientas de BI y pipelines posteriores.

### Uso de CTEs y Funciones de Ventana
* Se implementaron **CTEs (`WITH`)** en `sql/02_sql_analitico.sql` para desacoplar la lógica de pre-agregación y numeración de filas del filtrado final, mejorando la legibilidad y mantenibilidad frente a subconsultas anidadas.
* **`ROW_NUMBER()` con desempate determinista:** Para obtener la última compra por cliente se usó `ORDER BY s.created_at DESC, s.id DESC`. Incluir `s.id DESC` garantiza que, ante dos ventas con idéntico timestamp, el resultado sea 100% determinista.
* **`RANK()` vs `DENSE_RANK()`:** Se empleó `DENSE_RANK() <= 3` para obtener el Top 3 de facturación por ciudad sin dejar huecos en la numeración en caso de empates.
* **`LAG()` y Acumulados (`SUM() OVER`):** Permiten comparar la variación de gasto de un cliente respecto a su orden inmediatamente anterior y calcular el acumulado histórico (*running total*) en una sola pasada sobre los datos, sin necesidad de *self-joins* costosos.

---

## 2. Estrategia de Extracción Incremental y Marca de Agua (Watermark)

En lugar de extraer las 50.000 filas en cada ejecución (*Full Load*), se implementó en `sql/04_incremental_idempotencia_transacciones.sql` una arquitectura basada en una tabla de control `etl_watermarks`.

### Criterio de Selección: `updated_at` vs `created_at`
* Se eligió **`updated_at`** como columna de control porque captura tanto **registros nuevos** (donde `updated_at >= created_at`) como **registros modificados** posteriormente (por ejemplo, una orden que pasa de `pending` a `paid` o `cancelled` días después de haberse creado). Filtrar solo por `created_at` provocaría pérdida de actualizaciones de estado.

### Límites del Intervalo Semiabierto `[inicio, fin)`
Para evitar tanto la pérdida de datos como la duplicación innecesaria en los bordes temporales entre ejecuciones consecutivas, se definió un intervalo cerrado por la izquierda y abierto por la derecha:

    WHERE s.updated_at >= (v.fecha_inicio - INTERVAL '5 minutes')
      AND s.updated_at < v.fecha_fin

* El límite superior exacto (`v.fecha_fin`) de la ejecución actual se convierte en el nuevo `last_watermark` de la siguiente ejecución.

### Manejo de Registros Tardíos (*Late Arriving Data*)
* En sistemas transaccionales concurrentes, una transacción larga puede iniciar en el instante T1, pero confirmarse (`COMMIT`) en T2 después de que el extractor ya corrió.
* Para mitigar esto, se aplica una **ventana deslizante de seguridad (*lookback window*) de 5 minutos** (`v.fecha_inicio - INTERVAL '5 minutes'`). Aunque esto vuelve a leer los registros de los últimos 5 minutos del lote previo, nuestra capa de escritura **idempotente** garantiza que re-procesarlos no genere duplicados.

---

## 3. Idempotencia y Prevención de Duplicados

Un pipeline es **idempotente** si ejecutarlo N veces con el mismo lote de entrada produce exactamente el mismo estado en la base de datos que ejecutarlo una sola vez.

* **Clave de negocio única:** La columna `order_id` cuenta con una restricción `UNIQUE` en `sales` y actúa como `PRIMARY KEY` en la tabla destino `sales_curated`.
* **Operación `UPSERT` (`INSERT ... ON CONFLICT DO UPDATE`):**

    INSERT INTO sales_curated (order_id, customer_id, product_category, amount, status, created_at, updated_at, loaded_at)
    SELECT order_id, customer_id, product_category, amount, status, created_at, updated_at, NOW()
    FROM datos_extraidos
    ON CONFLICT (order_id) DO UPDATE SET
        amount = EXCLUDED.amount,
        status = EXCLUDED.status,
        updated_at = EXCLUDED.updated_at,
        loaded_at = NOW();

* **Evidencia obtenida:** Al insertar y actualizar dos veces la orden `ORD-DEMO-0001` (primero con `100000.00 / pending` y luego con `125000.00 / paid`), la consulta de validación confirmó `cantidad_filas = 1`, `monto_actual = 125000.00` y `estado_actual = paid`.

---

## 4. Transacciones y Consistencia del Watermark

### Relación entre la Carga y el Avance de la Marca de Agua
Uno de los errores más críticos en ingeniería de datos es actualizar la marca de agua antes de confirmar que los datos fueron escritos, o hacerlo fuera de la transacción de escritura.

* **Confirmación atómica (`BEGIN ... COMMIT`):** En nuestra implementación, el `INSERT ... ON CONFLICT` sobre `sales_curated` (1.688 registros extraídos) y el `UPDATE etl_watermarks` viven dentro de la misma transacción. La marca de agua (`2026-10-14 12:23:46.858877+00`) **solo avanzó cuando la escritura de todos los registros del lote finalizó con éxito**.
* **Recuperación ante fallos (`ROLLBACK`):** En la simulación de fallo donde se intentó alterar el monto a `99999999.99` y mover la marca de agua al año `2099-01-01`, la instrucción `ROLLBACK` revirtió ambos cambios de forma atómica, conservando intactos el monto `125000.00` y el watermark `2026-10-14 12:23:46.858877+00`.