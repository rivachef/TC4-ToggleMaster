# Resumo Executivo - ToggleMaster Fase 3

## Objetivo

Automatizar toda a infraestrutura e o ciclo de vida dos 5 microsservicos do ToggleMaster utilizando praticas de IaC (Terraform), CI/CD (GitHub Actions com DevSecOps) e GitOps (ArgoCD), conforme requisitos do Tech Challenge Fase 3 da Pos Tech FIAP.

---

## Conformidade com os Requisitos do Desafio

### 1. Infraestrutura como Codigo (Terraform) - COMPLETO

| Requisito | Implementacao | Status |
|-----------|--------------|--------|
| Networking (VPC, Subnets, IGW, Route Tables) | `terraform/modules/networking/` - VPC com 2 AZs, subnets publicas + privadas, IGW, NAT Gateway | OK |
| Cluster EKS com Node Groups | `terraform/modules/eks/` - EKS v1.29, Node Group t3.medium x2, usando LabRole (Academy) | OK |
| 3 instancias RDS PostgreSQL | `terraform/modules/databases/` - auth-db, flag-db, targeting-db (db.t3.micro) | OK |
| 1 Cluster ElastiCache Redis | `terraform/modules/databases/` - cache.t3.micro, single node | OK |
| 1 Tabela DynamoDB | `terraform/modules/databases/` - ToggleMasterAnalytics (PAY_PER_REQUEST) | OK |
| 1 Fila SQS | `terraform/modules/messaging/` - togglemaster-queue | OK |
| 5 repositorios ECR | `terraform/modules/ecr/` - um por microsservico | OK |
| Backend remoto S3 | `terraform/backend.tf` - S3 + DynamoDB lock table | OK |
| LabRole (Academy) | Passada via variavel `lab_role_arn`, sem criar IAM roles | OK |

**Total de recursos AWS provisionados: 39**

### 2. Pipeline CI/CD com DevSecOps - COMPLETO

| Requisito | Implementacao | Status |
|-----------|--------------|--------|
| Workflows para os 5 microsservicos | `.github/workflows/ci-{auth,flag,targeting,evaluation,analytics}-service.yaml` | OK |
| Trigger em Push e Pull Request na main | Path filters: `microservices/<service>/**` | OK |
| Build & Unit Test | Go: `go build + go test` / Python: `pip install + pytest` | OK |
| Linter/Static Analysis | Go: `golangci-lint v1.61` / Python: `flake8` | OK |
| SCA (Trivy filesystem scan) | `aquasecurity/trivy-action` com severity CRITICAL,HIGH | OK |
| SAST (gosec/bandit) | Go: `gosec v2.20.0` / Python: `bandit -r . --severity-level high` | OK |
| Docker Build | Build da imagem com tag do commit hash (short SHA) | OK |
| Container Scan (Trivy) | Trivy scan na imagem Docker apos build | OK |
| Push para ECR | Login via `aws-actions` + push com tag `:<commit-sha>` | OK |

### 3. Entrega Continua (CD) e GitOps - COMPLETO

| Requisito | Implementacao | Status |
|-----------|--------------|--------|
| Repositorio de GitOps (pasta separada no monorepo) | `gitops/` com manifestos K8s por servico | OK |
| Instalacao do ArgoCD no EKS | `argocd/install.sh` + manifests oficiais | OK |
| Atualizacao automatica da tag no GitOps | Job `update-gitops` no CI - `sed` no deployment.yaml + commit automatico | OK |
| ArgoCD sync automatico | `syncPolicy.automated` com `prune: true` e `selfHeal: true` | OK |
| ArgoCD gerenciando os 5 microsservicos | 6 Applications: 5 servicos + 1 shared (namespace + ingress) | OK |

---

## Arquitetura Implementada

```
                         GitHub Repository (monorepo)
                                    |
                    +---------------+---------------+
                    |               |               |
              terraform/      microservices/     gitops/
              (IaC)           (codigo fonte)    (K8s manifests)
                    |               |               |
                    v               v               v
              AWS Resources   GitHub Actions    ArgoCD
              (39 recursos)   (CI/CD pipeline)  (GitOps sync)
                    |               |               |
                    +-------+-------+               |
                            |                       |
                         AWS EKS <------------------+
                     (5 microsservicos)
```

### Fluxo CI/CD Completo (Validado End-to-End)

```
Dev Push (main) --> GitHub Actions dispara
    |
    +--> Build & Unit Test
    +--> Linter (golangci-lint / flake8)
    +--> Security Scan (Trivy SCA + gosec/bandit SAST)
    +--> Docker Build + Trivy Container Scan
    +--> Push para ECR (tag: <commit-sha>)
    +--> Update GitOps (commit automatico no deployment.yaml)
    |
ArgoCD detecta mudanca (~3 min polling)
    |
    +--> Rolling update dos pods no EKS
    +--> Nova versao em producao
```

