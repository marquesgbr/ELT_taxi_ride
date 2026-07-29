## Equipe e Papéis
1. Gabriel Marques
    - Modelagem Dimensional
    - Perfilamento e Limpeza
    - Criação de Consultas de BI
2. Getúlio Junqueira de Queiroz Lima (Ausente)
3. cleyton esley gomes ferreira (Ausente)
4. Luiz Miguel Alves Venancio (Ausente)
5. Thales Afonso Dornelas Gomes (Ausente)

## Visão Geral do Projeto

Este projeto foi desenvolvido com o objetivo de processar dados públicos de corridas de táxi de Nova York (TLC Yellow Taxi - Jan/2024), transformando arquivos brutos (Parquet/CSV) com milhões de linhas em um Esquema Estrela (Star Schema). Esse modelo visa fornecer uma base confiável para consultas analíticas (OLAP), respondendo a perguntas de negócio sobre mobilidade urbana, eficiência de frota e comportamento financeiro.

Inspirações de perguntas que guiaram a modelagem:

- Quais os melhores horários do dia para dirigir para maximizar a velocidade e lucro?
- Existem quedas bruscas de receita de um dia pro outro?
- Qual a preferência dos passageiros quanto à forma de pagamento?
- É possível prever zonas de alta demanda baseado no dia e no horário?

## Stack

- Engine: DuckDB
- Linguagem: SQL
- Ambiente: VSCode

## Como Rodar?
Pressupondo que já exista um ambiente capaz de executar consultas SQL no padrão do DuckDB, siga estes passos:

1. Tenha certeza de ter os seguintes arquivos no seu diretório e com os respectivos caminhos especificados no arquivo `01_raw.sql`:
    - `taxi_zone_lookup.csv`
    - `yellow_tripdata_2024-01.parquet`
2. Execute os arquivos `.sql` na ordem que estão numerados
3. Em cada arquivo (exceto `06_queries.sql`) é necessário executar as queries na ordem em que aparecem. 


Ao final, é esperado que existam as seguintes tabelas:
- count_not_feasiable_limits (1 Linha)
- count_rows_nulls (5 linhas)
- dim_calendar (31 linhas)
- dim_junk (21 linhas)
- dim_location (265 linhas)
- dim_payment (7 linhas)
- fact_tb_trips (2.865.159 linhas)
- iqr_values (1 linha)
- negative_amounts (37,6 mil linhas)
- partial_dupe_rows (30,7 mil linhas)
- profiling_stats_summary (19 linhas)
- raw_yellow_tripdata (2.964.624 linhas)
- staging_cleanse (2.865.159 linhas)
- summary_staging (17 linhas)
- taxi_zone_lookup (265 linhas)

Não são esperadas criações de VIEWs.

## Modelagem do Banco de Consulta

Nesse tópico, mostra-se as justificativas e opções consideradas nas decisões de arquitetura, que focaram em aproveitar ao máximo as variáveis existentes nos dados originais, evitando criação e exclusão que trariam retornos pequenos.

### Decisões da Modelagem das Dimensões

1. Usar Junk Dimension para VendorID, RatecodeID e store and fwd flag ao invés de dimensão degenerada.
    - **Por quê?** Esses dados tem baixa cardinalidade, possuem contextos que são explicados por si só e não determinam ou são determinados por outras colunas. A fim de manter a tabela fato concisa, mas sem perder informação, essas colunas foram adicionadas a uma junk table.
    - **Opção(ões) descartada(s):**
        1. Criar três tabelas de dimensão físicas separadas (uma para cada atributo).
            *Por que foi descartada?* Exigiria múltiplas junções desnecessários nas consultas para tabelas minúsculas (de 2 a 7 linhas), prejudicando a legibilidade e a performance.
            
        2. Deixar os códigos e textos espalhados como dimensões degeneradas diretamente na tabela Fato.
            *Por que foi descartada?* Perderia a chance de centralizar a tradução dos códigos de Ratecode e Vendor, repetindo desnecessariamente múltiplos valores que não tem descrição nos dados originais.
            
