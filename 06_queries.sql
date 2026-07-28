/*
Consultas na tabela fato para responder perguntas relevantes 
sobre demanda, tempo, localização, pagamentos, preços ou eficiência das viagens
*/

/*
Query inicial: olhando as primeiras linhas da tabela fato para ter uma ideia do que temos.
*/
SELECT * FROM fact_tb_trips LIMIT 20;


/*
Pergunta: Quais são os melhores dias da semana e horários para rodar, visando maximizar o faturamento por minuto trabalhado?
Query: Rentabilidade média por hora do dia e dia da semana
*/
SELECT 
    c.name_weekday,
    f.hour_pickup,
    COUNT(*) AS total_corridas,
    ROUND(SUM(f.total_amount), 2) AS faturamento_total,
    -- Faturamento por minuto de corrida em trânsito
    ROUND(SUM(f.total_amount) / NULLIF(SUM(f.duration_minutes), 0), 2) AS faturamento_por_minuto
FROM fact_tb_trips f
JOIN dim_calendar c ON f.id_date_pickup = c.id_date
GROUP BY c.name_weekday, c.num_weekday, f.hour_pickup
ORDER BY faturamento_por_minuto DESC
LIMIT 10; -- Exibe as 10 horas mais rentáveis do mês

/*
Pergunta: Quais são as horas de maior volume de chamadas e como a duração e o ticket médio das corridas mudam da madrugada para o horário comercial?
Query: Perfil de demanda e faturamento por Hora do Dia
*/
SELECT 
    f.hour_pickup,
    COUNT(*) AS total_corridas,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct_demanda,
    ROUND(SUM(f.total_amount), 2) AS faturamento_total,
    ROUND(SUM(f.duration_minutes), 2) AS duracao_total_minutos,
    ROUND(AVG(f.duration_minutes), 2) AS duracao_media_minutos,
    ROUND(AVG(f.total_amount), 2) AS ticket_medio
FROM fact_tb_trips f
GROUP BY f.hour_pickup
ORDER BY f.hour_pickup;

/*
Pergunta: Quais são os pares de 'distrito de origem -> distrito de destino' com maior volume de viagens e maior arrecadação?
Query: top rotas de maior tráfego entre distritos
*/
SELECT 
    loc_pick.borough AS distrito_origem,
    loc_drop.borough AS distrito_destino,
    COUNT(*) AS total_viagens,
    ROUND(SUM(f.total_amount), 2) AS faturamento_total_rota,
    ROUND(AVG(f.trip_distance), 2) AS distancia_media_milhas
FROM fact_tb_trips f
JOIN dim_location loc_pick ON f.id_location_pickup = loc_pick.id_location
JOIN dim_location loc_drop ON f.id_location_dropoff = loc_drop.id_location
GROUP BY loc_pick.borough, loc_drop.borough
ORDER BY total_viagens DESC
LIMIT 10;


/*
Pergunta: Os finais de semana concentram corridas mais longas/lucrativas, ou os dias úteis dominam o faturamento por conta do fluxo de negócios?
Query: Comparativo Semanal de Volume, Faturamento e Distância
*/
SELECT 
    c.num_weekday,
    c.name_weekday,
    c.is_weekend,
    COUNT(*) AS total_corridas,
    ROUND(SUM(f.total_amount), 2) AS faturamento_total,
    ROUND(AVG(f.total_amount), 2) AS ticket_medio,
    ROUND(AVG(f.trip_distance), 2) AS distancia_media_milhas,
    ROUND(AVG(f.tip_amount), 2) AS gorjeta_media
FROM fact_tb_trips f
JOIN dim_calendar c ON f.id_date_pickup = c.id_date
GROUP BY c.num_weekday, c.name_weekday, c.is_weekend
ORDER BY c.num_weekday;

/*
Pergunta: Qual a preferência de pagamento dos passageiros e como isso impacta o faturamento (se afetar)?
Query: Share por tipo de pagamento e faturamento médio por tipo (análise de gorjeta válida somente para algumas formas de pagamento)
*/
SELECT 
    p.desc_payment AS metodo_pagamento,
    COUNT(*) AS qtd_transacoes,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct_participacao,
    ROUND(SUM(f.total_amount), 2) AS volume_financeiro,
    ROUND(AVG(f.fare_amount), 2) AS tarifa_media,
    ROUND(AVG(f.total_amount), 2) AS faturamento_medio,
    ROUND(AVG(f.tip_amount), 2) AS gorjeta_media,
    -- Taxa de conversão de gorjeta (Gorjeta / Tarifa)
    ROUND(AVG(f.tip_amount / NULLIF(f.fare_amount, 0)) * 100, 2) AS pct_gorjeta_sobre_tarifa
FROM fact_tb_trips f
JOIN dim_payment p ON f.id_payment = p.id_payment
WHERE p.positive_revenue = TRUE -- Considerando apenas pagamentos que geram receita
GROUP BY p.desc_payment, p.id_payment
ORDER BY qtd_transacoes DESC;

