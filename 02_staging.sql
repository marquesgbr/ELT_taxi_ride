-- Ler tabela bruta do banco e fazer investigação/tratamento dos dados (profiling e cleanining)

SELECT * FROM raw_yellow_tripdata LIMIT 10;

CREATE OR REPLACE TABLE profilling_stats_summary AS SELECT * FROM (SUMMARIZE raw_yellow_tripdata);

-- Ler estatísticas de profiling para basear as regras de limpeza
SELECT * FROM profilling_stats_summary;

/* Checagem de duplicatas */
CREATE OR REPLACE TABLE dupe_rows AS 
SELECT *, COUNT(*) as qtd_duplicatas
FROM raw_yellow_tripdata
GROUP BY *
HAVING COUNT(*) > 1 ORDER BY qtd_duplicatas DESC;

SELECT * FROM dupe_rows;
-- Sem linhas duplicadas


/* Valores nulos (colunas que aparecem com nulos no profilling_stats_summary) */


CREATE OR REPLACE TABLE count_rows_nulls AS
SELECT 
    COALESCE(payment_type, 'Nulo na Fonte') AS tipo_pagamento,
    COUNT(*) AS total_registros,
    SUM(CASE WHEN passenger_count IS NULL THEN 1 ELSE 0 END) AS nulos_passageiros,
    SUM(CASE WHEN congestion_surcharge IS NULL THEN 1 ELSE 0 END) AS nulos_cobrança_congest,
    SUM(CASE WHEN Airport_fee IS NULL THEN 1 ELSE 0 END) AS nulos_taxa_aeroporto,
    SUM(CASE WHEN store_and_fwd_flag IS NULL THEN 1 ELSE 0 END) AS nulos_store_and_fwd_flag,
    SUM(CASE WHEN ratecodeid IS NULL THEN 1 ELSE 0 END) AS nulos_ratecode
FROM raw_yellow_tripdata
GROUP BY payment_type
ORDER BY payment_type;

SELECT * FROM count_rows_nulls;
-- Adicionar linhas com payment_type = 0 no rejected records.


/* Valores inconsistentes */

CREATE OR REPLACE TABLE not_feasiable_limits AS
SELECT 
    COUNT(*) AS total_corridas,
    SUM(CASE WHEN trip_distance <= 0 THEN 1 ELSE 0 END) AS distancia_zero_ou_negativa,
    SUM(CASE WHEN fare_amount < 0 THEN 1 ELSE 0 END) AS tarifa_negativa,
    SUM(CASE WHEN extra < 0 THEN 1 ELSE 0 END) AS extra_negativa,
    SUM(CASE WHEN mta_tax < 0 THEN 1 ELSE 0 END) AS mta_tax_negativa,
    SUM(CASE WHEN tip_amount < 0 THEN 1 ELSE 0 END) AS tip_amount_negativa,
    SUM(CASE WHEN tolls_amount < 0 THEN 1 ELSE 0 END) AS tolls_amount_negativa,
    SUM(CASE WHEN improvement_surcharge < 0 THEN 1 ELSE 0 END) AS improvement_surcharge_negativa,
    SUM(CASE WHEN total_amount < 0 THEN 1 ELSE 0 END) AS total_amount_negativa,
    SUM(CASE WHEN congestion_surcharge < 0 THEN 1 ELSE 0 END) AS congestion_surcharge_negativa,
    SUM(CASE WHEN Airport_fee < 0 THEN 1 ELSE 0 END) AS Airport_fee_negativa,
    SUM(CASE WHEN passenger_count > 5 OR passenger_count <= 0 THEN 1 ELSE 0 END) AS qtd_passageiros_inconsist,
    SUM(CASE WHEN tpep_dropoff_datetime < tpep_pickup_datetime THEN 1 ELSE 0 END) AS dropoff_antes_pickup,
    
    -- Consideramos que uma viagem ocorre em janeiro de 2024 se, e somente se, partida e chegada ocorrerem dentro desse mês
    SUM(CASE WHEN tpep_pickup_datetime < '2024-01-01' THEN 1 ELSE 0 END) AS pickup_antes_2024_01_01,
    SUM(CASE WHEN tpep_pickup_datetime > '2024-02-01' THEN 1 ELSE 0 END) AS pickup_apos_2024_02_01,
    SUM(CASE WHEN tpep_dropoff_datetime < '2024-01-01' THEN 1 ELSE 0 END) AS dropoff_antes_2024_01_01,
    SUM(CASE WHEN tpep_dropoff_datetime > '2024-02-01' THEN 1 ELSE 0 END) AS dropoff_apos_2024_02_01
FROM raw_yellow_tripdata;