2. Usar dimensão role-playing para identificadores de embarque e desembarque.
    - **Por quê?** Origem e destino compartilham o mesmo domínio de dados, então evita redundância e armazenamos algo que será usado repetidas vezes nas consultas. Dessa forma também podemos acrescentar mais detalhes na dimensão para enriquecer o escopo de perguntas que podem ser respondidas pelas consultas.
    - **Opção(ões) descartada(s):**
        1. Criar duas tabelas físicas idênticas (para local origem e destino).
            *Por que foi descartada?* Dobraria o esforço de manutenção do banco (se o nome de um bairro mudar, teríamos que fazer o UPDATE em dois lugares diferentes) e duplicaria o armazenamento do mesmo domínio de dados.
            
3. Usar uma dimensão role-playing para uma dimensão temporal que contém os atributos descritivos do Dia de embarque e desembarque
    - **Por quê?** Nesse modelo de negócio, embora as corridas normalmente começem e terminem no mesmo dia, há uma parcela de viagens que iniciam no final de um dia e terminam no dia seguinte. Então, cria-se uma dimensão role-playing para reutilizar a mesma tabela física que contém atributos de calendário para ambos os eventos de embarque e desembarque. Isso centraliza a lógica temporal e evita a duplicação estrutural no banco.
    - **Opção(ões) descartada(s):**
        - **Deixar os atributos de data e hora achatados diretamente na Tabela Fato (Sem criar dimensão).**
            *Por que foi descartada?* A Tabela Fato ficaria insustentavelmente pesada. Em vez de armazenar apenas um número inteiro (Ex.: 20240102), a Fato teria que repetir dados de texto constantes como 'Segunda-feira', 'Janeiro' e 'Dia Útil' em cada linha de transação, destruindo a performance de leitura e quebrando o conceito do Esquema Estrela.
            
4. Separar somente a Data de “tpep_dropoff_datetime” e “tpep_pickup_datetime” e usá-la como chave estrangeira para a dimensão temporal.
    - **Por quê?** Porque o timestamp exato (com horas, minutos e segundos) tem altíssima cardinalidade. Se criássemos uma dimensão de tempo com o momento exato, ela teria quase tantas linhas quanto a própria tabela fato, destruindo a performance. Ao extrair apenas o dia do calendário, criamos uma dimensão bem menor (31 linhas para o mês de janeiro), o que permite adicionar atributos úteis de negócio (dia da semana, número da semana, etc.) e facilita agrupamentos extremamente rápidos.
    - **Opção(ões) descartada(s):**
        1. Criar uma tabela *dim_tempo* contendo a data e a hora exata combinadas.
            *Por que foi descartada?* Explosão de cardinalidade. A dimensão teria um número de linhas que não é desprezível em relação a tabela fato, prejudicando desempenho e o propósito de uma dimensão agregadora.
            
5. Dimensão degenerada na fato que mostra o timestamp de pickup e dropoff (Decorrente da decisão anterior)
    - **Por quê?** Como separamos apenas a "Data" para a dimensão de calendário, não podemos perder a informação exata de quando a corrida aconteceu. O timestamp fica direto na tabela Fato (como dimensão degenerada) porque ele não possui nenhuma informação descritiva extra que justifique criar uma tabela separada só para ele. Ele sobrevive na fato apenas para permitir cálculos pontuais — como a duração exata da viagem em minutos, que será adicionada à tabela fato como atributo.
    - **Opção(ões) descartada(s):**
        1. Remover as horas, minutos e segundos completamente do modelo analítico para poupar espaço.
            *Por que foi descartada?* Perda irreversível de informações de negócio cruciais, impossibilitando o cálculo de métricas importantes como o tempo exato de duração das corridas.
            
        2. Criar uma dimensão separada só com "Horas do Dia", sem a data.
            *Por que foi descartada?* Acrescentaria complexidade à modelagem e mais um JOIN nas consultas sem fornecer ganhos reais de agregação em comparação com deixar o timestamp cru na Fato.
            
