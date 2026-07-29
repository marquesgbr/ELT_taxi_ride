/* 
Criação da Tabela Fato 
*/

CREATE OR REPLACE TABLE fact_tb_trips AS
SELECT 
    -- 1. CHAVES ESTRANGEIRAS (FKs) PARA AS DIMENSÕES
    
    -- FK para dim_data (Formato YYYYMMDD para pickup e dropoff)
    CAST(STRFTIME(s.tpep_pickup_datetime, '%Y%m%d') AS INT) AS id_date_pickup,
    CAST(STRFTIME(s.tpep_dropoff_datetime, '%Y%m%d') AS INT) AS id_date_dropoff,
    
    -- FK para dim_localizacao (Role-Playing: embarque e desembarque)
    s.PULocationID AS id_location_pickup,
    s.DOLocationID AS id_location_dropoff,
    
    -- FK para dim_payment
    s.payment_type AS id_payment,
    
    -- FK para dim_junk (Resgatada via JOIN com a Junk Dimension)
    j.id_junk,

    -- 2. ATRIBUTOS TEMPORAIS DE GRANULARIDADE DA FATO
    s.tpep_pickup_datetime,
    s.tpep_dropoff_datetime,
    HOUR(s.tpep_pickup_datetime) AS hour_pickup,
    HOUR(s.tpep_dropoff_datetime) AS hour_dropoff,
    
    -- Métrica Derivada: Duração da viagem em minutos
    ROUND(DATEDIFF('second', s.tpep_pickup_datetime, s.tpep_dropoff_datetime) / 60.0, 2) AS duration_minutes,

    -- 3. MEDIDAS ADITIVAS (Métricas financeiras e outros)
    s.passenger_count,
    s.trip_distance,
    s.fare_amount,
    s.tip_amount,
    s.tolls_amount,
    s.mta_tax,
    s.congestion_surcharge,
    s.Airport_fee,
    s.total_amount

FROM staging_cleanse s

-- JOIN com a Junk Dimension (batendo os 3 atributos)
JOIN dim_junk j 
  ON s.VendorID = j.id_vendor 
 AND s.RatecodeID = j.id_ratecode 
 AND s.store_and_fwd_flag = j.store_and_fwd_flag;

