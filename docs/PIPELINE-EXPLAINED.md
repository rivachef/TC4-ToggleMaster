# Pipeline Explicado - ToggleMaster Fase 3

Guia didatico completo do pipeline ToggleMaster, explicando cada peca da arquitetura, o **por que** de cada decisao, e o que dizer na apresentacao.

---

## O Grande Quadro

Imagina que voce tem uma fabrica com 3 departamentos:

1. **Departamento de Construcao** (Terraform) → constroi o predio (infraestrutura AWS)
2. **Departamento de Producao** (CI/CD) → fabrica o produto (compila, testa, empacota)
3. **Departamento de Entrega** (GitOps/ArgoCD) → entrega o produto na loja (deploy no Kubernetes)

O grande insight da Fase 3 e: **os 3 departamentos funcionam de forma independente e automatizada**. O Terraform nao sabe que o CI/CD existe. O CI/CD nao faz deploy diretamente. O ArgoCD nao sabe como o codigo foi compilado. Cada um faz sua parte, e o **Git e o contrato entre eles**.

```
Developer Push ──> GitHub Actions (CI) ──> Atualiza Git ──> ArgoCD (CD) ──> Kubernetes
                        |                      |                                |
                   Compila, testa,       Commit automatico             Sync automatico
                   escaneia, empacota    da nova image tag             dos pods
```

---

## FASE 1: Terraform — Construindo o Predio

### O que o Terraform faz?

Pense no Terraform como uma **planta arquitetonica**. Voce descreve o que quer (VPC, banco de dados, cluster Kubernetes...) num arquivo `.tf`, e o Terraform cria tudo na AWS.

### Por que modulos?

```
terraform/modules/
├── networking/    → VPC, subnets, internet gateway, NAT
├── eks/           → Cluster Kubernetes
├── databases/     → 3 PostgreSQL + Redis + DynamoDB
├── messaging/     → Fila SQS
└── ecr/           → 5 repositorios Docker
```

Cada modulo e uma **peca de LEGO**. O `main.tf` monta as pecas juntas. Isso e importante porque:
- Voce pode reusar modulos em outros projetos
- Se algo quebrar no banco, voce mexe so no modulo `databases/`
- Na apresentacao: *"Componentizamos a infra em modulos reutilizaveis"*

### Backend Remoto — Por que S3 + DynamoDB?

O Terraform guarda um arquivo chamado `terraform.tfstate` que e o **mapa de tudo que foi criado**. Se voce perder esse arquivo, o Terraform nao sabe mais o que existe na AWS.

- **S3**: guarda o `tfstate` na nuvem (nao no seu computador)
- **DynamoDB**: funciona como um **cadeado** — se duas pessoas rodarem `terraform apply` ao mesmo tempo, o DynamoDB impede que um sobrescreva o outro

Na apresentacao: *"Usamos backend remoto com S3 para persistencia do state e DynamoDB para lock de concorrencia."*

### LabRole — A restricao do AWS Academy

No AWS Academy, voce **nao pode criar IAM Roles** (sao roles pre-existentes). Entao, ao inves de:

```hcl
resource "aws_iam_role" "eks" { ... }  # PROIBIDO no Academy
```

Fazemos:

```hcl
variable "lab_role_arn" { }  # Recebemos a role pronta como variavel
```

Na apresentacao: *"Adaptamos o Terraform para o ambiente AWS Academy, importando a LabRole existente via variavel."*

### Os 39 recursos — O que cada um faz?

Pense numa cidade:

| Recurso | Analogia | Funcao |
|---------|----------|--------|
| **VPC** | O terreno da cidade | Rede virtual isolada |
| **Subnets publicas** (2) | Ruas onde qualquer um chega | Load Balancers ficam aqui |
| **Subnets privadas** (2) | Ruas internas, protegidas | Bancos de dados e pods ficam aqui |
| **IGW** (Internet Gateway) | Porta de entrada da cidade | Permite trafego externo |
| **NAT Gateway** | Saida controlada | Pods acessam internet, mas internet nao acessa eles |
| **EKS** | A fabrica | Cluster Kubernetes com 2 nodes t3.medium |
| **RDS** (3x) | 3 cofres separados | Um banco PostgreSQL por servico com persistencia |
| **Redis** | Memoria rapida | Cache para o evaluation-service |
| **SQS** | Esteira transportadora | Fila: evaluation manda eventos → analytics consome |
| **DynamoDB** | Arquivo morto | Analytics grava dados de uso |
| **ECR** (5x) | Garagem de containers | Armazena imagens Docker de cada servico |