6. Criar uma dimensão de pagamento como uma lookup table para mais informação 
    - **Por quê?** Nos dados brutos, o tipo de pagamento é apenas um número inteiro categórico que não gera conhecimento ao ser somado, multiplicado, etc. E para um modelo analítico (OLAP), números sem contexto não servem para o usuário final. Essa dimensão funcionará como um dicionário para traduzir esses códigos em descrições legíveis ("Cartão de Crédito", "Dinheiro"), garantindo que os relatórios sejam compreensíveis.
    - **Opção(ões) descartada(s):**
        1. Deixar a regra de tradução embutida (via `CASE WHEN`) direto nas consultas do usuário final ou do software de BI.
            *Por que foi descartada?* Se a origem adicionar um novo código de pagamento amanhã, teríamos que procurar e alterar o SQL em dezenas de painéis diferentes.
7. Não usar restrição de PK na tabela fato; garantir integridade através da idempotência do pipeline
    - **Por quê?** Como bancos de dados analíticos colunares são construídos para engolir milhões de linhas de uma vez só (bulk load). Exigir que o banco verifique a unicidade de uma Chave Primária linha por linha durante a inserção destruiria a performance do processamento. Em vez de depender de uma barreira física no banco, garantimos que não haverá duplicidade construindo um pipeline idempotente (usando **CREATE OR REPLACE TABLE**), que limpa e recria a camada sempre do zero de forma controlada.
    - **Opção(ões) descartada(s):**
        1. Usar uma restrição física de Chave Composta (Local + Data + Tempo).
            *Por que foi descartada?* É altamente propenso a falhas de ingestão no mundo real (ex: duas corridas distintas saindo do mesmo aeroporto no exato segundo).
        2. Impor uma restrição rígida de Primary Key via um ID gerado por SEQUENCE.
            *Por que foi descartada?* A validação linha a linha de uma restrição de PK durante o processo de inserção massiva destruiria a performance computacional típica esperada de um banco OLAP colunar.


### Descrição das Dimensões

O contexto ao redor de cada evento de corrida é fornecido por 4 dimensões:

- `dim_calendar` **(Dimensão Role-Playing)**: Reúne os atributos descritivos de calendário (ano, mês, dia, dia da semana, indicador de fim de semana). É referenciada duas vezes na Fato (embarque e desembarque).
- `dim_location` **(Dimensão Role-Playing)**: Mapeia os códigos da TLC para seus respetivos distritos (*Boroughs*), zonas (*Zones*) e áreas de serviço (*Service Zones*), acrescentada de uma flag booleana que identifica aeroportos. É referenciada duas vezes na Fato (origem e destino).
- `dim_payment`: Mapeia as formas de pagamento oficiais (códigos 0 a 6) segundo dicionário oficial. Incorpora atributos de contexto de negócio via *flags* booleanas (`positive_revenue` e `has_chargeback`) para identificar transações que geram receita e métodos que podem gerar estornos.
- `dim_junk` **(Junk Dimension)**: Agrupa as combinações únicas — que aparecem no dataset — dos atributos de baixa cardinalidade (`VendorID`, `RatecodeID` e `store_and_fwd_flag`).

### **O Grão da Tabela Fato**

**Declaração de Granularidade:** Cada linha na Tabela Fato (`fact_tb_trips`) representa **estritamente uma única corrida de táxi concluída**.

O propósito deste banco analítico é responder a questões operacionais e de mobilidade urbana. Portanto, a menor unidade indivisível de análise é a viagem (que pode transportar um ou mais passageiros). Todas as métricas numéricas armazenadas respeitam este nível de detalhe.

### Colunas da Tabela Fato

A forma da tabela fato decorre das decisões feitas na modelagem dimensional. As descrições acompanham atributos que não estão descritos no dicionário do dataset.

