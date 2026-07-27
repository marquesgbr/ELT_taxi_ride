-- Ler tabela bruta do banco e fazer investigação/tratamento dos dados (profiling e cleanining)

/* 
    1. Sumarizar estatísticas de profiling 
    2. Checar duplicatas
    3. Checar valores nulos
    4. Checar valores inconsistentes (negativos, passageiros > 5, datetime de dropoff antes do pickup, etc)
    5. Checar outliers (valores muito discrepantes)
*/

/* Investigação do formato da tabela */
SELECT * FROM raw_yellow_tripdata LIMIT 10;

CREATE OR REPLACE TABLE profilling_stats_summary AS SELECT * FROM (SUMMARIZE raw_yellow_tripdata);

-- Ler estatísticas de profiling para basear as regras de limpeza
SELECT * FROM profilling_stats_summary;


/* Checagem de duplicatas */

-- Duplicatas exatas (todas as colunas iguais)
SELECT *, COUNT(*) as qtd_duplicatas
FROM raw_yellow_tripdata
GROUP BY *
HAVING COUNT(*) > 1 ORDER BY qtd_duplicatas DESC;

-- Sem linhas duplicatas exatas


-- Duplicatas parciais 

-- Mesmo datetime e locatização de pickup e dropoff, mesma distância e valores monetários inclusive em sinal
SELECT 
    payment_type, 
    tpep_dropoff_datetime, 
    tpep_pickup_datetime, 
    PULocationID, DOLocationID, 
    trip_distance, fare_amount, tip_amount, total_amount, 
    COUNT(*) AS qtd_duplicatas
FROM raw_yellow_tripdata
GROUP BY payment_type, tpep_dropoff_datetime, tpep_pickup_datetime, PULocationID, DOLocationID, trip_distance, fare_amount, tip_amount, total_amount
HAVING COUNT(*) > 1
ORDER BY qtd_duplicatas DESC;


-- Mesmo datetime e localização de pickup e dropoff, mesma distância e 
-- valores monetários em módulo, porém podendo ter sinais diferentes
CREATE OR REPLACE TABLE partial_dupe_rows AS
SELECT 
    payment_type, 
    tpep_dropoff_datetime, tpep_pickup_datetime, 
    PULocationID, DOLocationID, 
    trip_distance, abs(fare_amount), abs(tip_amount), abs(total_amount), 
    COUNT(*) AS qtd_duplicatas
FROM raw_yellow_tripdata
GROUP BY payment_type, tpep_dropoff_datetime, tpep_pickup_datetime, PULocationID, DOLocationID, trip_distance, abs(fare_amount), abs(tip_amount), abs(total_amount)
HAVING COUNT(*) > 1
ORDER BY qtd_duplicatas DESC;


SELECT * FROM partial_dupe_rows;
-- 30k pares de linhas com valores exatos de tempo e localização para DO e PU e distancia, mas valores montetários que diferem apenas no sinal. 
-- Isso pode ser um erro de registro do aparelho que registra a corrida ou algum estorno/contestação. 

-- Corridas contestadas ou que houve estorno 
SELECT * FROM partial_dupe_rows
WHERE payment_type IN (3, 4);

-- Corridas com pagamento em dinheiro (1) ou cartão de crédito (2) que possuem duplicatas parciais
-- Possivelmente erros de registro ou cancelamento do motorista, mas que não foram contestadas ou estornadas.
SELECT * FROM partial_dupe_rows
WHERE payment_type IN (1, 2);

/*
Conclusão: Rejeitar linhas com valores negativos e manter apenas os positivos para análise. 
Lidar com payment_type 3 e 4 (contestadas ou estornadas) de forma separada nas consultas, 
pois podem ter propósitos diferentes, como análise de fraude ou estorno de valores.
*/


/* Valores nulos (colunas que aparecem com nulos no profilling_stats_summary) */
SELECT * FROM raw_yellow_tripdata
WHERE payment_type = 0;

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

/*
Conclusão: Fazer imputação de valores nulos na coluna de passenger_count com a mediana da variável.
Substituir RatecodeID nulo por 99 de acordo com o dicionário de dados.
O restante das colunas são candidatas a serem rejeitadas da tabela fato por já não terem 
informações tão cruciais para o propósito do modelo final, que visa analisar padrões de comportamento e tendências.
*/


/* Valores inconsistentes */