Na apresentacao: *"Sao 39 recursos divididos em 5 modulos, provisionados em ~20 minutos."*

### Erro comum: DynamoDB digest stale

Se o `terraform init` falhar com "state data does not have expected content", significa que uma sessao anterior deixou um lock "fantasma". A solucao:

```bash
aws dynamodb delete-item --table-name togglemaster-terraform-lock \
  --key '{"LockID":{"S":"togglemaster-terraform-state/infra/terraform.tfstate-md5"}}'
terraform init -reconfigure
```

---

## FASE 2: kubectl — A Ponte para o Cluster

```bash
aws eks update-kubeconfig --name togglemaster-cluster --region us-east-1
```

Esse comando faz uma coisa simples: configura seu terminal para falar com o cluster Kubernetes que o Terraform criou. E como **salvar o telefone do cluster na sua agenda**.

Depois disso, todo `kubectl` que voce digitar vai direto pro EKS.

---

## FASE 3: O Setup — De Infraestrutura Vazia para Aplicacao Rodando

Aqui e onde a magica acontece. O `setup-full.sh` orquestra 8 passos. Cada um tem uma razao de estar nessa ordem.

### Passo 1/8: Gerar Secrets (`generate-secrets.sh`)

**O problema:** Seus microsservicos precisam de senhas, endpoints de banco, credenciais AWS. Mas essas informacoes sao **sensiveis** — nao podem ir pro Git.

**A solucao:** O script le o output do Terraform (que tem todos os endpoints) + a senha do banco (do `terraform.tfvars`) + suas credenciais AWS, e **gera 8 arquivos `secret.yaml`** localmente.

**Por que 8 secrets?**

| Servico | Secret do app | Secret do DB init | Total |
|---------|--------------|-------------------|-------|
| auth-service | `secret.yaml` (DATABASE_URL, MASTER_KEY) | `db/secret.yaml` (host, user, pass) | 2 |
| flag-service | `secret.yaml` (DATABASE_URL) | `db/secret.yaml` (host, user, pass) | 2 |
| targeting-service | `secret.yaml` (DATABASE_URL) | `db/secret.yaml` (host, user, pass) | 2 |
| evaluation-service | `secret.yaml` (REDIS, SQS, AWS creds) | - | 1 |
| analytics-service | `secret.yaml` (SQS, AWS creds) | - | 1 |
| **Total** | | | **8** |

**O conceito `stringData`:** No Kubernetes, secrets podem ser definidos de 2 formas:

```yaml
# Opcao 1: data (base64) — chato de gerar manualmente
data:
  SENHA: "bWluaGEtc2VuaGE="

# Opcao 2: stringData (texto puro) — o K8s converte pra voce
stringData:
  SENHA: "minha-senha"
```

Usamos `stringData` porque e mais simples de automatizar. O Kubernetes converte para base64 automaticamente ao aplicar.

Na apresentacao: *"Os secrets sao gerados automaticamente a partir do Terraform output, nunca commitados no Git."*

### Passo 2/8: Instalar ArgoCD

ArgoCD e o **operador de GitOps**. Ele fica olhando a pasta `gitops/` no GitHub e, quando detecta mudanca, sincroniza com o cluster.

Ele e instalado dentro do proprio cluster Kubernetes (namespace `argocd`), e exposto via LoadBalancer para acesso web.

**O `--server-side`:** Os CRDs (Custom Resource Definitions) do ArgoCD sao tao grandes que o `kubectl apply` normal falha com "metadata.annotations: Too long". O `--server-side` manda o processamento pro servidor ao inves de fazer no cliente.

### Passo 3/8: Aplicar Secrets (`apply-secrets.sh`)

Aplica os 8 `secret.yaml` que foram gerados no Passo 1. Agora o cluster "conhece" todas as senhas e endpoints.

**Por que antes do Docker build?** Porque quando os pods subirem, eles precisam dos secrets ja disponiveis. Se o secret nao existir, o pod falha.