SELECT * FROM not_feasiable_limits;

/* 
Calcular quartis para as colunas numericas contínuas e criar tabela com os limites de IQR de cada uma.
Formato de uma tabela de parâmetros de linha única.
Colunas a serem analisadas:
    - trip_distance
    - fare_amount
    - extra
    - mta_tax
    - tip_amount
    - tolls_amount
    - improvement_surcharge
    - total_amount
    - congestion_surcharge
    - Airport_fee
*/
CREATE OR REPLACE TABLE iqr_continuous AS
WITH limites AS (
    SELECT 
        -- Fare Amount
        QUANTILE_CONT(fare_amount, 0.25) AS q1_fare_amount,
        QUANTILE_CONT(fare_amount, 0.75) AS q3_fare_amount,
        (QUANTILE_CONT(fare_amount, 0.75) - QUANTILE_CONT(fare_amount, 0.25)) * 1.5 AS iqr_fare_amount,

        -- Trip Distance
        QUANTILE_CONT(trip_distance, 0.25) AS q1_trip_distance,
        QUANTILE_CONT(trip_distance, 0.75) AS q3_trip_distance,
        (QUANTILE_CONT(trip_distance, 0.75) - QUANTILE_CONT(trip_distance, 0.25)) * 1.5 AS iqr_trip_distance,

        -- Extra
        QUANTILE_CONT(extra, 0.25) AS q1_extra,
        QUANTILE_CONT(extra, 0.75) AS q3_extra,
        (QUANTILE_CONT(extra, 0.75) - QUANTILE_CONT(extra, 0.25)) * 1.5 AS iqr_extra,

        -- MTA Tax
        QUANTILE_CONT(mta_tax, 0.25) AS q1_mta_tax,
        QUANTILE_CONT(mta_tax, 0.75) AS q3_mta_tax,
        (QUANTILE_CONT(mta_tax, 0.75) - QUANTILE_CONT(mta_tax, 0.25)) * 1.5 AS iqr_mta_tax,

        -- Tip Amount
        QUANTILE_CONT(tip_amount, 0.25) AS q1_tip_amount,
        QUANTILE_CONT(tip_amount, 0.75) AS q3_tip_amount,
        (QUANTILE_CONT(tip_amount, 0.75) - QUANTILE_CONT(tip_amount, 0.25)) * 1.5 AS iqr_tip_amount,

        -- Tolls Amount
        QUANTILE_CONT(tolls_amount, 0.25) AS q1_tolls_amount,
        QUANTILE_CONT(tolls_amount, 0.75) AS q3_tolls_amount,
        (QUANTILE_CONT(tolls_amount, 0.75) - QUANTILE_CONT(tolls_amount, 0.25)) * 1.5 AS iqr_tolls_amount,

        -- Improvement Surcharge
        QUANTILE_CONT(improvement_surcharge, 0.25) AS q1_improvement_surcharge,
        QUANTILE_CONT(improvement_surcharge, 0.75) AS q3_improvement_surcharge,
        (QUANTILE_CONT(improvement_surcharge, 0.75) - QUANTILE_CONT(improvement_surcharge, 0.25)) * 1.5 AS iqr_improvement_surcharge,

        -- Total Amount
        QUANTILE_CONT(total_amount, 0.25) AS q1_total_amount,
        QUANTILE_CONT(total_amount, 0.75) AS q3_total_amount,
        (QUANTILE_CONT(total_amount, 0.75) - QUANTILE_CONT(total_amount, 0.25)) * 1.5 AS iqr_total_amount,

        -- Congestion Surcharge
        QUANTILE_CONT(congestion_surcharge, 0.25) AS q1_congestion_surcharge,
        QUANTILE_CONT(congestion_surcharge, 0.75) AS q3_congestion_surcharge,
        (QUANTILE_CONT(congestion_surcharge, 0.75) - QUANTILE_CONT(congestion_surcharge, 0.25)) * 1.5 AS iqr_congestion_surcharge,

        -- Airport Fee
        QUANTILE_CONT(Airport_fee, 0.25) AS q1_Airport_fee,
        QUANTILE_CONT(Airport_fee, 0.75) AS q3_Airport_fee,
        (QUANTILE_CONT(Airport_fee, 0.75) - QUANTILE_CONT(Airport_fee, 0.25)) * 1.5 AS iqr_Airport_fee

    FROM raw_yellow_tripdata
    WHERE fare_amount > 0 AND trip_distance > 0
)
SELECT * FROM limites;



--- Aqui removemos as duplicatas aplicando as regras de limpeza
CREATE OR REPLACE TABLE staging_limpa AS 
SELECT * FROM raw_yellow_tripdata
WHERE (regras);