1. Chaves Estrangeiras:
    - id_date_pickup: Chave inteira (`YYYYMMDD`) apontando para a `dim_calendar` (Data de Embarque).
    - id_date_dropoff: Chave inteira (`YYYYMMDD`) apontando para a `dim_calendar` (Data de Desembarque).
    - id_location_pickup: Chave inteira referente à `dim_location` (Local de Embarque).
    - id_location_dropoff: Chave inteira referente à `dim_location` (Local de Desembarque).
    - id_payment: Chave inteira referente à `dim_payment` (Método de Pagamento).
    - id_junk: Chave substituta da `dim_junk` (Combinação de Provedor, Tarifa e Flag)
2. Atributos de Tempo:
    - tpep_pickup_datetime
    - tpep_dropoff_datetime
    - duration_minutes: Métrica derivada calculada na camada de transformação (`(dropoff - pickup) em minutos`). Pré-calculada na Fato para simplificar *dashboards* de BI e acelerar consultas de velocidade/tempo de trânsito.
3. Tarifas e Gorjeta
    - airport_fee
    - tolls_amount
    - tip_amount
    - congestion_surcharge
4. Descrição principal da corrida:
    - fare_amount
    - trip_distance
    - passenger_count
    - total_amount

## Decisões de Limpeza

Referência de negócio para algumas decisões de limpeza:

- https://www.nyc.gov/site/tlc/passengers/taxi-fare.page - Site oficial do governo de NYC

### Seleção de Variável

Vamos excluir da análise variáveis que são somente taxas fixas ou sem muito significado, o intuito é focar na análise de valores importantes e identificadores que agregam valor nos insights de negócio. Em suma, não há motivação suficiente para que sejam mantidas na tabela fato, porém mantê-las fora do modelo final torna as consultas mais fáceis de manipular e deixa o modelo mais leve.

Com isso em mente, essas colunas não farão parte da tabela fato:

1. **improvement_surcharge:** taxa fixa e engessada do governo que não agrega valor na análise
2. **extra:** cobranças extras que não sabemos de onde vem ou para que servem

### Valores Nulos

Identificou-se que todas as linhas com valores nulos na base (~140 mil registros) compartilham a mesma característica: `payment_type = 0`. 
Quanto as razões de existir esse padrão, validou-se no dicionário oficial da TLC (*Taxi & Limousine Commission* de NY) que esse código representa corridas do tipo **Flex Fare** (tarifas flexíveis/dinâmicas ou de aplicativo conveniado). Nesses cenários, ao invés do taxímetro tradicional ser acionado, o valor da corrida vem de um sistema externo, gerando esse efeito em cascata onde múltiplos campos ficam nulos ao mesmo tempo.

Para contornar esse problema estrutural sem perder os dados válidos, adotou-se a seguinte estratégia de imputação:

- **passenger_count:** Imputação usando a mediana da variável
- **RatecodeID:** Substituição pelo valor `99` de acordo com o dicionário oficial.
- **store_and_fwd_flag:** Imputação por moda.
- **Airport_fee e congestion_surcharge**: Imputação via regras de negócio e conciliação financeira.
    - OBS.: Considere `SOMA = fare_amount + tip_amount + tolls_amount + extra + improvement_surcharge + mta_tax`.
    - Observou-se que o `total_amount` geralmente refletem as fórmulas:
        - `total_amount = SOMA + 2.50`
        - `total_amount = SOMA`
    - Com base nas regras do governo de NYC, deduzimos que:
        - Se `total_amount = SOMA + 2.50` →`congestion_surcharge` é preenchido com $2.50 e `Airport_fee` com $0.00.
        - Se `total_amount = SOMA` → Ambas as taxas recebem $0.00.
        - Na documentação oficial, `Airport_fee` é $2.00 se cobrado mas isso refere-se ao valor desse ano. Posteriormente verifica-se que `Airport_fee` só pode ser $0.00 ou $1.75 — possível valor na época que os dados foram coletados —, confirmando essa hipótese.
        - Nota 1: 835 instâncias não se encaixaram em nenhum padrão de conciliação financeira e foram rejeitadas para preservar a integridade contábil da Tabela Fato.
    - **Texto referência:** "Plus New York State Congestion Surcharge of $2.50 (Yellow Taxi) or $2.75 (Green Taxi) or 75 cents (any shared ride) for all trips that begin, end or pass through Manhattan south of 96th Street." https://www.nyc.gov/site/tlc/passengers/taxi-fare.page

