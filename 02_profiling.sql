-- Ler tabela bruta do banco e fazer investigação dos dados (profiling)

/* 
    1. Sumarizar estatísticas de profiling 
    2. Checar duplicatas
    3. Checar valores nulos
    4. Checar valores inconsistentes e outliers (negativos, passageiros > 5, datetime de dropoff antes do pickup, etc)
*/

/* ---- Investigação do formato da tabela ---- */
SELECT * FROM raw_yellow_tripdata LIMIT 10;

CREATE OR REPLACE TABLE profiling_stats_summary AS SELECT * FROM (SUMMARIZE raw_yellow_tripdata);

-- Ler estatísticas de profiling para basear as regras de limpeza
SELECT * FROM profiling_stats_summary;

/*
mta_tax, improvement_surcharge e congestion_surcharge são taxas que podem ou não ser cobradas, mas quando são cobradas, possuem valor fixo
segundo o site oficial da cidade de Nova Iorque (https://www.nyc.gov/site/tlc/passengers/taxi-fare.page).
MTA Tax: $0.50
Improvement Surcharge: $1.00
Congestion Surcharge (Yellow Taxi): $2.50

Dos dados de profiling_stats_summary, podemos ver que Airport_fee também é uma taxa que pode ou não ser cobrada, mas quando é, possui valor fixo de $1.75.
Conclusão: Usaremos essas informações para checar inconsistências de valores e também para fazer imputação de valores nulos. 
Isso também tira a necessidade de calcular IQR para essas colunas, pois não são variáveis contínuas, mas sim taxas fixas que podem ou não ser cobradas.
*/
SELECT * FROM raw_yellow_tripdata
WHERE mta_tax NOT IN (0, 0.5, -0.5) OR improvement_surcharge NOT IN (0, 1, -1) OR airport_fee NOT IN (0, 1.75, -1.75) OR congestion_surcharge NOT IN (0, 2.5, -2.5);

/* ---- Checagem de duplicatas ---- */

-- Duplicatas exatas (todas as colunas iguais)
SELECT *, COUNT(*) as qtd_duplicatas
FROM raw_yellow_tripdata
GROUP BY ALL
HAVING qtd_duplicatas > 1 ORDER BY qtd_duplicatas DESC;

-- Sem linhas com duplicatas exatas


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


/* ---- Valores nulos (colunas que aparecem com nulos no profilling_stats_summary) ---- */

SELECT * FROM raw_yellow_tripdata
WHERE payment_type = 0 AND PULocationID in (132, 138);
-- 140162 linhas

SELECT * FROM raw_yellow_tripdata
WHERE payment_type = 0 AND ROUND((total_amount - fare_amount - tip_amount - tolls_amount - extra - improvement_surcharge - mta_tax), 2) = 2.5;
-- 125088 linhas

SELECT * FROM raw_yellow_tripdata
WHERE payment_type = 0 AND ROUND((total_amount - fare_amount - tip_amount - tolls_amount - extra), 2) = mta_tax + improvement_surcharge;
-- 14239 linhas
-- Check: 140162 != 125088 + 14239 = 139327; 835 linhas que não se encaixam em nenhum dos dois casos acima.

/*
Nessas consultas houve a necessidade de usar a função ROUND() para arredondar os valores, pois, em algumas instâncias, poderíamos 
fazer a conciliação financeira manualmente e verificar que o valor aparente de total_amount bate com a soma dos valores aparentes das outras taxas, mas ao
criarmos a condição na cláusula WHERE, a condição não era reconhecida como verdadeira para essas mesmas linhas. 
Para evitar que perdas de frações invisíveis da subtração afetassem a condição, usou-se a função ROUND() para arredondar os 
valores para 2 casas decimais, que é o padrão usado nesse banco de dados. 
Conclusão: Para evitar esse tipo de erro futuramente, faremos uma conversão de tipo de DOUBLE para DECIMAL(10,2) para todas as colunas do tipo DOUBLE.
*/


