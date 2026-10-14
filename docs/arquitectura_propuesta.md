# Arquitectura Propuesta para el Pipeline de Ingeniería de Datos

Este documento describe cómo evoluciona el entorno transaccional actual en PostgreSQL hacia una arquitectura moderna de Data Lakehouse utilizando **Apache Airflow**, **Amazon S3** y **Apache Spark**, justificando técnicamente el rol de cada componente.

---

## 1. Diagrama de Arquitectura del Pipeline

    +-------------------------------------------------------------------+
    | 1. ORQUESTACIÓN Y CONTROL: Apache Airflow                         |
    |    - Programa ejecuciones (DAGs), gestiona reintentos y alertas   |
    |    - Lee y actualiza el Watermark solo tras confirmación exitosa  |
    +-------------------------------------------------------------------+
         |                           |                           |
         v (Extrae lote)             v (Almacena Parquet)        v (Transforma)
    +--------------------+     +--------------------+     +--------------------+
    | 2. FUENTE OLTP     |     | 3. DATA LAKE (S3)  |     | 4. PROCESAMIENTO   |
    | PostgreSQL 15      | --> | - Capa Bronze (Raw)| --> | - SQL / Python     |
    | - customers        |     | - Capa Silver      |     |   (Volumen bajo/med)|
    | - sales            |     | - Capa Gold (BI)   |     | - Apache Spark     |
    | (Índice updated_at)|     | (Formato Parquet)  |     |   (Alto volumen)   |
    +--------------------+     +--------------------+     +--------------------+

---

## 2. Rol de Cada Componente en la Arquitectura

### 1. PostgreSQL (Base de Datos Operacional / OLTP)
* **Rol:** Sistema fuente donde la aplicación de comercio electrónico registra en tiempo real las transacciones (`customers` y `sales`) garantizando propiedades ACID.
* **Responsabilidad en el pipeline:** Proveer lecturas incrementales rápidas gracias al índice `idx_sales_updated_at`, evitando bloqueos o sobrecarga sobre la operación comercial.

### 2. Apache Airflow (Orquestador de Flujos de Trabajo)
* **Rol:** Cerebro de programación (*scheduling*), gestión de dependencias entre tareas (DAGs), manejo automático de reintentos (*retries* con *exponential backoff*), SLA y alertas ante fallos.
* **Diferencia clave frente al procesamiento distribuido:** **Airflow NO es un motor de procesamiento de datos.** Airflow no debe cargar millones de filas en su propia memoria para transformarlas; su función es coordinar *cuándo* y *en qué orden* se ejecutan las tareas, delegando el trabajo pesado a PostgreSQL, S3 o Spark, y actualizando la marca de agua (`watermark`) solo cuando las tareas previas terminan en estado `SUCCESS`.

### 3. Amazon S3 (Almacenamiento de Objetos / Data Lake)
* **Rol:** Capa de almacenamiento desacoplada, económica y altamente durable. Permite almacenar datos históricos e incrementales en formatos columnares comprimidos como **Apache Parquet** (o tablas abiertas como Delta Lake / Apache Iceberg) organizados bajo una arquitectura Medallion:
  * **Bronze (Raw):** Volcado exacto de los lotes incrementales extraídos de PostgreSQL, particionados por fecha de ingesta (`year=YYYY/month=MM/day=DD/`), permitiendo reprocesamiento histórico en caso de errores lógicos.
  * **Silver (Clean/Conformed):** Datos limpios, tipados y deduplicados por clave de negocio (`order_id`).
  * **Gold (Analytics/Curated):** Tablas listas para consumo en BI (ventas por ciudad, cohortes de clientes, rankings).

### 4. Apache Spark (Motor de Procesamiento Distribuido)
* **Rol:** Motor de cómputo en clúster diseñado para procesar grandes volúmenes de datos en paralelo dividiendo el trabajo en múltiples nodos (*executors*).
* **Responsabilidad en el pipeline:** Ejecutar transformaciones masivas, *merges* (UPSERTs sobre Parquet/Delta/Iceberg en S3) y cruces complejos cuando el volumen supera la capacidad de un nodo único.

---

## 3. Justificación Técnica: ¿Cuándo basta con SQL/Procesos Sencillos y cuándo se necesita Apache Spark?

Una decisión fundamental de Ingeniería de Datos es **evitar la sobreingeniería**. Levantar un clúster de Spark tiene un costo de infraestructura y un tiempo de arranque (*overhead* de JVM y distribución de red) que no se justifica para volúmenes pequeños.

| Criterio | Cuándo es suficiente SQL / Python Ligero | Cuándo se justifica Apache Spark (Distribuido) |
| :--- | :--- | :--- |
| **Volumen de Datos** | **Bajo a Mediano** (desde miles de filas hasta algunas decenas de millones, p. ej., < 10-20 GB por lote). | **Alto Volumen / Big Data** (cientos de millones o miles de millones de filas; lotes de decenas de GB a múltiples TB). |
| **Escenario actual del Laboratorio (50.000 ventas)** | **100% suficiente con PostgreSQL y SQL.** Como demostró nuestro `EXPLAIN ANALYZE`, PostgreSQL procesa e indexa 50.000 ventas en **< 1 milisegundo (0.593 ms)**. Usar Spark aquí sería contraproducente y más lento por el tiempo de inicialización del clúster. | No requerido para el volumen actual de la semilla. |
| **Fuentes de Datos** | Datos estructurados que residen en una misma base de datos relacional o Data Warehouse. | Cruce masivo de fuentes heterogéneas en el Data Lake (logs semiestructurados JSON de clickstream en S3 + tablas transaccionales + feeds externos). |
| **Escalabilidad** | Escala verticalmente (más CPU/RAM al servidor de base de datos). | Escala horizontalmente agregando nodos trabajadores al clúster sin afectar a la base de datos transaccional. |

### Conclusión para el Caso de Uso
1. **En la etapa actual (50.000 ventas y 200 clientes):** La solución óptima, más rápida y rentable es usar **SQL nativo en PostgreSQL** (con los índices `idx_sales_created_at` y `idx_sales_updated_at`) orquestado por un job ligero en Python/Airflow que deposite respaldos Parquet en S3.
2. **En una etapa futura de crecimiento masivo:** Cuando la empresa escale a decenas de millones de transacciones diarias o necesite cruzar las ventas con millones de eventos de navegación web almacenados en S3, **Apache Spark** entrará a procesar las capas Bronze -> Silver -> Gold directamente sobre S3, liberando a PostgreSQL de toda carga analítica.