### Passo 4/8: Build e Push Docker

**Por que Docker?** Seus microsservicos sao codigo Go e Python. O Kubernetes nao roda codigo diretamente — ele roda **containers**. O Docker empacota cada microsservico numa imagem.

**O que e ECR?** E o "Docker Hub da AWS". Uma garagem privada para suas imagens. Usamos tag `IMMUTABLE` para seguranca — uma vez pushada, a tag nao pode ser sobrescrita.

**Por que `--platform linux/amd64`?** Se voce esta num Mac M1/M2/M3, seu chip e ARM. Mas o EKS roda em x86. Sem essa flag, a imagem funciona no seu Mac mas **nao funciona no cluster** (causa `CrashLoopBackOff` silencioso).

**Por que ANTES do ArgoCD Applications?** Se voce aplicar as Applications antes de ter imagens no ECR, o ArgoCD vai tentar criar os pods imediatamente, e eles ficarao em `ImagePullBackOff` (nao encontra a imagem). Foi exatamente o que aconteceu durante nosso teste e geramos o Erro 7 na documentacao.

Na apresentacao: *"Fazemos build multi-plataforma para garantir compatibilidade com os nodes x86 do EKS."*

### Passo 5/8: Aplicar ArgoCD Applications

O arquivo `argocd/applications.yaml` define **6 Applications**:

| Application | O que monitora | O que cria no cluster |
|-------------|---------------|----------------------|
| auth-service | `gitops/auth-service/` | Deployment, Service, HPA, DB Job |
| flag-service | `gitops/flag-service/` | Deployment, Service, DB Job |
| targeting-service | `gitops/targeting-service/` | Deployment, Service, DB Job |
| evaluation-service | `gitops/evaluation-service/` | Deployment, Service, HPA |
| analytics-service | `gitops/analytics-service/` | Deployment, Service |
| togglemaster-shared | `gitops/` (raiz) | Namespace, Ingress |

O `syncPolicy: automated` com `prune: true` e `selfHeal: true` significa:

- **automated**: sincroniza automaticamente (sem clique manual)
- **prune**: se algo for removido do Git, remove do cluster tambem
- **selfHeal**: se alguem mexer no cluster manualmente, o ArgoCD reverte para o que esta no Git

Na apresentacao: *"O ArgoCD garante que o cluster e sempre um espelho fiel do Git. Se alguem alterar manualmente, ele auto-corrige."*

### Passo 6/8: NGINX Ingress Controller

**O problema:** Voce tem 5 servicos, cada um com seu IP interno. Como o mundo externo acessa?

**A solucao:** O Ingress Controller e como um **recepcionista**. Ele recebe todas as requisicoes externas e roteia:

```
Internet → Load Balancer → NGINX Ingress Controller
                                    |
                           /auth/*  → auth-service:8001
                           /flags/* → flag-service:8002
                           /rules/* → targeting-service:8003
                           /eval/*  → evaluation-service:8004
                           /analytics/* → analytics-service:8005
```

Sem ele, cada servico precisaria de um LoadBalancer proprio (mais caro).

### Passo 7/8: Aguardar Pods

O script espera cada um dos 5 deployments ficar Ready. Isso inclui:

1. Puxar a imagem do ECR
2. Iniciar o container
3. Passar os health checks
4. Os 3 DB init jobs rodarem (criam as tabelas nos bancos)

**Estado final esperado:**
- 10 pods Running (2 replicas x 5 servicos)
- 3 jobs Completed (auth-db-init, flag-db-init, targeting-db-init)

### Passo 8/8: Gerar API Key (`generate-api-key.sh`)

**O problema:** O evaluation-service precisa de uma `SERVICE_API_KEY` para se autenticar nos outros servicos. Mas quem gera essa chave e o auth-service — que so funciona depois de estar rodando.

**A solucao:** O script:

1. Abre uma "ponte" local para o auth-service (`port-forward`)
2. Pede uma API key via `Authorization: Bearer $MASTER_KEY`
3. Recebe a chave
4. Atualiza o secret do evaluation-service com ela (`kubectl patch`)
5. Reinicia o evaluation-service para aplicar a mudanca