**Opções Descartadas:**

- **Descartar todas as linhas com `payment_type = 0`:** Rejeitada pois resultaria na perda de 140 mil corridas com faturamento real. Empobreceria a volumetria do modelo final, visto que os dados principais (tarifa, distância e localização) estavam íntegros.
- **Imputação de `store_and_fwd_flag` via agrupamento geográfico:** Pensou-se em mapear as zonas (`PULocationID` e `DOLocationID`) e distâncias onde a flag era mais ativada para criar uma regra preditiva de preenchimento. Rejeitada pela complexidade excessiva para a camada de Staging; exigiria a construção prévia de um modelo dimensional apenas para validação.

### Tratamento de Outliers em colunas numéricas contínuas

Para lidar com valores extremos que distorcem a análise (ex: `trip_distance` de 312.722 milhas ou `fare_amount` de $5.000), aplicou-se o método estatístico IQR (Amplitude Interquartil). Os limites do IQR foram calculados isoladamente e armazenados em uma tabela de configuração de linha única.
máximo iguais à `1.5*IQR` para cada uma.
Manteremos na base apenas os registros cujo valor seja menor ou igual ao Limite Superior do IQR (Q3 + 1.5*IQR). As variáveis contínuas submetidas a este filtro foram: `trip_distance`, `fare_amount`, `tip_amount` e `total_amount`.

**Opção Descartada:** Usar o filtro IQR em todas as colunas numéricas (incluindo taxas fixas). Taxas como `airport_fee` e `mta_tax` são valores discretos. A aplicação do IQR resultaria num limite de zero, o que eliminaria erroneamente viagens legítimas.

### **Tratamento de Incosistências**

Além de `extra` e `improvement_surcharge`, temos outras 4 variáveis numéricas que estão relacionadas à taxas, todas elas podem ou não ser cobradas numa corrida, porém 3 delas  (`Airport_fee`, `congestion_surcharge`, `mta_tax`) possuem valores fixos quando cobradas. Sendo assim, cada uma delas receberá os seguintes tratamentos:

- **Airport_fee:** Precisa estar no conjunto **`{0, 1.75}`**. No site oficial do governo de NYC atualmente determina $2, mas no momento da criação desse dataset o valor ainda era de $1.75 — análise de valores únicos comprovou que o valor dessa variável está em (-1.75, 0, 1.75).
- **congestion_surcharge:** Precisa estar no conjunto **`{0, 2.50}`**. Valor determinado para “Yellow Taxi” no site oficial do governo de NYC.
- **mta_tax:** Precisa estar no conjunto **`{0, 0.50}`**. Valor determinado no site oficial do governo de NYC.
- **tolls_amount**: ****Limitado a valores não-negativos. O método IQR falhou nesta coluna devido à alta esparsidade de dados (Q1 e Q3 são os mesmos e, quando consideramos somente os valores maiores que zero, são iguais à 6.94), resultando num IQR de zero. Todavia, os valores extremos dessa variável serão eliminados pelo filtro com IQR de `total_amount`.

### Casos Limítrofes (Edge Cases)

Durante a análise exploratória, foram identificadas algumas instâncias com quantidades de passageiros (**`passenger_count`**) aparentemente anômalas para um carro de passeio convencional (ex: 7, 8 ou 9 passageiros).

Optou-se por **não** excluir ou filtrar esses registros do modelo. O cruzamento de dados demonstrou que uma parte desses registros anômalos está associada ao `RatecodeID = 5` (Tarifa Negociada / *Negotiated Fare*) ou a corridas padrão que plausivelmente envolvem veículos de maior porte, como Vans ou SUVs. Sendo viagens faturadas e concluídas de forma legítima, sua remoção causaria uma perda indevida de receita na Tabela Fato.

