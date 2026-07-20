-- Ler tabela bruta do banco e fazer investigação/tratamento dos dados (profiling e preprocessing)


CREATE OR REPLACE TABLE profilling_stats_summary AS SELECT * FROM (SUMMARIZE raw_yellow_tripdata);

SELECT * FROM profilling_stats_summary;

-- Valores nulos 
SELECT 
    COUNT(*) AS total_registros,
    SUM(CASE WHEN passenger_count IS NULL THEN 1 ELSE 0 END) AS nulos_passageiros,
    SUM(CASE WHEN congestion_surcharge IS NULL THEN 1 ELSE 0 END) AS nulos_cobrança_congest,
    SUM(CASE WHEN Airport_fee IS NULL THEN 1 ELSE 0 END) AS nulos_taxa_aeroporto,
    SUM(CASE WHEN store_and_fwd_flag IS NULL THEN 1 ELSE 0 END) AS nulos_store_and_fwd_flag,
    SUM(CASE WHEN ratecodeid IS NULL THEN 1 ELSE 0 END) AS nulos_ratecode
FROM raw_yellow_tripdata;


-- Valores inconsistentes
SELECT 
    COUNT(*) AS total_corridas,
    SUM(CASE WHEN trip_distance <= 0 THEN 1 ELSE 0 END) AS distancia_zero_ou_negativa,
    SUM(CASE WHEN fare_amount < 0 THEN 1 ELSE 0 END) AS tarifa_negativa,
    SUM(CASE WHEN passenger_count > 8 THEN 1 ELSE 0 END) AS excesso_passageiros
FROM raw_yellow_tripdata;
