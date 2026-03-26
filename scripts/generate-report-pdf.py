#!/usr/bin/env python3
"""
Gera o PDF de Relatorio de Entrega - Tech Challenge Fase 3
ToggleMaster: Feature Flag Management Platform
"""

from fpdf import FPDF
import os

class ReportPDF(FPDF):
    def header(self):
        self.set_font("Helvetica", "B", 10)
        self.set_text_color(100, 100, 100)
        self.cell(0, 8, "ToggleMaster - Tech Challenge Fase 3 | FIAP Pós Tech", align="C")
        self.ln(8)
        self.set_draw_color(0, 102, 204)
        self.set_line_width(0.5)
        self.line(10, self.get_y(), 200, self.get_y())
        self.ln(4)

    def footer(self):
        self.set_y(-15)
        self.set_font("Helvetica", "I", 8)
        self.set_text_color(128, 128, 128)
        self.cell(0, 10, f"Pagina {self.page_no()}/{{nb}}", align="C")

    def section_title(self, title):
        self.set_font("Helvetica", "B", 14)
        self.set_text_color(0, 51, 102)
        self.cell(0, 10, title, new_x="LMARGIN", new_y="NEXT")
        self.set_draw_color(0, 102, 204)
        self.set_line_width(0.3)
        self.line(10, self.get_y(), 120, self.get_y())
        self.ln(4)

    def subsection_title(self, title):
        self.set_font("Helvetica", "B", 11)
        self.set_text_color(0, 76, 153)
        self.cell(0, 8, title, new_x="LMARGIN", new_y="NEXT")
        self.ln(1)

    def body_text(self, text):
        self.set_font("Helvetica", "", 10)
        self.set_text_color(40, 40, 40)
        self.multi_cell(0, 5.5, text)
        self.ln(2)

    def bold_text(self, label, value):
        self.set_font("Helvetica", "B", 10)
        self.set_text_color(40, 40, 40)
        self.cell(0, 6, label, new_x="LMARGIN", new_y="NEXT")
        self.set_font("Helvetica", "", 10)
        self.multi_cell(0, 5.5, value)
        self.ln(2)

    def bullet(self, text, indent=15):
        x = self.get_x()
        self.set_font("Helvetica", "", 10)
        self.set_text_color(40, 40, 40)
        self.cell(indent, 5.5, "  -")
        self.multi_cell(0, 5.5, text)
        self.ln(1)

    def table_header(self, cols, widths):
        self.set_font("Helvetica", "B", 9)
        self.set_fill_color(0, 76, 153)
        self.set_text_color(255, 255, 255)
        for i, col in enumerate(cols):
            self.cell(widths[i], 7, col, border=1, fill=True, align="C")
        self.ln()

    def table_row(self, cols, widths, fill=False):
        self.set_font("Helvetica", "", 9)
        self.set_text_color(40, 40, 40)
        if fill:
            self.set_fill_color(230, 240, 255)
        else:
            self.set_fill_color(255, 255, 255)
        for i, col in enumerate(cols):
            align = "L" if i == 0 else "C"
            if i == len(cols) - 1:
                align = "R"
            self.cell(widths[i], 6, col, border=1, fill=True, align=align)
        self.ln()

    def table_row_total(self, cols, widths):
        self.set_font("Helvetica", "B", 9)
        self.set_text_color(255, 255, 255)
        self.set_fill_color(0, 51, 102)
        for i, col in enumerate(cols):
            align = "L" if i == 0 else "C"
            if i == len(cols) - 1:
                align = "R"
            self.cell(widths[i], 7, col, border=1, fill=True, align=align)
        self.ln()


