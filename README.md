# Laboratorio: PostgreSQL para Data Engineering

Repositorio con la solución integral al laboratorio de Ingeniería de Datos sobre PostgreSQL contenerizado con Docker. Incluye análisis relacional y analítico (CTEs y funciones de ventana), optimización de rendimiento con evidencia mediante `EXPLAIN (ANALYZE, BUFFERS)`, estrategia de extracción incremental por marca de agua (*watermark*), escritura idempotente (`UPSERT`), control transaccional (`COMMIT`/`ROLLBACK`) y propuesta de arquitectura hacia Apache Airflow, Amazon S3 y Apache Spark.

---

## 1. Objetivo y Contexto

Construir un entorno 100% reproducible en Docker con PostgreSQL 15 para una empresa de comercio electrónico que registra **200 clientes** (`customers`) y **50.000 ventas** (`sales`), permitiendo:
* Consultar indicadores comerciales y tendencias analíticas sin depender de una instalación local de PostgreSQL.
* Diagnosticar planes de ejecución y demostrar mejoras reales de rendimiento con índices B-Tree.
* Implementar un flujo de extracción incremental seguro ante reintentos, fallos y registros tardíos.

---

## 2. Estructura del Repositorio

    /laboratorio-data-engineering
    ├── /sql
    │   ├── 01_sql_relacional.sql                        # JOINs (INNER vs LEFT), agregaciones y manejo de NULL con COALESCE
    │   ├── 02_sql_analitico.sql                         # CTEs y funciones de ventana (ROW_NUMBER, RANK, DENSE_RANK, LAG, Running Totals)
    │   ├── 03_rendimiento_indices.sql                   # Comparación de planes EXPLAIN (ANALYZE, BUFFERS) antes y después de índices
    │   └── 04_incremental_idempotencia_transacciones.sql # Watermarks, extracción incremental, UPSERT idempotente y COMMIT/ROLLBACK
    ├── /docs
    │   ├── evidencias_rendimiento.md                    # Evidencia empírica y análisis comparativo de planes de ejecución
    │   ├── decisiones_tecnicas.md                       # Justificación técnica de SQL, extracción incremental, idempotencia y transacciones
    │   └── arquitectura_propuesta.md                    # Diagrama e integración futura con Airflow, S3 y Spark vs SQL
    ├── .env.example                                     # Plantilla de variables de entorno (sin secretos reales)
    ├── .gitignore                                       # Exclusión de archivo .env y temporales
    ├── docker-compose.yml                               # Definición del servicio PostgreSQL 15, volumen persistente y healthcheck
    ├── postgresql_semilla_data_engineering.sql          # Script generador de datos semilla (200 clientes y 50.000 ventas)
    └── README.md                                        # Documentación principal de ejecución y validación

---

## 3. Requisitos Previos

* **Docker** y **Docker Compose** instalados y en ejecución (Docker Desktop en Windows/WSL2 o Docker Engine en Linux).
* **Git** para clonar y versionar el repositorio.
* **No se requiere** tener PostgreSQL ni `psql` instalados localmente en el sistema operativo anfitrión (todas las operaciones se ejecutan dentro del contenedor).

---

## 4. Guía Paso a Paso: Preparar, Iniciar y Validar el Entorno

### Paso 1: Clonar el repositorio y configurar variables de entorno
    git clone https://github.com/jhonnyelithAZ/laboratorio-data-engineering.git
    cd laboratorio-data-engineering
    cp .env.example .env

*(Opcional)* Edita el archivo `.env` con tus credenciales locales de prueba. Por defecto utiliza:
* `POSTGRES_USER=postgres`
* `POSTGRES_PASSWORD=admin123`
* `POSTGRES_DB=ecommerce_db`
* `POSTGRES_PORT=5432`

### Paso 2: Iniciar el contenedor con Docker Compose
    docker compose up -d

La primera vez que se inicia el contenedor con el volumen vacío, PostgreSQL ejecuta automáticamente el script `postgresql_semilla_data_engineering.sql` montado en `/docker-entrypoint-initdb.d/init.sql`.

### Paso 3: Validar la disponibilidad de PostgreSQL (`healthcheck`)
    docker ps

Verifica que el contenedor `de_postgres_lab` muestre en la columna `STATUS` el estado **`Up ... (healthy)`**.