/*
Pergunta: Qual distrito de embarque gera a maior rentabilidade por milha e por minuto rodado para o motorista?
Query: Rentabilidade por distrito de embarque
*/
SELECT 
    loc.borough AS distrito_embarque,
    COUNT(*) AS total_corridas,
    ROUND(SUM(f.total_amount), 2) AS faturamento_total,
    ROUND(AVG(f.total_amount), 2) AS ticket_medio,
    -- Métrica de Eficiência Monetária por Milha Rodada ($/milha)
    ROUND(SUM(f.total_amount) / NULLIF(SUM(f.trip_distance), 0), 2) AS receita_por_milha,
    -- Métrica de Eficiência Monetária por Minuto em Trânsito ($/minuto)
    ROUND(SUM(f.total_amount) / NULLIF(SUM(f.duration_minutes), 0), 2) AS receita_por_minuto
FROM fact_tb_trips f
JOIN dim_location loc ON f.id_location_pickup = loc.id_location
GROUP BY loc.borough
ORDER BY faturamento_total DESC;


/*
Pergunta: Em quais horários o trânsito da cidade 'trava' (velocidade média cai), reduzindo o faturamento por minuto do motorista?
Query: Estimativa velocidade média numa viagem (milhas/hora) por hora do dia, considerando apenas corridas com mais de 1 minuto de duração 
*/
WITH velocidade_corridas AS (
    SELECT 
        f.hour_pickup,
        f.trip_distance,
        f.duration_minutes,
        -- conversão da duração de minutos para horas para achar Milhas/Hora (mph)
        (f.trip_distance / NULLIF(f.duration_minutes / 60.0, 0)) AS velocidade_mph
    FROM fact_tb_trips f
    WHERE f.duration_minutes > 1 -- remove viagens de menos de 1 minuto para não distorcer a velocidade
)
SELECT 
    hour_pickup,
    COUNT(*) AS qtd_amostras,
    ROUND(AVG(velocidade_mph), 2) AS velocidade_media_mph,
    ROUND(AVG(duration_minutes), 2) AS duration_media_minutos,
    ROUND(AVG(trip_distance), 2) AS distancia_media_milhas
FROM velocidade_corridas
GROUP BY hour_pickup
ORDER BY hour_pickup;
-- R: Horários das 14h-17h


/*
Pergunta: Como o caixa da empresa vai se acumulando ao longo de janeiro e qual é a variação percentual de faturamento 
de um dia para o outro? Existem quedas bruscas de receita de um dia pro outro?
Query: Fluxo de caixa acumulado e variação de dia a dia
*/
WITH faturamento_diario AS (
    SELECT 
        c.full_date,
        c.name_weekday,
        SUM(f.total_amount) AS receita_do_dia,
        COUNT(*) AS total_corridas
    FROM fact_tb_trips f
    JOIN dim_calendar c ON f.id_date_pickup = c.id_date
    GROUP BY c.full_date, c.name_weekday
),
analise_crescimento AS (
    SELECT 
        full_date,
        name_weekday,
        total_corridas,
        receita_do_dia,
        
        SUM(receita_do_dia) OVER (ORDER BY full_date) AS receita_acumulada_mes,
        
        LAG(receita_do_dia, 1) OVER (ORDER BY full_date) AS receita_dia_anterior
    FROM faturamento_diario
)
SELECT 
    full_date,
    name_weekday,
    receita_do_dia,
    receita_dia_anterior,
    
    -- 3. Cálculo da Variação Percentual
    ROUND(((receita_do_dia - receita_dia_anterior) / NULLIF(receita_dia_anterior, 0)) * 100, 2) AS variacao_dod_pct,
    
    receita_acumulada_mes
FROM analise_crescimento
ORDER BY full_date;

/*
Pergunta: Quais são as 3 rotas mais procuradas de manhã (ida pro trabalho) comparadas com as 3 mais procuradas à noite (volta pra casa)?
Query: Top 3 rotas mais populares particionadas por turno (Manhã vs Noite)
*/
WITH rotas_por_turno AS (
    SELECT 
        CASE 
            WHEN f.hora_pickup BETWEEN 6 AND 10 THEN '1. Rush da Manhã (06h-10h)'
            WHEN f.hora_pickup BETWEEN 16 AND 20 THEN '2. Rush da Noite (16h-20h)'
            ELSE '3. Outros Horários'
        END AS turno,
        loc_pick.zona AS zona_origem,
        loc_drop.zona AS zona_destino,
        COUNT(*) AS volume_viagens,
        ROUND(AVG(f.duracao_minutos), 1) AS tempo_medio_rota
    FROM fato_viagens f
    JOIN dim_localizacao loc_pick ON f.id_localizacao_pickup = loc_pick.id_localizacao
    JOIN dim_localizacao loc_drop ON f.id_localizacao_dropoff = loc_drop.id_localizacao
    WHERE f.hora_pickup BETWEEN 6 AND 10 OR f.hora_pickup BETWEEN 16 AND 20
    GROUP BY turno, loc_pick.zona, loc_drop.zona
),
ranking_rotas AS (
    SELECT 
        turno,
        zona_origem,
        zona_destino,
        volume_viagens,
        tempo_medio_rota,
        DENSE_RANK() OVER (PARTITION BY turno ORDER BY volume_viagens DESC) AS posicao_ranking
    FROM rotas_por_turno
)
SELECT * FROM ranking_rotas
WHERE posicao_ranking <= 3 
ORDER BY turno, posicao_ranking;