def generate_report():
    pdf = ReportPDF()
    pdf.alias_nb_pages()
    pdf.set_auto_page_break(auto=True, margin=20)

    # =========================================
    # PAGE 1 - CAPA
    # =========================================
    pdf.add_page()
    pdf.ln(30)

    # Logo/Title area
    pdf.set_font("Helvetica", "B", 28)
    pdf.set_text_color(0, 51, 102)
    pdf.cell(0, 15, "ToggleMaster", align="C", new_x="LMARGIN", new_y="NEXT")

    pdf.set_font("Helvetica", "", 14)
    pdf.set_text_color(80, 80, 80)
    pdf.cell(0, 8, "Feature Flag Management Platform", align="C", new_x="LMARGIN", new_y="NEXT")

    pdf.ln(10)
    pdf.set_draw_color(0, 102, 204)
    pdf.set_line_width(1)
    pdf.line(60, pdf.get_y(), 150, pdf.get_y())
    pdf.ln(10)

    pdf.set_font("Helvetica", "B", 16)
    pdf.set_text_color(0, 76, 153)
    pdf.cell(0, 10, "Relatório de Entrega", align="C", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "", 13)
    pdf.set_text_color(80, 80, 80)
    pdf.cell(0, 8, "Tech Challenge - Fase 3", align="C", new_x="LMARGIN", new_y="NEXT")
    pdf.cell(0, 8, "Pós Tech FIAP - Software Architecture", align="C", new_x="LMARGIN", new_y="NEXT")

    pdf.ln(20)

    # Participants box
    pdf.set_fill_color(240, 245, 255)
    pdf.set_draw_color(0, 102, 204)
    pdf.rect(30, pdf.get_y(), 150, 50, style="DF")

    pdf.set_xy(35, pdf.get_y() + 5)
    pdf.set_font("Helvetica", "B", 11)
    pdf.set_text_color(0, 51, 102)
    pdf.cell(140, 7, "Participantes", align="C", new_x="LMARGIN", new_y="NEXT")

    pdf.set_x(35)
    pdf.set_font("Helvetica", "", 10)
    pdf.set_text_color(40, 40, 40)
    participants = [
        ("Luiz Cesar Paulino da Costa", "RM367925"),
        ("Marcelo Oliveira", "RM368372"),
        ("Ricardo Pimenta", "RM368911"),
        ("Sergio Muller", "RM368926"),
    ]
    for name, rm in participants:
        pdf.set_x(45)
        pdf.cell(90, 7, name, align="L")
        pdf.cell(40, 7, rm, align="R", new_x="LMARGIN", new_y="NEXT")

    pdf.ln(25)

    # Links
    pdf.set_font("Helvetica", "B", 10)
    pdf.set_text_color(0, 51, 102)
    pdf.cell(0, 7, "Repositório GitHub:", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "", 10)
    pdf.set_text_color(0, 102, 204)
    pdf.cell(0, 6, "https://github.com/rivachef/TC3-ToggleMaster", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(3)

    pdf.set_font("Helvetica", "B", 10)
    pdf.set_text_color(0, 51, 102)
    pdf.cell(0, 7, "Vídeo de Apresentação:", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "I", 10)
    pdf.set_text_color(128, 128, 128)
    pdf.cell(0, 6, "https://drive.google.com/drive/folders/1ArwAm0wAv2JCtY_9Ri7GRv0qqWXig3Nu", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(3)

    pdf.set_font("Helvetica", "B", 10)
    pdf.set_text_color(0, 51, 102)
    pdf.cell(0, 7, "Documentação Completa:", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "", 10)
    pdf.set_text_color(0, 102, 204)
    pdf.cell(0, 6, "https://github.com/rivachef/TC3-ToggleMaster/tree/main/docs", new_x="LMARGIN", new_y="NEXT")

    # =========================================
    # PAGE 2 - VISAO GERAL
    # =========================================
    pdf.add_page()
    pdf.section_title("1. Visão Geral do Projeto")

    pdf.body_text(
        "O ToggleMaster é uma plataforma de gerenciamento de feature flags composta por "
        "5 microsserviços. Na Fase 3 do Tech Challenge, o objetivo foi automatizar toda a "
        "infraestrutura e o ciclo de vida desses microsserviços utilizando práticas de "
        "Infrastructure as Code (Terraform), CI/CD com DevSecOps (GitHub Actions) e "
        "GitOps (ArgoCD)."
    )

    pdf.subsection_title("Arquitetura de Microsserviços")

    # Services table
    widths = [40, 22, 18, 52, 58]
    pdf.table_header(["Serviço", "Linguagem", "Porta", "Banco de Dados", "Função"], widths)
    rows = [
        ["auth-service", "Go 1.23", "8001", "PostgreSQL (RDS)", "Autenticação e API Keys"],
        ["flag-service", "Python 3.12", "8002", "PostgreSQL (RDS)", "CRUD de feature flags"],
        ["targeting-service", "Python 3.12", "8003", "PostgreSQL (RDS)", "Regras de targeting"],
        ["evaluation-service", "Go 1.23", "8004", "Redis (ElastiCache)", "Avaliação de flags"],
        ["analytics-service", "Python 3.12", "8005", "DynamoDB + SQS", "Eventos e analytics"],
    ]
    for i, row in enumerate(rows):
        pdf.table_row(row, widths, fill=(i % 2 == 0))

    pdf.ln(5)

    pdf.subsection_title("Estrutura do Monorepo")
    pdf.set_font("Courier", "", 9)
    pdf.set_text_color(40, 40, 40)
    mono = (
        "TC3-ToggleMaster/\n"
        "  terraform/          -> IaC (5 módulos AWS)\n"
        "  microservices/      -> Código fonte (5 serviços)\n"
        "  .github/workflows/  -> CI/CD (5 pipelines)\n"
        "  gitops/             -> Manifestos K8s (ArgoCD)\n"
        "  argocd/             -> Configuração ArgoCD\n"
        "  scripts/            -> Automação (setup, secrets, credentials)\n"
        "  docs/               -> Documentação completa"
    )
    pdf.multi_cell(0, 5, mono)
    pdf.ln(4)

    # =========================================
    # FLUXO CI/CD
    # =========================================
    pdf.section_title("2. Pipeline CI/CD Completo")

    pdf.body_text(
        "Cada microsserviço possui um workflow independente no GitHub Actions, disparado "
        "por push ou pull request na branch main (com path filters). O pipeline executa "
        "5 jobs sequenciais que implementam práticas DevSecOps:"
    )

    pdf.subsection_title("Jobs do Pipeline (sequenciais)")

    widths2 = [12, 45, 55, 78]
    pdf.table_header(["#", "Job", "Ferramentas", "Descrição"], widths2)
    jobs = [
        ["1", "Build & Unit Test", "go build/pytest", "Compilação e execução de testes unitários"],
        ["2", "Lint / Static Analysis", "golangci-lint/flake8", "Verificação de qualidade e estilo de código"],
        ["3", "Security Scan", "Trivy SCA + gosec/bandit", "Análise de vulnerabilidades (CRITICAL bloqueia)"],
        ["4", "Docker Build & Push", "Docker + Trivy + ECR", "Build da imagem, scan de container, push ao ECR"],
        ["5", "Update GitOps", "git + sed", "Atualiza tag da imagem no deployment.yaml"],
    ]
    for i, row in enumerate(jobs):
        pdf.table_row(row, widths2, fill=(i % 2 == 0))

    pdf.ln(5)

    pdf.subsection_title("Regras de Segurança (DevSecOps)")
    pdf.bullet("SCA (Trivy): Bloqueia o pipeline se encontrar vulnerabilidades CRITICAL (exit-code: 1)")
    pdf.bullet("SAST (gosec/bandit): Executa análise estática com continue-on-error para não bloquear por falsos positivos")
    pdf.bullet("Container Scan (Trivy): Verifica a imagem Docker após build (exit-code: 0, informativo)")
    pdf.bullet("Permissões mínimas: contents: write apenas no job update-gitops (princípio de menor privilégio)")

    pdf.ln(3)
    pdf.subsection_title("GitOps com ArgoCD (Entrega Contínua)")
    pdf.body_text(
        "Após o CI atualizar o manifesto no diretório gitops/, o ArgoCD detecta a mudança "
        "automaticamente (polling ~3 min) e realiza o sync dos pods no cluster EKS. "
        "Configurado com syncPolicy.automated, prune: true e selfHeal: true para garantir "
        "que o cluster sempre reflita o estado desejado no Git. "
        "São 6 ArgoCD Applications: 5 serviços + 1 shared (namespace + ingress)."
    )

    # =========================================
    # DESAFIOS E DECISOES
    # =========================================
    pdf.section_title("3. Desafios Encontrados e Decisões Tomadas")

    challenges = [
        (
            "AWS Academy (LabRole)",
            "Não é possível criar IAM Roles/Policies via Terraform no ambiente Academy.",
            "Usar data source para importar a LabRole existente via variável lab_role_arn, "
            "eliminando qualquer dependência de criação de IAM."
        ),
        (
            "Credenciais temporárias (4h)",
            "A sessão AWS Academy expira a cada 4 horas, exigindo renovação de credenciais "
            "no cluster Kubernetes e nos GitHub Secrets.",
            "Criação do script update-aws-credentials.sh que atualiza automaticamente os "
            "secrets no cluster. Suporte a credenciais via env vars ou aws configure."
        ),
        (
            "CVEs CRITICAL em dependências Go",
            "Trivy encontrou CVE-2024-45337 (CRITICAL) em golang.org/x/crypto v0.20.0, "
            "bloqueando o pipeline conforme regra DevSecOps.",
            "Upgrade de Go 1.21 para Go 1.23 em ambos os serviços Go, atualizando "
            "golang.org/x/crypto para v0.35.0 e golang.org/x/net para v0.33.0. "
            "Pipeline voltou a passar com zero vulnerabilidades CRITICAL."
        ),
        (
            "gosec incompatível com Go 1.21",
            "Versão latest do gosec exige Go >= 1.25, causando falha no SAST.",
            "Fixar gosec em v2.20.0 (compatível com Go 1.23) + continue-on-error: true "
            "para não bloquear pipeline por alertas MEDIUM (ex: G114 - http.ListenAndServe)."
        ),
        (
            "GITHUB_TOKEN sem permissão de push",
            "Job update-gitops falhava ao fazer git push para atualizar manifestos.",
            "Adicionar permissions: contents: write APENAS no job update-gitops "
            "(princípio de menor privilégio), não no workflow global."
        ),
        (
            "Race condition em pipelines concorrentes",
            "Quando múltiplos serviços são alterados no mesmo commit, os pipelines rodam "
            "em paralelo e o segundo git push falha (remote has new commits).",
            "Adicionado git pull --rebase origin main antes do push, com retry loop "
            "(até 3 tentativas com 5s de intervalo) em todos os 5 workflows."
        ),
        (
            "ECR tag immutability em re-runs",
            "Ao re-executar um pipeline falhado, o push ao ECR falha porque a image tag "
            "(commit SHA) já existe e os repositórios usam tags imutáveis.",
            "Adicionado check com aws ecr describe-images antes do push. "
            "Se a tag já existe, o push é ignorado graciosamente."
        ),
        (
            "Secrets expostos no repositório Git",
            "Credenciais e senhas de banco estavam inline nos deployment.yaml commitados.",
            "Separação dos secrets em arquivos dedicados (secret.yaml) adicionados ao "
            ".gitignore. Scripts de automação (generate-secrets.sh, apply-secrets.sh) "
            "geram e aplicam os secrets a partir do terraform output."
        ),
        (
            "Security Groups EKS -> RDS/Redis",
            "Pods no EKS não conseguiam acessar RDS PostgreSQL e ElastiCache Redis.",
            "Criação de regras de security group adicionais em terraform/main.tf "
            "permitindo o cluster SG do EKS acessar portas 5432 e 6379."
        ),
    ]

    for i, (title, challenge, decision) in enumerate(challenges):
        pdf.set_font("Helvetica", "B", 10)
        pdf.set_text_color(0, 51, 102)
        pdf.cell(0, 6, f"{i+1}. {title}", new_x="LMARGIN", new_y="NEXT")

        pdf.set_font("Helvetica", "B", 9)
        pdf.set_text_color(180, 0, 0)
        pdf.set_x(12)
        pdf.cell(30, 5, "Desafio:", new_x="LMARGIN", new_y="NEXT")
        pdf.set_font("Helvetica", "", 9)
        pdf.set_text_color(40, 40, 40)
        pdf.set_x(15)
        pdf.multi_cell(180, 5, challenge)

        pdf.set_font("Helvetica", "B", 9)
        pdf.set_text_color(0, 120, 0)
        pdf.set_x(12)
        pdf.cell(30, 5, "Decisão:", new_x="LMARGIN", new_y="NEXT")
        pdf.set_font("Helvetica", "", 9)
        pdf.set_text_color(40, 40, 40)
        pdf.set_x(15)
        pdf.multi_cell(180, 5, decision)
        pdf.ln(3)

    # =========================================
    # PAGE 4 - ESTIMATIVA DE CUSTOS
    # =========================================
    pdf.add_page()
    pdf.section_title("4. Estimativa de Custos AWS")

    pdf.body_text(
        "A tabela abaixo apresenta a estimativa mensal de custos da infraestrutura "
        "provisionada pelo Terraform na região us-east-1 (N. Virginia), considerando "
        "preços on-demand da AWS vigentes em 2025."
    )

    pdf.subsection_title("4.1 Custos Fixos Mensais (infraestrutura base)")

    wc = [52, 32, 18, 30, 28, 30]
    pdf.table_header(["Componente", "Tipo/Instância", "Qtd", "Preço/Hora", "Horas/Mês", "Custo/Mês"], wc)

    cost_rows = [
        ["EKS Cluster", "-", "1", "$0.10", "730", "$73.00"],
        ["EKS Nodes (EC2)", "t3.medium", "2", "$0.0416", "730", "$60.74"],
        ["RDS Auth DB", "db.t3.micro", "1", "$0.0166", "730", "$12.12"],
        ["RDS Flag DB", "db.t3.micro", "1", "$0.0166", "730", "$12.12"],
        ["RDS Targeting DB", "db.t3.micro", "1", "$0.0166", "730", "$12.12"],
        ["ElastiCache Redis", "cache.t3.micro", "1", "$0.0166", "730", "$12.12"],
        ["NAT Gateway", "-", "1", "$0.045", "730", "$32.85"],
    ]
    for i, row in enumerate(cost_rows):
        pdf.table_row(row, wc, fill=(i % 2 == 0))
    pdf.table_row_total(["SUBTOTAL FIXO", "", "", "", "", "$215.07"], wc)

    pdf.ln(6)
    pdf.subsection_title("4.2 Custos Variáveis (dependem do uso)")

    wv = [52, 62, 38, 38]
    pdf.table_header(["Serviço", "Modelo de Cobrança", "Estimativa Baixa", "Estimativa Alta"], wv)

    var_rows = [
        ["RDS Storage (60 GB)", "$0.115/GB-mes (gp2)", "$6.90", "$6.90"],
        ["DynamoDB", "On-demand ($1.25/M writes)", "$0.50", "$25.00"],
        ["SQS", "$0.40/milhão de requests", "$0.10", "$5.00"],
        ["NAT Gateway (dados)", "$0.045/GB processado", "$2.00", "$20.00"],
        ["ECR Storage", "$0.10/GB-mes", "$1.00", "$5.00"],
        ["S3 (tfstate)", "$0.023/GB-mes", "$0.01", "$0.01"],
        ["Data Transfer Out", "$0.09/GB (após 1 GB)", "$0.00", "$10.00"],
    ]
    for i, row in enumerate(var_rows):
        pdf.table_row(row, wv, fill=(i % 2 == 0))
    pdf.table_row_total(["SUBTOTAL VARIAVEL", "", "$10.51", "$71.91"], wv)

    pdf.ln(6)
    pdf.subsection_title("4.3 Resumo Geral de Custos")

    wr = [80, 55, 55]
    pdf.table_header(["Categoria", "Custo Mensal (min)", "Custo Mensal (max)"], wr)
    pdf.table_row(["Custos Fixos (infraestrutura)", "$215.07", "$215.07"], wr, fill=True)
    pdf.table_row(["Custos Variáveis (uso)", "$10.51", "$71.91"], wr, fill=False)
    pdf.table_row(["Auto-scaling (se 4 nodes)", "$0.00", "$60.74"], wr, fill=True)
    pdf.table_row_total(["TOTAL ESTIMADO", "$225.58", "$347.72"], wr)

    pdf.ln(5)
    pdf.set_font("Helvetica", "I", 9)
    pdf.set_text_color(100, 100, 100)
    pdf.multi_cell(0, 5,
        "Observações:\n"
        "- Preços referentes à região us-east-1 (N. Virginia), on-demand, março/2025\n"
        "- AWS Academy fornece créditos que cobrem esses custos durante o período do curso\n"
        "- EKS Node Group pode escalar de 1 a 4 nodes (t3.medium) conforme demanda\n"
        "- Repositórios ECR configurados com lifecycle policy (max 10 imagens)\n"
        "- Não inclui custos de GitHub Actions (gratuito para repositórios públicos)"
    )

    # =========================================
    # PAGE 5 - INFRAESTRUTURA DETALHADA
    # =========================================
    pdf.add_page()
    pdf.section_title("5. Infraestrutura AWS (Terraform)")

    pdf.body_text(
        "Total de 39 recursos AWS provisionados via Terraform, organizados em 5 módulos "
        "reutilizáveis. Backend remoto com S3 para persistência do state e DynamoDB para "
        "lock de concorrência."
    )

    pdf.subsection_title("Módulos Terraform")

    wm = [35, 75, 80]
    pdf.table_header(["Módulo", "Recursos Principais", "Configuração"], wm)
    modules = [
        ["networking", "VPC, 4 Subnets, IGW, NAT, Routes, SGs", "2 AZs, CIDR 10.0.0.0/16, pub + priv"],
        ["eks", "EKS Cluster, Node Group", "K8s 1.31, t3.medium x2 (1-4), AL2023"],
        ["databases", "3 RDS, 1 ElastiCache, 1 DynamoDB", "PostgreSQL 17.4, Redis, PAY_PER_REQUEST"],
        ["messaging", "1 SQS Queue", "Standard, visibility 30s, retention 1d"],
        ["ecr", "5 ECR Repositories", "Immutable tags, scan on push, lifecycle 10"],
    ]
    for i, row in enumerate(modules):
        pdf.table_row(row, wm, fill=(i % 2 == 0))

    pdf.ln(5)

    pdf.subsection_title("Diagrama de Arquitetura AWS")
    pdf.set_font("Courier", "", 8)
    pdf.set_text_color(40, 40, 40)
    diagram = (
        "                         Internet\n"
        "                            |\n"
        "                    [ Internet Gateway ]\n"
        "                            |\n"
        "              +--- VPC 10.0.0.0/16 ---+\n"
        "              |                        |\n"
        "     [Public Subnet 1a]      [Public Subnet 1b]\n"
        "      10.0.1.0/24             10.0.2.0/24\n"
        "         |                       |\n"
        "     [NAT GW]          [NGINX Ingress LB]\n"
        "         |                       |\n"
        "     [Private Subnet 1a]  [Private Subnet 1b]\n"
        "      10.0.11.0/24        10.0.22.0/24\n"
        "         |                       |\n"
        "         +--- EKS Cluster -------+\n"
        "         |   (2x t3.medium)      |\n"
        "         |                       |\n"
        "    [ 5 Microsservicos ]    [ ArgoCD ]\n"
        "    [ 10 Pods total   ]    [ (GitOps) ]\n"
        "         |                       \n"
        "    +----+----+----+             \n"
        "    |    |    |    |             \n"
        "  [RDS] [RDS] [RDS] [ElastiCache]\n"
        "  auth  flag  targ   Redis       \n"
        "                                  \n"
        "  [DynamoDB]    [SQS Queue]       \n"
        "  analytics     messaging         "
    )
    pdf.multi_cell(0, 4, diagram)

    pdf.ln(5)

    # =========================================
    # PAGE 6 - METRICAS E CONFORMIDADE
    # =========================================
    pdf.add_page()
    pdf.section_title("6. Métricas e Conformidade")

    pdf.subsection_title("Métricas do Projeto")
    metrics = [
        "Recursos AWS provisionados via Terraform: 39",
        "Microsserviços: 5 (2 Go + 3 Python)",
        "Pods Kubernetes em execução: 10 (2 réplicas por serviço)",
        "Pipelines CI/CD independentes: 5 (um por microsserviço)",
        "ArgoCD Applications: 6 (5 serviços + 1 shared)",
        "Tempo médio do pipeline CI/CD: ~5-7 minutos",
        "Tempo de setup completo (do zero): ~30-40 minutos",
        "Vulnerabilidades CRITICAL no código: 0 (após upgrade Go 1.23)",
    ]
    for m in metrics:
        pdf.bullet(m)

    pdf.ln(4)
    pdf.subsection_title("Tecnologias utilizadas")

    wt = [50, 80, 60]
    pdf.table_header(["Camada", "Tecnologia", "Versão"], wt)
    techs = [
        ["IaC", "Terraform", ">= 1.5"],
        ["Cloud", "AWS (EKS, RDS, ElastiCache, DynamoDB, SQS, ECR)", "-"],
        ["Orquestração", "Kubernetes (EKS)", "1.31"],
        ["CI/CD", "GitHub Actions", "v4"],
        ["SCA", "Trivy (Aqua Security)", "latest"],
        ["SAST", "gosec (Go) / bandit (Python)", "v2.20.0 / latest"],
        ["Linter", "golangci-lint (Go) / flake8 (Python)", "v1.61 / latest"],
        ["Container Registry", "AWS ECR", "-"],
        ["GitOps", "ArgoCD", "stable"],
        ["Ingress", "NGINX Ingress Controller", "v1.12.0"],
        ["Backend", "Go / Python Flask", "1.23 / 3.12"],
        ["Bancos de Dados", "PostgreSQL, Redis, DynamoDB", "17.4, 7.x, -"],
    ]
    for i, row in enumerate(techs):
        pdf.table_row(row, wt, fill=(i % 2 == 0))

    pdf.add_page()
    pdf.subsection_title("Checklist de Conformidade com os Requisitos")

    wk = [110, 80]
    pdf.table_header(["Requisito", "Status"], wk)
    reqs = [
        ["Terraform com módulos e backend remoto (S3)", "COMPLETO"],
        ["EKS com Node Groups e auto-scaling", "COMPLETO"],
        ["3 RDS PostgreSQL + ElastiCache + DynamoDB + SQS", "COMPLETO"],
        ["5 repositórios ECR com scan on push", "COMPLETO"],
        ["CI/CD com Build, Test, Lint para cada serviço", "COMPLETO"],
        ["Security Scan: SCA (Trivy) + SAST (gosec/bandit)", "COMPLETO"],
        ["Regra de bloqueio para CVEs CRITICAL", "COMPLETO"],
        ["Docker Build + Container Scan + Push ECR", "COMPLETO"],
        ["GitOps com ArgoCD (sync automático)", "COMPLETO"],
        ["Manifestos K8s separados por serviço (gitops/)", "COMPLETO"],
        ["Pipeline atualiza automaticamente tag da imagem", "COMPLETO"],
        ["Documentação completa no repositório", "COMPLETO"],
    ]
    for i, row in enumerate(reqs):
        pdf.table_row(row, wk, fill=(i % 2 == 0))

    # =========================================
    # SAVE
    # =========================================
    output_dir = os.path.dirname(os.path.abspath(__file__))
    output_path = os.path.join(output_dir, "..", "docs", "RELATORIO-ENTREGA-FASE3.pdf")
    output_path = os.path.normpath(output_path)
    pdf.output(output_path)
    print(f"PDF gerado com sucesso: {output_path}")
    return output_path


if __name__ == "__main__":
    generate_report()