/* 
Corridas com payment_type = 0 são corridas com pagamento em dinheiro, mas que não foram registradas corretamente. 
A maioria delas (125k) tem total_amount igual a soma das outras taxas + 2.5 (possivelmente a taxa de congestionamento) e outras 14k não seguem essa regra, possuindo apenas as taxas  
como unicas taxas mta_tax e improvement_surcharge (que sempre aparecem preenchidas), nesses casos: total_amount = fare_amount + tip_amount + tolls_amount + extra + 1.5.
MTA_tax e improvement_surcharge somadas dão 1.5.

Conclusão: Vamos fazer a imputação de acordo com a regra de negócio. 
Onde:
Congestion_surcharge = 2.5 e Airport_fee = 0 para as linhas que seguem a regra 1 e 
Congestion_surcharge = 0 e Airport_fee = 0 para as linhas que seguem a regra 2. 
*/

SELECT * FROM raw_yellow_tripdata
WHERE payment_type = 0 
AND ROUND((total_amount - fare_amount - tip_amount - tolls_amount - extra), 2) <> mta_tax + improvement_surcharge 
AND ROUND((total_amount - fare_amount - tip_amount - tolls_amount - extra - improvement_surcharge - mta_tax), 2) <> 2.5;
/*
835 linhas que não se encaixam em nenhum dos dois casos acima, ou seja, não possuem a taxa de congestionamento e também não possuem apenas as taxas de
MTA_tax e improvement_surcharge. Além disso, muitas delas aparecem com distância de viagem igual a 0, o que não é possível.
Conclusão: Vamos rejeitar essas instâncias pois possuem uma inconsistância considerável e não são facilmente tratáveis (além de serem um número muito pequeno).
*/


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
Na flag de store and fwd, vamos fazer imputação por moda. 
Por convenção e praticidade, também realizaremos uma conversão de tipo da flag de store and fwd para booleano, onde 'Y' será True e 'N' será False 
*/


/* ---- Valores inconsistentes ---- */

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
/*
Conclusão: 
Considerando a quantidade muito variada de valores inconsistentes e a necessidade de manter a qualidade dos dados, vamos fazer a
limpeza desses valores muito discrepantes (Ex.: 312722.3 milhas de viagem em trip_distance e 5000 de fare_amount), mantendo 
apenas os valores que estiverem dentro do intervalo de 1.5*IQR para cada uma. 
Assim a distribuição dos dados não ficará tão distorcida por outliers extremos.
Uma observação para trip_distance, é que ela precisa ser maior que 0 ao contrário dos outros valores contínuos, caso contrário rejeitamos a instância.
Inconsistências de localização e tempo também serão tratadas como regra de limpeza, rejeitando as instâncias que não se encaixarem nas 7 últimas regras citadas acima.
*/

-- Investigar corridas com qtd de passageiros inconsistentes 
SELECT * FROM raw_yellow_tripdata
WHERE passenger_count > 6;
/*
Com exceção de 1 corrida, todas marcadas como Negotiated fare (5), possivelmente motoristas 
que aceitaram mais passageiros do que o permitido sob certas condições.
Conclusão: Vamos manter essas linhas na tabela fato.
*/

SELECT * FROM raw_yellow_tripdata
WHERE passenger_count >= 6
ORDER BY passenger_count DESC, RatecodeID DESC;
/* 
Maioria marcados como Standard Rate (1), possivelmente motoristas 
que aceitaram mais passageiros do que o permitido sem condições adicionais.
Conclusão: Vamos manter essas linhas na tabela fato.
*/

SELECT * FROM raw_yellow_tripdata
WHERE passenger_count = 0;
/* 
Conclusão: Para essas corridas, também vamos fazer uma imputação usando a mediana da variável, pois quaisquer outra inconsistências
de quantia da corrida, ratecode, localização, tempo, etc. serão tratadas pelas demais regras de limpeza. 
*/

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


-- Calculo de mediana e moda para imputação
SELECT MEDIAN(passenger_count) AS mediana_passageiros, MODE() WITHIN GROUP (ORDER BY store_and_fwd_flag) AS moda_store_and_fwd_flag
FROM raw_yellow_tripdata;