**O detalhe do header:** O auth-service espera `Authorization: Bearer`, que e o padrao RFC 6750 para tokens. E diferente de um header customizado como `X-Master-Key`. O campo no body e `name` (nao `description`).

```bash
# CORRETO:
curl -H "Authorization: Bearer $MASTER_KEY" -d '{"name": "evaluation-service"}'

# ERRADO (retorna "Acesso nao autorizado"):
curl -H "X-Master-Key: $MASTER_KEY" -d '{"description": "evaluation-service key"}'
```

---

## FASE 4: CI/CD — O Pipeline Automatico

Agora que esta tudo rodando, vamos entender como **futuras mudancas** chegam ao cluster automaticamente.

### O Fluxo Completo

```
Desenvolvedor faz push → GitHub Actions dispara → 5 jobs sequenciais:

┌─────────────────────────────────────────────────────────────┐
│  1. BUILD & TEST         "O codigo compila? Os testes       │
│                           passam?"                          │
│         ↓                                                   │
│  2. LINT                 "O codigo segue boas praticas?"    │
│         ↓                                                   │
│  3. SECURITY (DevSecOps) "Tem vulnerabilidade conhecida?"   │
│     ├── Trivy (SCA)      → Verifica dependencias            │
│     │                      (exit-code: 1 = bloqueante)      │
│     └── gosec/bandit     → Verifica o codigo (SAST)         │
│         ↓                                                   │
│  4. DOCKER BUILD + PUSH  "Empacota e guarda no ECR"         │
│     └── Trivy scan       → Verifica a imagem final          │
│         ↓                                                   │
│  5. UPDATE GITOPS        "Atualiza a tag da imagem no Git"  │
│     └── github-actions[bot] faz commit automatico           │
└─────────────────────────────────────────────────────────────┘
         ↓
ArgoCD detecta mudanca (~3 min) → Rolling update dos pods
```

### Por que 5 jobs e nao 1?

Se tudo fosse um job unico, um erro no lint cancelaria o build inteiro. Com jobs separados:
- Voce ve exatamente **qual etapa falhou**
- Cada etapa pode ter regras diferentes (ex: security pode ser `continue-on-error`)
- Na interface do GitHub Actions, cada job aparece como um bloco visual separado

### O conceito DevSecOps

**Dev** (Desenvolvimento) + **Sec** (Seguranca) + **Ops** (Operacoes) = Seguranca integrada ao pipeline, nao como etapa final.

| Tipo | Ferramenta | O que faz | Analogia |
|------|-----------|-----------|----------|
| **SCA** (Software Composition Analysis) | Trivy | Verifica se suas **dependencias** tem CVEs conhecidas | "O ingrediente que voce comprou esta vencido?" |
| **SAST** (Static Application Security Testing) | gosec / bandit | Verifica se **seu codigo** tem padroes inseguros | "Voce deixou a porta aberta no seu codigo?" |
| **Container Scan** | Trivy | Verifica a **imagem Docker** final | "O produto embalado esta seguro?" |

Na apresentacao: *"Implementamos seguranca em 3 camadas: SCA nas dependencias, SAST no codigo, e scan na imagem Docker final."*

### `permissions: contents: write` — Por que no job e nao no workflow?

Principio de **menor privilegio**. Apenas o job que precisa escrever no repo (`update-gitops`) recebe essa permissao. Os jobs de build, lint e security NAO precisam escrever — entao nao recebem.

```yaml
# CORRETO (menor privilegio):
update-gitops:
  permissions:
    contents: write    # So esse job pode escrever

# ERRADO (permissao ampla demais):
# permissions no nivel do workflow daria write para TODOS os jobs
```

Na apresentacao: *"Seguimos o principio de menor privilegio: apenas o job de update GitOps tem permissao de escrita."*

### O commit automatico do bot

Quando o CI termina, o job `update-gitops` faz:

```yaml
# 1. Atualiza a tag da imagem no deployment
sed -i "s|image: .*auth-service:.*|image: ECR/auth-service:abc1234|" gitops/auth-service/deployment.yaml

# 2. Commita e faz push
git commit -m "chore: update auth-service image to abc1234"
git push
```

Isso e a **ponte entre CI e CD**. O CI nao faz deploy. Ele apenas atualiza o Git. Quem faz deploy e o ArgoCD.