CREATE OR REPLACE TABLE count_not_feasiable_limits AS
SELECT
    COUNT(*) AS total_corridas,
    SUM(CASE WHEN trip_distance <= 0 THEN 1 ELSE 0 END) AS distancia_zero_ou_negativa,
    SUM(CASE WHEN passenger_count > 5 OR passenger_count <= 0 THEN 1 ELSE 0 END) AS qtd_passageiros_inconsist,
    
    SUM(CASE WHEN fare_amount < 0 THEN 1 ELSE 0 END) AS tarifa_negativa,
    SUM(CASE WHEN tip_amount < 0 THEN 1 ELSE 0 END) AS tip_amount_negativa,
    SUM(CASE WHEN total_amount < 0 THEN 1 ELSE 0 END) AS total_amount_negativa,
    
    SUM(CASE WHEN extra < 0 THEN 1 ELSE 0 END) AS extra_negativa,
    SUM(CASE WHEN mta_tax < 0 THEN 1 ELSE 0 END) AS mta_tax_negativa,
    SUM(CASE WHEN tolls_amount < 0 THEN 1 ELSE 0 END) AS tolls_amount_negativa,
    SUM(CASE WHEN improvement_surcharge < 0 THEN 1 ELSE 0 END) AS improvement_surcharge_negativa,
    SUM(CASE WHEN congestion_surcharge < 0 THEN 1 ELSE 0 END) AS congestion_surcharge_negativa,
    SUM(CASE WHEN Airport_fee < 0 THEN 1 ELSE 0 END) AS Airport_fee_negativa,
    
    SUM(CASE WHEN PULocationID < 1 OR PULocationID > 265 THEN 1 ELSE 0 END) AS PULocationID_invalido,
    SUM(CASE WHEN DOLocationID < 1 OR DOLocationID > 265 THEN 1 ELSE 0 END) AS DOLocationID_invalido,
    SUM(CASE WHEN tpep_dropoff_datetime < tpep_pickup_datetime THEN 1 ELSE 0 END) AS dropoff_antes_pickup,
    -- Consideramos que uma viagem ocorre em janeiro de 2024 se, e somente se, partida e chegada ocorrerem dentro desse mês
    SUM(CASE WHEN tpep_pickup_datetime < '2024-01-01' THEN 1 ELSE 0 END) AS pickup_antes_2024_01_01,
    SUM(CASE WHEN tpep_pickup_datetime > '2024-02-01' THEN 1 ELSE 0 END) AS pickup_apos_2024_02_01,
    SUM(CASE WHEN tpep_dropoff_datetime < '2024-01-01' THEN 1 ELSE 0 END) AS dropoff_antes_2024_01_01,
    SUM(CASE WHEN tpep_dropoff_datetime > '2024-02-01' THEN 1 ELSE 0 END) AS dropoff_apos_2024_02_01
FROM raw_yellow_tripdata;

SELECT * FROM count_not_feasiable_limits;


-- Investigar corridas com qtd de passageiros inconsistentes 
SELECT * FROM raw_yellow_tripdata
WHERE passenger_count > 6;
/*Com exceção de 1 corrida, todas marcadas como Negotiated fare (5), possivelmente motoristas 
que aceitaram mais passageiros do que o permitido sob certas condições.
Vamos manter essas linhas na tabela fato.
*/

SELECT * FROM raw_yellow_tripdata
WHERE passenger_count >= 6 AND RatecodeID <> 5;
/* Maioria marcados como Standard Rate (1), possivelmente motoristas 
que aceitaram mais passageiros do que o permitido sem condições adicionais.
Vamos manter essas linhas na tabela fato.
*/

SELECT * FROM raw_yellow_tripdata
WHERE passenger_count = 0;
-- Para essas corridas, também vamos fazer uma imputação usando a mediana da variável, pois quaisquer outra inconsistências
-- de quantia da corrida, ratecode, localização, tempo, etc. serão tratadas pelas demais regras de limpeza. 

/*
Mais linhas com valores de tarifa negativos, que podem não ter uma duplicata, podem ser na verdade
valores válidos, mas o aparelho que registra a viagem fez uma inversão de sinal. 
*/
CREATE OR REPLACE TABLE negative_amounts AS
SELECT * FROM raw_yellow_tripdata
WHERE fare_amount < 0 OR tip_amount < 0 OR total_amount < 0;

SELECT * FROM negative_amounts;
/* 
37k linhas das quais sabemos que cerca de 30k são duplicatas parciais de outra linha com o mesmo valor positivo, nos restando 7k
sem duplicatas parciais, que podem ser valores válidos ou não dependendendo do caso (como um erro de registro do 
taxímetro ou outro fator).
Conclusão: Para todos os efeitos, vamos desconsiderar essas linhas na tabela fato pela mesma 
regra das duplicatas parciais, que é manter apenas os valores positivos.
*/




/* 
Calcular quartis para as colunas numericas contínuas e criar tabela com os limites de IQR de cada uma.
Formato de uma tabela de parâmetros de linha única.
Colunas a serem analisadas:
    - trip_distance
    - fare_amount
    - tip_amount
    - total_amount
*/
CREATE OR REPLACE TABLE iqr_values AS
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

        -- Tip Amount
        QUANTILE_CONT(tip_amount, 0.25) AS q1_tip_amount,
        QUANTILE_CONT(tip_amount, 0.75) AS q3_tip_amount,
        (QUANTILE_CONT(tip_amount, 0.75) - QUANTILE_CONT(tip_amount, 0.25)) * 1.5 AS iqr_tip_amount,

        -- Total Amount
        QUANTILE_CONT(total_amount, 0.25) AS q1_total_amount,
        QUANTILE_CONT(total_amount, 0.75) AS q3_total_amount,
        (QUANTILE_CONT(total_amount, 0.75) - QUANTILE_CONT(total_amount, 0.25)) * 1.5 AS iqr_total_amount,

    FROM raw_yellow_tripdata
    WHERE 
)
SELECT * FROM limites;



--- Aqui removemos as duplicatas aplicando as regras de limpeza
CREATE OR REPLACE TABLE staging_limpa AS 
SELECT * FROM raw_yellow_tripdata
WHERE (regras);