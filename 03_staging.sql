-- Criar tabelas de staging baseado nas análises de profiling (fase de cleasing e transformação de dados) 


/* 
Calcular quartis para as colunas numericas contínuas que estarão na tabela fato e criar tabela com os limites de IQR de cada uma.
Formato de uma tabela de parâmetros de linha única. 
Tolls_amount foi excluída por nem sempre precisar ser paga, portanto resultaria num IQR = 0.
Colunas a serem analisadas:
    - trip_distance
    - fare_amount
    - tip_amount
    - total_amount
*/
CREATE OR REPLACE TABLE iqr_values AS
WITH boundaries AS (
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
    WHERE fare_amount > 0 AND trip_distance > 0 AND tip_amount >= 0 AND total_amount > 0
)
SELECT * FROM boundaries;



/*
Recapitulação de decisões da fase de perfilamento:
1. Para as colunas Airport_fee, MTA_tax e Congestion_surcharge será considerado apenas os valores fixos que podem ser cobrados ou zero. 
    Logo essas variáveis precisam estar nestes respectivos conjuntos de valores:
    Airport_fee: {0, 1.75}
    MTA_tax: {0, 0.5}
    Congestion_surcharge: {0, 2.5}
2. Rejeitar linhas com valores negativos e manter apenas os positivos para análise. 
3. Vamos fazer a imputação de valores nulos (linhas onde payment_type = 0) de acordo com a regra de negócio. 
    Regra 1: total_amount = fare_amount + tip_amount + extra + tolls_amount + mta_tax + improvement_surcharge + 2.5 (taxa de congestionamento)
    Regra 2: total_amount = fare_amount + tip_amount + extra + tolls_amount + mta_tax + improvement_surcharge + 0 (somente as taxas de MTA_tax e improvement_surcharge)
    Regra 3: Rejeitar linhas que não se encaixam em nenhuma das duas regras acima.
    Onde:
    Congestion_surcharge = 2.5 e Airport_fee = 0 para as linhas que seguem a regra 1 e 
    Congestion_surcharge = 0 e Airport_fee = 0 para as linhas que seguem a regra 2. 
4. Na coluna de passenger_count, fazer imputação de valores nulos ou iguais a zero com a mediana da variável.
5. Substituir RatecodeID nulo por 99 de acordo com o dicionário de dados.
6. store_and_fwd_flag sofre imputação por moda
7. Limpeza de valores discrepantemente altos nas variáveis numéricas contínuas usando IQR para cada uma.
8. Optou-se por não rejeitar corridas com alto número de passageiros (ex: 7, 8, 9).
    O propósito é manter edge cases de corridas que possam ter ocorrido de fato, mas em veículos maiores e/ou sob negociação com o taxista.
    Como evidência, o perfilamento mostrou que algumas dessas corridas possuem RatecodeID = 5 (Negotiated Fare).
9. Usar regras de consistência de localização e tempo:
    Local:
    Rejeitar PULocationID ou DOLocationID que não existam na tabela oficial de zonas (taxi_zone_lookup)

    Tempo:
    tpep_dropoff_datetime < tpep_pickup_datetime -> não podemos ter dropoff antes pickup
    Consideramos que uma viagem ocorre em janeiro de 2024 se, e somente se, partida e chegada ocorrerem dentro desse mês:
    tpep_pickup_datetime < '2024-01-01'   -> início da viagem antes de 2024-01-01,
    tpep_pickup_datetime > '2024-02-01'   -> início da viagem após 2024-02-01,
    tpep_dropoff_datetime < '2024-01-01'  -> final da viagem antes de 2024-01-01,
    tpep_dropoff_datetime > '2024-02-01'  -> final da viagem após 2024-02-01
10. Variáveis que não pertencerão à tabela fato:
    - improvement_surcharge
    - extra
    As razões não foram baseadas somente na análise de perfilamento, mas também em decisões de negócio. Essas variáveis
    são valores que não possuem significado atrelado (extra) e ou cobranças fixas do governo (improvement_surcharge) que não são relevantes para o modelo final.
    Visto que elas estão ali pelo propósito de auditoria, elas não serão consideradas na tabela fato que será usada para análises de negócio.
11. Transformações de tipo de dados:
    - store_and_fwd_flag: de string para booleano
    - Variáveis do tipo Double para DECIMAL(10,2): 
        - fare_amount
        - tip_amount
        - tolls_amount
        - total_amount
        - mta_tax
        - congestion_surcharge
        - airport_fee
*/


CREATE OR REPLACE TABLE staging_cleanse AS 

-- 1. Já averiguamos que não há duplicatas exatas, mas essa etapa previne possíveis casos futuros de duplicatas exatas. 
WITH data_no_dupes AS (
    SELECT DISTINCT * FROM raw_yellow_tripdata
),

-- 2. Calculo dinamico de moda e mediana para imputação de valores
dynamic_stats AS (
    SELECT 
        MEDIAN(passenger_count) AS med_passengers, 
        MODE(store_and_fwd_flag) AS mode_flag
    FROM data_no_dupes
),