### Paso 4: Validar la creación de tablas y el volumen de datos semilla
Ejecuta el siguiente comando para comprobar que existen los **200 clientes** y las **50.000 ventas**:
    docker exec -it de_postgres_lab psql -U postgres -d ecommerce_db -c "SELECT 'customers' AS tabla, COUNT(*) AS registros FROM customers UNION ALL SELECT 'sales', COUNT(*) FROM sales;"

Salida esperada:
    tabla   | registros 
   -----------+-----------
    customers |       200
    sales     |     50000
   (2 rows)

---

## 5. Ejecución de las Consultas SQL del Laboratorio

Cada bloque temático puede ejecutarse directamente contra el contenedor sin instalar clientes externos:

1. **SQL Relacional (JOINs, métricas comerciales y tratamiento de `NULL`):**
       docker exec -i de_postgres_lab psql -U postgres -d ecommerce_db < sql/01_sql_relacional.sql
2. **SQL Analítico (CTEs, rankings, `LAG` y acumulados):**
       docker exec -i de_postgres_lab psql -U postgres -d ecommerce_db < sql/02_sql_analitico.sql
3. **Rendimiento e Índices (`EXPLAIN ANALYZE` comparativo):**
       docker exec -i de_postgres_lab psql -U postgres -d ecommerce_db < sql/03_rendimiento_indices.sql
4. **Extracción Incremental, Idempotencia (`UPSERT`) y Transacciones (`COMMIT`/`ROLLBACK`):**
       docker exec -i de_postgres_lab psql -U postgres -d ecommerce_db < sql/04_incremental_idempotencia_transacciones.sql

---

## 6. Procedimiento para Reinicializar la Semilla y Detener el Entorno

> **ADVERTENCIA IMPORTANTE DE SEGURIDAD:**
> El script `postgresql_semilla_data_engineering.sql` contiene las sentencias destructivas `DROP TABLE IF EXISTS sales CASCADE;` y `DROP TABLE IF EXISTS customers CASCADE;`. **Elimina y recrea por completo las tablas y sus datos.** NUNCA debe ejecutarse en una base de datos de producción; su uso está estrictamente restringido a bases de datos locales o de pruebas limpias.

### Opción A: Reinicializar manualmente el script semilla sobre el contenedor activo
    docker exec -i de_postgres_lab psql -U postgres -d ecommerce_db < postgresql_semilla_data_engineering.sql

### Opción B: Recrear la base de datos desde cero limpiando el volumen Docker
Si deseas destruir el contenedor junto con su volumen persistente (`de_postgres_data`) y volver a levantar una instancia 100% limpia desde cero:
    docker compose down -v
    docker compose up -d

### Detener el entorno conservando los datos (Persistencia)
Para detener los contenedores sin borrar los datos almacenados en el volumen:
    docker compose down

*(Al volver a ejecutar `docker compose up -d`, los datos persistirán intactos).*

---

## 7. Problemas de Ejecución Más Comunes (Troubleshooting)

1. **Error `Bind for 0.0.0.0:5432 failed: port is already allocated`:**
   * **Causa:** Tienes otra instancia local de PostgreSQL u otro contenedor ocupando el puerto `5432` en tu máquina.
   * **Solución:** Cambia `POSTGRES_PORT=5433` en tu archivo `.env` y ejecuta `docker compose up -d`.
2. **Las tablas no aparecen al iniciar con `docker compose up -d`:**
   * **Causa:** El volumen `de_postgres_data` fue creado previamente cuando el archivo semilla estaba vacío (PostgreSQL solo ejecuta `/docker-entrypoint-initdb.d/` cuando el directorio de datos está vacío por primera vez).
   * **Solución:** Ejecuta `docker compose down -v` seguido de `docker compose up -d`.
3. **El estado del contenedor dice `(health: starting)`:**
   * **Causa:** PostgreSQL está terminando de insertar las 50.000 filas iniciales.
   * **Solución:** Espera entre 5 y 10 segundos y vuelve a verificar con `docker ps` hasta que indique `(healthy)`.

---

## 8. Documentación Técnica Detallada

* [Evidencias y Análisis de Rendimiento (`EXPLAIN ANALYZE`)](./docs/evidencias_rendimiento.md)
* [Decisiones Técnicas: SQL, Extracción Incremental, Idempotencia y Transacciones](./docs/decisiones_tecnicas.md)
* [Arquitectura Propuesta: PostgreSQL, Airflow, Spark y S3](./docs/arquitectura_propuesta.md)