**Opção Descartada:** Impor um limite máximo (*hardcode*) de 4 a 6 passageiros ou aplicar o filtro IQR nesta coluna. Rejeitada pois a estatística penalizaria viagens reais em veículos maiores, distorcendo as métricas de faturamento global e ticket médio.

### Valores negativos e Duplicatas

Não foram encontradas duplicatas exatas, mas através de uma agregação com valores absolutos usando a função `ABS()`, identificou-se cerca de 30 mil pares de instâncias duplicadas espelhadas (mesmos timestamps, mesmos IDs de localização e valores financeiros com sinais invertidos). Esses pares representam cancelamentos, estornos e chargebacks (geralmente associados aos `payment_type` 3 ou 4). Além disso, detectou-se cerca de 7 mil registros isolados com valores negativos nas quantias monetárias, caracterizando possível falha de registro do proprio equipamento. 

Então, optou-se por rejeitar todos os registros de valor negativo. 

**Opção Descartada:** Conversão para valor absoluto. Não foi feito a fim de evitar a duplicidade inverídica de viagens e faturamento no modelo OLAP.

### **Transformações e Conversões de Tipo**

Para otimizar o banco de dados analítico e prevenir erros sistêmicos, as seguintes conversões foram aplicadas durante a construção da Staging:

1. **store_and_fwd_flag (VARCHAR → BOOLEAN):** Valores 'Y' convertidos para `TRUE` e 'N' para `FALSE`. Otimiza o armazenamento e possui a mesma semântica para análises de BI.
2. **tpep_pickup/dropoff_datetime (TIMESTAMP → INTEGER):** Extração apenas da data no formato numérico `YYYYMMDD`. Essa transformação visa criar as Chaves Estrangeiras (FK) que se conectarão à nossa Dimensão de Tempo (`dim_calendar`) no formato de Dimensão Role-Playing, mas não apaga o atributo `TIMESTAMP` original.
3. Métricas financeiras e **trip_distance** **(DOUBLE → DECIMAL(10,2)):** Durante a fase de perfilamento, a conciliação financeira de algumas transações falhou na cláusula `WHERE` devido a problemas de arredondamento inerentes à aritmética de ponto flutuante (*floating-point*) em SQL. A conversão forçada para DECIMAL de duas casas mantém o padrão do dataset e evita a propagação do erro para a Tabela Fato.
4. Variáveis Numéricas Discretas **(BIGINT → INTEGER):** Durante a ingestão dos dados brutos, colunas de identificação e categorização (`VendorID`, `RatecodeID`, `passenger_count`, `payment_type`, `PULocationID` e `DOLocationID`) foram tipadas como `BIGINT`. Foi realizada a conversão explícita de todas essas colunas para `INTEGER`. A análise de perfilamento provou que o valor máximo absoluto em qualquer uma dessas colunas (ex: `LocationID` = 265, `RatecodeID` = 99) é muito menor que o limite suportado pelo tipo `INTEGER` (2.14 bilhões). Realizar essa conversão reduz o consumo de armazenamento dessas colunas e em tabelas muito grandes, essa economia também prova-se benéfica na execução de múltiplos `JOINs` e escaneamentos que englobam toda a tabela.

## **Registro do Uso de LLMs**

1. https://share.gemini.google/o7wsTrSkUzLa
    1. “Como configurar DuckDB para VSCode?”
    2. “Faltou alguma coisa nesse comando para criar a tabela de dados brutos no banco?”
2. https://share.gemini.google/5c47qJqSyei7
    1. “Função para calcular percentis”
    2. “Função de agregação com CASE WHEN”
3. https://share.gemini.google/3HSuqnePg6rJ
    1. “Como excluir colunas num SELECT”
    2. “Uso práticos de QUALIFY”
    3. “Gerando e manipulando séries”