---

## Tecnologias Utilizadas

| Camada | Tecnologia | Versao |
|--------|-----------|--------|
| IaC | Terraform | >= 1.5 |
| Cloud | AWS (EKS, RDS, ElastiCache, DynamoDB, SQS, ECR, VPC) | - |
| Orquestracao | Kubernetes (EKS) | 1.29 |
| CI/CD | GitHub Actions | v4 |
| SAST | gosec (Go), bandit (Python) | v2.20.0, latest |
| SCA | Trivy (Aqua Security) | latest |
| Linter | golangci-lint (Go), flake8 (Python) | v1.61, latest |
| Container Registry | AWS ECR | - |
| GitOps | ArgoCD | stable |
| Ingress | NGINX Ingress Controller | v1.12.0 |
| Backend | Go 1.21, Python 3.12/Flask | - |
| Banco de Dados | PostgreSQL (RDS), Redis (ElastiCache), DynamoDB | 16, 7, - |
| Mensageria | AWS SQS | - |

---

## Desafios Encontrados e Decisoes Tomadas

### 1. AWS Academy (LabRole)
- **Desafio:** Nao e possivel criar IAM Roles/Policies via Terraform
- **Decisao:** Usar `data source` para importar a LabRole existente via variavel `lab_role_arn`
- **Impacto:** Zero - funciona perfeitamente com a role pre-existente

### 2. Credenciais temporarias (4h)
- **Desafio:** Sessao AWS Academy expira a cada 4 horas
- **Decisao:** Criado script `update-aws-credentials.sh` que atualiza automaticamente os secrets do evaluation-service e analytics-service no cluster. GitHub Secrets tambem precisam ser atualizados a cada sessao. Scripts suportam credenciais via env vars ou `aws configure`.
- **Impacto:** Operacional simplificado - um unico comando renova as credenciais no cluster

### 3. CVEs em dependencias transitivas
- **Desafio:** Trivy encontrou CVEs CRITICAL em bibliotecas Go upstream (golang.org/x/net)
- **Decisao:** Trivy filesystem scan opera com `exit-code: '1'` (bloqueante) para manter rigor DevSecOps. CVEs em dependencias transitivas devem ser resolvidas atualizando as libs.
- **Impacto:** Pipeline bloqueante para vulnerabilidades criticas, garantindo seguranca real

### 4. gosec incompativel com Go 1.21
- **Desafio:** Versao latest do gosec exige Go >= 1.25
- **Decisao:** Pinar gosec em v2.20.0 (compativel com Go 1.21) + `continue-on-error: true`
- **Impacto:** SAST funcional com versao estavel

### 5. GITHUB_TOKEN sem permissao de push
- **Desafio:** Job de update GitOps falhava ao fazer `git push`
- **Decisao:** Adicionar `permissions: contents: write` apenas no job `update-gitops` (principio de menor privilegio), nao no workflow global
- **Impacto:** Resolvido - pipeline agora faz push automatico, com permissoes minimas

### 7. Secrets expostos no git
- **Desafio:** Credenciais e senhas estavam inline nos `deployment.yaml` commitados no repositorio
- **Decisao:** Separar secrets em arquivos `secret.yaml` dedicados, adicionar ao `.gitignore`, e criar scripts de automacao (`generate-secrets.sh`, `apply-secrets.sh`) que geram e aplicam os secrets a partir do `terraform output`
- **Impacto:** Seguranca - nenhuma credencial real no repositorio; operacional - setup automatizado via scripts

### 6. Security Groups EKS -> RDS/Redis
- **Desafio:** Pods no EKS nao conseguiam acessar RDS e Redis
- **Decisao:** Criar regras de security group adicionais em `terraform/main.tf` permitindo o cluster SG do EKS acessar as portas 5432 (Postgres) e 6379 (Redis)
- **Impacto:** Resolvido - comunicacao funcional entre cluster e databases

---

## Metricas do Projeto

- **Recursos AWS:** 39 provisionados via Terraform
- **Microsservicos:** 5 (2 Go + 3 Python)
- **Pods Kubernetes:** 10 (2 replicas cada) + 3 DB init jobs
- **Pipelines CI/CD:** 5 (um por microsservico)
- **ArgoCD Applications:** 6 (5 servicos + 1 shared)
- **Tempo de setup completo:** ~30-40 minutos (do zero ao ambiente funcional)
- **Tempo medio do pipeline CI/CD:** ~5-7 minutos (Build -> GitOps update)