Na apresentacao: *"O CI/CD e desacoplado do deploy. O CI atualiza o Git, e o ArgoCD sincroniza. Isso e GitOps."*

---

## FASE 5: Manutencao — O Dia-a-Dia

### Por que credenciais de 4h?

AWS Academy usa credenciais temporarias. A cada 4h, elas expiram. Isso afeta:
- **evaluation-service e analytics-service** (precisam de AWS creds para SQS/DynamoDB)
- **GitHub Actions** (precisa de AWS creds para push no ECR)

O `update-aws-credentials.sh` resolve o lado do cluster. Os GitHub Secrets voce atualiza manualmente no repositorio.

---

## A Gestao de Secrets — O Diferencial de Seguranca

Este e um ponto **forte para a apresentacao**. Muitos projetos cometem o erro de guardar secrets no Git.

### Antes vs Depois

```
ANTES (inseguro):              DEPOIS (seguro):

deployment.yaml                deployment.yaml
├── Deployment                 ├── Deployment (referencia secretRef)
└── Secret (senha real!)       │
                               secret.yaml (GITIGNORED)
                               └── gerado por scripts, nunca no Git

                               secret.yaml.example (no Git)
                               └── template com placeholders
```

### O fluxo de secrets

```
terraform output ──┐
(endpoints RDS,    │
 Redis, SQS)       │
                    ├──→ generate-secrets.sh ──→ 8x secret.yaml ──→ apply-secrets.sh ──→ Cluster K8s
terraform.tfvars ──┤         (local)              (gitignored)       (kubectl apply)
(db_password)      │
                   │
AWS credentials ───┘
(env vars ou
 aws configure)
```

Na apresentacao: *"Nenhuma credencial real existe no repositorio. Os secrets sao gerados a partir do Terraform output e aplicados diretamente no cluster."*

---

## Roteiro de Falas para o Video

### Frases-chave por momento

| Momento | O que dizer |
|---------|-------------|
| **Terraform** | "Provisionamos 39 recursos em 5 modulos. Backend remoto com S3 e DynamoDB lock." |
| **Secrets** | "Secrets gerenciados fora do Git via scripts que leem o Terraform output." |
| **Docker** | "Build multi-plataforma com push pro ECR. Tag IMMUTABLE para seguranca." |
| **ArgoCD** | "6 Applications com auto-sync, prune e selfHeal. O cluster e sempre espelho do Git." |
| **CI/CD** | "5 stages: build, lint, security (SCA+SAST), Docker, GitOps update. DevSecOps completo." |
| **GitOps** | "CI nao faz deploy. CI atualiza o Git, ArgoCD sincroniza. Desacoplamento total." |
| **Seguranca** | "Trivy bloqueante, permissions no job (menor privilegio), secrets fora do Git." |
| **Pipeline falhando** | "Insiro um import nao usado → lint falha → mostro o erro → corrijo → pipeline passa." |
| **Pipeline passando** | "Mostro os 5 stages verdes → commit do bot → ArgoCD detecta → pods atualizados." |

### Perguntas que podem aparecer na defesa

| Pergunta | Resposta curta |
|----------|---------------|
| "Por que monorepo?" | "Simplifica CI/CD com path filters e centraliza GitOps num unico repositorio." |
| "Por que nao Helm?" | "Para o escopo do projeto, manifestos puros sao mais didaticos e transparentes." |
| "Por que ArgoCD e nao Flux?" | "ArgoCD tem UI web que facilita demonstracao e troubleshooting visual." |
| "O Trivy e bloqueante?" | "SCA sim (exit-code: 1). Container scan nao (exit-code: 0), pois CVEs de base image estao fora do nosso controle." |
| "Como renovam credenciais?" | "Script update-aws-credentials.sh atualiza os secrets no cluster. GitHub Secrets atualizamos manualmente." |
| "Secrets estao no Git?" | "Nao. Estao no .gitignore. Geramos via script a partir do Terraform output." |
| "Por que 2 replicas?" | "Alta disponibilidade basica. Se um pod cair, o outro continua servindo." |
| "O que e selfHeal?" | "Se alguem alterar algo direto no cluster, o ArgoCD reverte para o que esta no Git." |
