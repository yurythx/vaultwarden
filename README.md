# Cofre de Senhas — Vaultwarden

Serviço de gerenciamento de senhas self-hosted baseado em [Vaultwarden](https://github.com/dani-garcia/vaultwarden) (implementação compatível com a API do Bitwarden), com banco de dados PostgreSQL, para uso interno da Prefeitura de Rondonópolis/MT.

Domínio de produção: `https://cofre.rondonopolis.mt.gov.br` (atrás de um proxy reverso em `192.168.0.218`). O host que roda os containers publica a aplicação em `192.168.0.225:8081` (HTTP) e `192.168.0.225:3012` (WebSocket), endereços que o proxy reverso usa como upstream.

## Sumário

- [Arquitetura](#arquitetura)
- [Pré-requisitos](#pré-requisitos)
- [Instalação rápida](#instalação-rápida)
- [Estrutura de arquivos](#estrutura-de-arquivos)
- [Variáveis de ambiente](#variáveis-de-ambiente)
- [Operações comuns](#operações-comuns)
- [Segurança](#segurança)
- [Backup e restauração](#backup-e-restauração)
- [Integração com Keycloak (SSO)](#integração-com-keycloak-sso)
- [Documentação completa de deploy](#documentação-completa-de-deploy)

## Arquitetura

```
                 ┌───────────────────────────┐
Internet/Rede  →  │  Proxy Reverso             │
Interna           │  192.168.0.218 — TLS/HTTPS │
                 └─────────────┬─────────────┘
                               │ 192.168.0.225:8081 (HTTP)
                               │ 192.168.0.225:3012 (WS)
                 ┌─────────────▼─────────────┐
                 │   vaultwarden (app)        │
                 │   porta 80 / 3012          │
                 └─────────────┬─────────────┘
                               │ rede interna "vw-internal"
                 ┌─────────────▼─────────────┐
                 │   vaultwarden-db           │
                 │   PostgreSQL 16 (alpine)   │
                 └────────────────────────────┘
```

- O container `vaultwarden-db` **não expõe porta ao host** — só é acessível pela rede interna do Docker.
- O container `vaultwarden` publica as portas 8081 (HTTP→80) e 3012 (WS) **apenas no IP `192.168.0.225`** do host — o endereço que o proxy reverso em `192.168.0.218` usa como upstream. Todo o tráfego externo deve passar pelo proxy reverso com TLS; garanta via firewall que só `192.168.0.218` alcança essas portas.

## Pré-requisitos

- Docker Engine ≥ 24 e Docker Compose Plugin ≥ 2.20 (`docker compose version`)
- Um proxy reverso (Nginx, Traefik ou Caddy) com certificado TLS válido para o domínio
- Acesso de saída para envio de e-mail (SMTP) — necessário para verificação de conta, convite e recuperação de senha
- IP `192.168.0.225` configurado na interface de rede do host, com portas 8081/3012 livres (ou ajuste conforme necessidade)

## Instalação rápida

```bash
git clone <url-do-repositorio> vaultwarden
cd vaultwarden
./scripts/setup-env.sh   # gera o .env com senha do banco e ADMIN_TOKEN já corretos
docker compose up -d
docker compose ps
```

Para o passo a passo completo (geração de senhas, token de administrador, configuração do proxy reverso, primeiro acesso e hardening), veja **[DEPLOY.md](DEPLOY.md)**.

## Estrutura de arquivos

```
.
├── docker-compose.yml       # definição dos serviços (app + banco)
├── .env.example             # modelo de variáveis de ambiente (versionado)
├── .env                     # variáveis reais com segredos (NÃO versionado)
├── .gitignore
├── scripts/
│   └── setup-env.sh         # gera o .env (senha do banco + hash do ADMIN_TOKEN)
├── README.md                # este arquivo
└── DEPLOY.md                # passo a passo de instalação e deploy
```

## Variáveis de ambiente

Todas as variáveis são configuradas em `.env` (copiado de `.env.example`). Principais:

| Variável              | Descrição                                                        | Padrão recomendado |
|------------------------|-------------------------------------------------------------------|---------------------|
| `POSTGRES_PASSWORD`    | Senha do usuário do banco                                          | gerar com `openssl rand -hex 32` |
| `DOMAIN`               | URL pública completa (com `https://`)                              | `https://cofre.rondonopolis.mt.gov.br` |
| `ADMIN_TOKEN`          | Hash Argon2id do token do painel `/admin`                           | gerado automaticamente por `./scripts/setup-env.sh` |
| `SIGNUPS_ALLOWED`      | Permite autocadastro de contas                                     | `false` (habilitar só na criação inicial) |
| `INVITATIONS_ALLOWED`  | Permite que admins convidem novos usuários                         | `true` |
| `SIGNUPS_VERIFY`       | Exige verificação de e-mail no cadastro                            | `true` |
| `SMTP_*`               | Configuração de e-mail (obrigatório para reset de senha e convites) | conforme servidor de e-mail da prefeitura |

Veja todos os campos comentados em [.env.example](.env.example).

## Operações comuns

```bash
# subir/atualizar a stack
docker compose up -d

# ver logs
docker compose logs -f vaultwarden

# checar saúde dos containers
docker compose ps

# parar
docker compose down          # mantém os volumes (dados)

# atualizar a versão do Vaultwarden
# 1. edite VAULTWARDEN_VERSION no .env para a tag desejada
docker compose pull vaultwarden
docker compose up -d vaultwarden
```

## Segurança

- Nunca use `SIGNUPS_ALLOWED=true` permanentemente em produção — habilite só para criar as contas iniciais e desative em seguida.
- O `ADMIN_TOKEN` deve ser armazenado como **hash Argon2id**, nunca em texto puro (veja DEPLOY.md).
- As portas do app só ficam expostas em `192.168.0.225` (IP do host na rede interna); a exposição pública deve ser feita exclusivamente via proxy reverso (`192.168.0.218`) com TLS. Restrinja por firewall para que só esse IP alcance 8081/3012.
- O banco de dados não tem porta publicada — acesso apenas pela rede interna `vw-internal`.
- Fixe (pin) a versão da imagem `vaultwarden/server` em produção em vez de usar `latest`, para evitar atualizações não planejadas.

## Backup e restauração

Ver seção dedicada em [DEPLOY.md](DEPLOY.md#9-backup-e-restauração).

## Integração com Keycloak (SSO)

**Adiada por decisão do time em 2026-07-30.** A imagem oficial `vaultwarden/server` (usada aqui) não tem suporte a OIDC/SSO — esse recurso só existe no fork comunitário `ghcr.io/timshel/oidcwarden`, cuja release estável atual (`v2026.7.0-1`/`latest`) tem um bug de migração de banco que impede o login via SSO (só a tag `:testing` funciona, testado ponta a ponta contra um Keycloak real). Decidiu-se manter a imagem oficial e revisitar quando o fork publicar uma tag estável corrigida, ou o recurso for incorporado ao projeto upstream. Detalhes completos, incluindo os dados do client Keycloak já levantados (`sso.rondonopolis.mt.gov.br`, client `vaultwarden-sso`), estão em [DEPLOY.md](DEPLOY.md#10-integração-com-keycloak-sso--adiada).

## Documentação completa de deploy

O passo a passo detalhado de instalação, configuração do proxy reverso, geração de segredos, primeiro acesso administrativo e checklist de produção está em **[DEPLOY.md](DEPLOY.md)**.
