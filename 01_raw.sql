-- Ler parquet e Criar tabela bruta no banco
SELECT * FROM read_parquet('yellow_tripdata_2024-01.parquet') LIMIT 50;

SELECT COUNT(*) FROM read_parquet('yellow_tripdata_2024-01.parquet');

CREATE OR REPLACE TABLE raw_yellow_tripdata AS 
SELECT * FROM read_parquet('yellow_tripdata_2024-01.parquet');

--- Criar tabela de lookup no banco para fase de staging e modelagem
CREATE OR REPLACE TABLE taxi_zone_lookup AS 
SELECT * FROM read_csv('taxi_zone_lookup.csv');