-- Dimensões geradas do staging

/*
Vamos gerar 4 dimensões:
 - dim_calendar (atributos de um calendário essencialmente)
 - dim_location (dimensão role-playing com atributos de localização, com base na tabela de lookup)
 - dim_payment (dimensão que descreve o tipo de pagamento para mais clareza, com base no dicionário de dados)
 - dim_junk (junk dimension para VendorID, RatecodeID e store_and_fwd_flag)
*/


/* Dimensão de calendário (usando series em vez de extrair da tabela de staging com DISTINCT)
    Os dados com os quais trabalharemos são de Janeiro de 2024 somente, mas essa estrutura permite 
    que a dimensão seja facilmente expandida para outros meses e anos, caso necessário.
*/
CREATE OR REPLACE TABLE dim_calendar AS
WITH dates_series AS (
    -- Gera uma sequência diária de 01/01/2024 até 31/01/2024
    SELECT UNNEST(generate_series(
        '2024-01-01'::DATE, 
        '2024-01-31'::DATE, 
        INTERVAL 1 DAY
    ))::DATE AS full_date
)
SELECT 
    -- Chave Primária Substituta no formato Inteiro YYYYMMDD (Ex: 20240115)
    CAST(STRFTIME(full_date, '%Y%m%d') AS INT) AS id_date,
    full_date,
   

    -- Atributos de Calendário
    YEAR(full_date) AS year,
    MONTH(full_date) AS month,
    STRFTIME(full_date, '%B') AS name_month, -- Nome do mês
    DAY(full_date) AS day,
    
    -- Atributos de Semana
    DAYOFWEEK(full_date) AS num_weekday, -- 0=Domingo, 1=Segunda, etc.
    DAYNAME(full_date) AS name_weekday,     -- Monday, Tuesday...
    QUARTER(full_date) AS quarter,
    
    -- Flag Booleana de Fim de Semana
    CASE 
        WHEN DAYOFWEEK(full_date) IN (0, 6) THEN TRUE 
        ELSE FALSE 
    END AS is_weekend

FROM dates_series;

SELECT * FROM dim_calendar;


/*
Dimensão de pagamento
Além da descrição padrão, trazemos até essa etapa o fato de que 
algumas instâncias de uma classe de pagamento possuem duplicatas com sinais espelhados (has_chargeback)
e também se a classe de pagamento gera receita positiva (positive_revenue).
*/
CREATE OR REPLACE TABLE dim_payment AS
WITH payment_dict(payment_type, desc_payment, positive_revenue, has_chargeback) AS (
    VALUES
        (0, 'Flex Fare', True, FALSE),
        (1, 'Credit card', TRUE, TRUE),
        (2, 'Cash', TRUE, TRUE),
        (3, 'No charge', FALSE, TRUE),
        (4, 'Dispute', FALSE, TRUE),
        (5, 'Unknown', FALSE, FALSE),
        (6, 'Voided trip', FALSE, FALSE)
)
SELECT 
    CAST(payment_type AS INT) AS id_payment,
    desc_payment,
    positive_revenue,
    has_chargeback
FROM payment_dict;

SELECT * FROM dim_payment;


/*
Dimensão de localização
Esta dimensão representa as diferentes localizações (distritos, zonas e áreas de serviço) do dataset.
Essencialmente é a tabela taxi_zone_lookup acrescentada de uma flag para identificar aeroportos.
*/
CREATE OR REPLACE TABLE dim_location AS
SELECT 
    CAST(LocationID AS INT) AS id_location,
    
    Borough,
    Zone,
    Service_zone,
    
    -- Identificar Aeroportos
    CASE 
        WHEN 
            service_zone LIKE '%Airport%' OR zone LIKE '%Airport%' 
        THEN TRUE 
        ELSE FALSE 
    END AS is_airport

FROM taxi_zone_lookup;

SELECT * FROM dim_location;



/*
Dimensão Junk (dim_junk)
Agrupa os códigos de fornecedor (VendorID), códigos de tarifa (RatecodeID)
e a flag de gravação local em memória (store_and_fwd_flag). Aqui não temos como adicionar informações relevantes, vamos acrescentar apenas
uma surrogate key para cada combinação única de atributos.
Vamos usar DISTINCT para usar somente as combinações que aparecem de fato nos dados para não gerar mais ruído.
*/
CREATE OR REPLACE TABLE dim_junk AS
WITH unique_combinations AS (
    SELECT DISTINCT
        VendorID,
        RatecodeID,
        store_and_fwd_flag
    FROM staging_cleanse
)
SELECT
    ROW_NUMBER() OVER () AS id_junk, -- Surrogate Key preservando a ordem na tabela de combinações
    
    VendorID as id_vendor,
    CASE 
        WHEN VendorID = 1 THEN 'Creative Mobile Technologies, LLC'
        WHEN VendorID = 2 THEN 'Curb Mobility, LLC'
        WHEN VendorID = 6 THEN 'Myle Technologies Inc'
        WHEN VendorID = 7 THEN 'Helix'
        ELSE 'Unknown Vendor'
    END AS desc_vendor,

    RatecodeID as id_ratecode,
    CASE 
        WHEN RatecodeID = 1 THEN 'Standard rate'
        WHEN RatecodeID = 2 THEN 'JFK'
        WHEN RatecodeID = 3 THEN 'Newark'
        WHEN RatecodeID = 4 THEN 'Nassau or Westchester'
        WHEN RatecodeID = 5 THEN 'Negotiated fare'
        WHEN RatecodeID = 6 THEN 'Group ride'
        WHEN RatecodeID = 99 THEN 'Null/unknown'
        ELSE 'Other'
    END AS desc_ratecode,
    store_and_fwd_flag
FROM unique_combinations;

SELECT * FROM dim_junk;