-- 3. Trazer as estatísticas para manipulação
data_boundaries AS (
    SELECT t.*, b.*, s.*
    FROM data_no_dupes t, iqr_values b, dynamic_stats s
),

-- 4. Imputação de valores substituindo a coluna atual pela coluna limpa
data_imputed AS (
    SELECT 
    * EXCLUDE (RatecodeID, passenger_count, store_and_fwd_flag, congestion_surcharge, Airport_fee, mode_flag, med_passengers),

    -- Dados nulos
    COALESCE(RatecodeID, 99) AS RatecodeID,
    COALESCE(NULLIF(passenger_count, 0), med_passengers) AS passenger_count, -- Imputando para nulo ou zero passageiros
    CASE
        WHEN COALESCE(store_and_fwd_flag, mode_flag) = 'Y' THEN TRUE ELSE FALSE
    END AS store_and_fwd_flag,

    CASE 
        WHEN payment_type = 0 AND ROUND(total_amount - fare_amount - tip_amount - extra - tolls_amount - mta_tax - improvement_surcharge, 2) = 2.50 THEN 2.50
        ELSE COALESCE(congestion_surcharge, 0.0)
    END AS congestion_surcharge,

    CASE 
        WHEN payment_type = 0 AND ROUND(total_amount - fare_amount - tip_amount - extra - tolls_amount - mta_tax - improvement_surcharge, 2) = 2.50 THEN 0.0
        ELSE COALESCE(Airport_fee, 0.0)
    END AS Airport_fee

    FROM data_boundaries
), 

-- 5. Filtrar valores negativos
data_filter_negative AS (
    SELECT * FROM data_imputed
    WHERE 
        fare_amount > 0 
    AND trip_distance > 0 
    AND total_amount > 0
    AND tip_amount >= 0
    AND tolls_amount >= 0
    AND mta_tax >= 0
    AND congestion_surcharge >= 0
    AND Airport_fee >= 0
    AND improvement_surcharge >= 0
    AND extra >= 0
),

-- 6. Filtrar inconsistências de tempo
data_filter_time AS (
    SELECT * FROM data_filter_negative
    WHERE
        tpep_pickup_datetime < tpep_dropoff_datetime 
    AND tpep_pickup_datetime >= '2024-01-01' AND tpep_pickup_datetime < '2024-02-01' 
    AND tpep_dropoff_datetime >= '2024-01-01' AND tpep_dropoff_datetime < '2024-02-01'
),


-- 7. Filtrar por restrições de domínio
data_filter_domain_constraints AS (
    SELECT * FROM data_filter_time
    WHERE
        -- Regras de domínio
            mta_tax IN (0.0, 0.50)
        AND Airport_fee IN (0.0, 1.75)
        AND congestion_surcharge IN (0.0, 2.50)

        -- Outliers por IQR
        AND fare_amount <= (q3_fare_amount + 1.5*iqr_fare_amount)
        AND trip_distance <= (q3_trip_distance + 1.5*iqr_trip_distance)
        AND tip_amount <= (q3_tip_amount + 1.5*iqr_tip_amount)
        AND total_amount <= (q3_total_amount + 1.5*iqr_total_amount) 

        -- Exclusão de instâncias Flex Fare onde não houve conciliação 
        AND NOT (
            payment_type = 0 AND 
            ROUND(total_amount - fare_amount - tip_amount - extra - tolls_amount - mta_tax - improvement_surcharge, 2) NOT IN (0.0, 2.50)
        )

        -- Integridade Referencial de Zonas
        AND PULocationID IN (SELECT LocationID FROM taxi_zone_lookup)
        AND DOLocationID IN (SELECT LocationID FROM taxi_zone_lookup)
)


SELECT -- Aqui não incluiremos improvement_surcharge e extra
    CAST(VendorID AS INT) AS VendorID,
    tpep_pickup_datetime,
    tpep_dropoff_datetime,
    CAST(passenger_count AS INT) AS passenger_count,
    CAST(trip_distance AS DECIMAL(10,2)) AS trip_distance,
    CAST(RatecodeID AS INT) AS RatecodeID,
    store_and_fwd_flag,
    PULocationID,
    DOLocationID,
    CAST(payment_type AS INT) AS payment_type,
    
    CAST(fare_amount AS DECIMAL(10,2)) AS fare_amount,
    CAST(tip_amount AS DECIMAL(10,2)) AS tip_amount,
    CAST(tolls_amount AS DECIMAL(10,2)) AS tolls_amount,
    CAST(mta_tax AS DECIMAL(10,2)) AS mta_tax,
    CAST(congestion_surcharge AS DECIMAL(10,2)) AS congestion_surcharge,
    CAST(Airport_fee AS DECIMAL(10,2)) AS Airport_fee,
    CAST(total_amount AS DECIMAL(10,2)) AS total_amount

FROM data_filter_domain_constraints;



CREATE OR REPLACE TABLE summary_staging AS
SELECT * FROM (SUMMARIZE staging_cleanse);

SELECT * FROM summary_staging;

/*Pelo summarize: não vemos nenhuma mudança inesperada e o número de linhas não caiu drasticamente.*/