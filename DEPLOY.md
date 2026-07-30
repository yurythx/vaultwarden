# Passo a passo — Instalação e Deploy do Vaultwarden

Guia operacional completo para colocar o serviço em produção atrás do proxy reverso `192.168.0.218`, no domínio `https://cofre.rondonopolis.mt.gov.br`.

## 1. Pré-requisitos no servidor

```bash
docker --version
docker compose version
```

Requisitos mínimos:
- Docker Engine ≥ 24
- Docker Compose Plugin ≥ 2.20
- 2 vCPU / 2 GB RAM livres (limites configurados: 1.5 vCPU / 512 MB para o app + 1 vCPU / 512 MB para o banco)
- IP `192.168.0.225` atribuído à interface de rede do host, com portas 8081 e 3012 livres

## 2. Obter os arquivos do projeto

```bash
git clone <url-do-repositorio> vaultwarden
cd vaultwarden
```

## 3. Configurar o arquivo `.env`

### Opção automática (recomendada)

O script abaixo faz os passos 3 e 4 inteiros: copia o `.env.example`, gera uma `POSTGRES_PASSWORD` forte, pede a senha do admin (duas vezes, sem eco no terminal), gera o hash Argon2id e já grava com o `$` escapado corretamente. Testado de ponta a ponta nesta stack (subida completa + login em `/admin` confirmado).

```bash
./scripts/setup-env.sh
```

Ao final, abra o `.env` e confira/ajuste manualmente:
- `DOMAIN` (já vem preenchido com `https://cofre.rondonopolis.mt.gov.br`)
- As variáveis `SMTP_*` (vêm comentadas — descomente e preencha)
- `VAULTWARDEN_VERSION`/`POSTGRES_VERSION` se quiser fixar uma versão diferente do padrão

Depois disso, pule direto para a [seção 5](#5-subir-a-stack).

### Opção manual (passo a passo, caso prefira não usar o script)

```bash
cp .env.example .env
```

Gere uma senha forte para o banco de dados (só caracteres hexadecimais, evita qualquer problema com caracteres especiais):

```bash
openssl rand -hex 32
```

Copie o resultado para `POSTGRES_PASSWORD` no `.env`. Ajuste também `DOMAIN` se necessário (já vem preenchido com o domínio de produção).

## 4. Gerar o token do painel administrativo (`/admin`) — manual

Pule esta seção se já rodou `./scripts/setup-env.sh` acima (ele faz isso automaticamente).

O `ADMIN_TOKEN` **não deve** ficar em texto puro. Gere um hash Argon2id (preset recomendado pelo próprio Bitwarden/Vaultwarden: `m=65540,t=3,p=4`) usando o utilitário `argon2` em um container descartável — não é preciso instalar nada no host:

```bash
SALT=$(openssl rand -base64 32)
printf '%s' 'SUA_SENHA_ADMIN_AQUI' | docker run --rm -i alpine sh -c \
  "apk add --no-cache argon2 >/dev/null 2>&1 && argon2 '$SALT' -e -id -k 65540 -t 3 -p 4"
```

Isso imprime um hash no formato:

```
$argon2id$v=19$m=65540,t=3,p=4$<salt em base64>$<hash em base64>
```

> Guarde a senha original (`SUA_SENHA_ADMIN_AQUI`) em um cofre/gestor de senhas da equipe de infraestrutura — é ela que você vai digitar depois para entrar em `/admin`. Só o hash vai para o `.env`.

**Passo crítico — escape do `$` no `.env`:** o Docker Compose interpola qualquer `$` que encontrar dentro do arquivo `.env`, mesmo em variáveis usadas apenas via `env_file` (confirmado em teste real desta stack: sem o escape, o token chega truncado/corrompido dentro do container e o login em `/admin` falha). Antes de colar o hash em `ADMIN_TOKEN`, duplique **todos** os `$` para `$$`. Você pode gerar o valor já escapado direto com `sed`:

```bash
SALT=$(openssl rand -base64 32)
printf '%s' 'SUA_SENHA_ADMIN_AQUI' | docker run --rm -i alpine sh -c \
  "apk add --no-cache argon2 >/dev/null 2>&1 && argon2 '$SALT' -e -id -k 65540 -t 3 -p 4" \
  | sed 's/\$/\$\$/g'
```

Cole o resultado (com os `$$` duplicados) em `ADMIN_TOKEN` no `.env`. Depois de subir a stack, confirme que o valor chegou correto no container:

```bash
docker compose exec vaultwarden printenv ADMIN_TOKEN
# deve mostrar o hash com "$" simples: $argon2id$v=19$m=65540,t=3,p=4$...
```

## 5. Subir a stack

```bash
docker compose up -d
docker compose ps
```

Aguarde os dois serviços ficarem `healthy`:

```bash
watch docker compose ps
```

Verifique os logs se algo não subir:

```bash
docker compose logs -f vaultwarden
docker compose logs -f vaultwarden-db
```

Teste localmente no próprio servidor:

```bash
curl -f http://192.168.0.225:8081/alive
```

## 6. Configurar o proxy reverso (192.168.0.218)

### Firewall no host dos containers (192.168.0.225)

Libere as portas 8081/3012 **somente** para o IP do proxy reverso. Escolha o comando conforme o firewall da distribuição:

```bash
# ufw (Debian/Ubuntu)
sudo ufw allow from 192.168.0.218 to any port 8081 proto tcp
sudo ufw allow from 192.168.0.218 to any port 3012 proto tcp
sudo ufw reload

# firewalld (RHEL/CentOS/Rocky)
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.0.218" port port="8081" protocol="tcp" accept'
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.0.218" port port="3012" protocol="tcp" accept'
sudo firewall-cmd --reload
```

Confirme que nenhuma outra origem consegue acessar:

```bash
# de uma máquina que NÃO é o proxy reverso, deve dar timeout/recusado
curl -v --max-time 5 http://192.168.0.225:8081/alive
```

### Certificado TLS

Se a prefeitura já tem uma CA interna ou um certificado emitido para `cofre.rondonopolis.mt.gov.br`, copie o `.crt`/`.key` para o servidor do proxy (`192.168.0.218`) nos caminhos usados no bloco Nginx abaixo. Caso contrário, usando Let's Encrypt (requer que a porta 80 esteja acessível publicamente para o domínio):

```bash
sudo certbot certonly --webroot -w /var/www/certbot -d cofre.rondonopolis.mt.gov.br
# gera os arquivos em /etc/letsencrypt/live/cofre.rondonopolis.mt.gov.br/
```

Ajuste `ssl_certificate`/`ssl_certificate_key` no bloco abaixo para o caminho real gerado.

### Exemplo Nginx

```nginx
server {
    listen 443 ssl http2;
    server_name cofre.rondonopolis.mt.gov.br;

    ssl_certificate     /etc/ssl/certs/cofre.crt;
    ssl_certificate_key /etc/ssl/private/cofre.key;

    client_max_body_size 128M;

    location / {
        proxy_pass http://192.168.0.225:8081;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # WebSocket para sincronização em tempo real
    location /notifications/hub {
        proxy_pass http://192.168.0.225:3012;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

server {
    listen 80;
    server_name cofre.rondonopolis.mt.gov.br;
    return 301 https://$host$request_uri;
}
```

> O proxy (`192.168.0.218`) roda em máquina separada da que hospeda os containers, por isso as portas no `docker-compose.yml` estão vinculadas ao IP `192.168.0.225` (a interface de rede do host Docker), não a `127.0.0.1`. Garanta por firewall que só `192.168.0.218` alcança as portas 8081/3012 desse host.

Recarregue o Nginx:

```bash
nginx -t && systemctl reload nginx
```

## 7. Primeiro acesso e criação dos administradores

1. Habilite cadastro temporariamente: no `.env`, defina `SIGNUPS_ALLOWED=true` e rode `docker compose up -d vaultwarden`.
2. Acesse `https://cofre.rondonopolis.mt.gov.br` e crie as contas dos administradores/servidores responsáveis.
3. Acesse o painel administrativo em `https://cofre.rondonopolis.mt.gov.br/admin`, usando a senha (não o hash) definida no passo 4.
4. No painel `/admin`, confira organizações e usuários criados.
5. **Desative o autocadastro**: volte o `.env` para `SIGNUPS_ALLOWED=false` e rode novamente `docker compose up -d vaultwarden`.
6. A partir daqui, novos usuários só entram por convite (`INVITATIONS_ALLOWED=true`, já habilitado).

## 8. Teste de fumaça pós-deploy

Rode estes checks depois de qualquer subida (deploy inicial ou atualização) para confirmar que está tudo no ar antes de liberar para os usuários:

```bash
# 1. containers saudáveis
docker compose ps
# ambos devem mostrar "healthy"

# 2. app respondendo direto no host
curl -f http://192.168.0.225:8081/alive

# 3. app respondendo através do proxy/domínio público, com TLS válido
curl -fI https://cofre.rondonopolis.mt.gov.br/alive

# 4. WebSocket acessível (deve responder com upgrade/erro 4xx, não timeout/conexão recusada)
curl -fI https://cofre.rondonopolis.mt.gov.br/notifications/hub

# 5. painel administrativo carrega
curl -fI https://cofre.rondonopolis.mt.gov.br/admin
```

Depois, manualmente pelo navegador:
- [ ] Login em `https://cofre.rondonopolis.mt.gov.br` com uma conta de teste
- [ ] Criar um item de senha e confirmar que salva
- [ ] Abrir o mesmo item em outra aba/dispositivo e ver a sincronização em tempo real (valida o WebSocket)
- [ ] Se SMTP estiver configurado: disparar "esqueci minha senha" e confirmar recebimento do e-mail

## 9. Backup e restauração

### Backup

```bash
mkdir -p backups
DATA=$(date +%Y%m%d_%H%M%S)

# dump lógico do PostgreSQL
docker compose exec -T vaultwarden-db pg_dump -U vw_user -d vaultwarden > "backups/db_${DATA}.sql"

# dados de anexos, attachments, ícones e config (volume da aplicação)
docker run --rm \
  -v vaultwarden_vw_app_data:/data \
  -v "$(pwd)/backups":/backup \
  alpine tar czf "/backup/app_data_${DATA}.tar.gz" -C /data .
```

> Automatize com um `cron` diário e copie os arquivos gerados para um destino externo (storage da prefeitura, S3 interno, etc.). Nunca deixe os backups apenas no mesmo host.

### Restauração

```bash
# banco de dados
cat backups/db_AAAAMMDD_HHMMSS.sql | docker compose exec -T vaultwarden-db psql -U vw_user -d vaultwarden

# dados da aplicação (com a stack parada)
docker compose stop vaultwarden
docker run --rm \
  -v vaultwarden_vw_app_data:/data \
  -v "$(pwd)/backups":/backup \
  alpine sh -c "rm -rf /data/* && tar xzf /backup/app_data_AAAAMMDD_HHMMSS.tar.gz -C /data"
docker compose start vaultwarden
```

## 10. Integração com Keycloak (SSO) — Adiada

**Status em 2026-07-30: adiada por decisão do time.** Registro do que foi investigado, para retomar sem perder o contexto.

Dados do Keycloak de produção já levantados:
- Authority: `https://sso.rondonopolis.mt.gov.br/realms/<realm>` (confirmar o nome exato do realm)
- Client ID: `vaultwarden-sso`
- Client Secret: já gerado no Keycloak — solicite novamente à equipe responsável quando for retomar (não foi persistido em nenhum arquivo deste repositório)
- Redirect URI a cadastrar no client Keycloak: `https://cofre.rondonopolis.mt.gov.br/identity/connect/oidc-signin`

**Por que foi adiado:** o suporte a SSO/OIDC não existe na imagem oficial `vaultwarden/server` — confirmado inspecionando o binário (`strings`/`grep` não encontram nenhuma variável `SSO_*`). O recurso só existe no fork comunitário [`Timshel/OIDCWarden`](https://github.com/Timshel/OIDCWarden) (`ghcr.io/timshel/oidcwarden`). Testando esse fork ponta a ponta contra um Keycloak real (realm de teste, client confidencial, usuário de teste):
- A tag versionada estável (`v2026.7.0-1`, igual a `:latest` no momento do teste) **quebra o login SSO**: erro `column "code_response_error" of relation "sso_auth" does not exist" — bug de empacotamento (a migração do banco embutida na imagem não bate com o binário compilado).
- Somente a tag `:testing` (digest diferente) tinha a migração corrigida; com ela, o fluxo completo funcionou (redirect para o Keycloak → login → callback em `/identity/connect/oidc-signin` → troca de código bem-sucedida).

**Quando retomar, checar antes de reconfigurar:**
1. Se já existe uma tag estável do fork com a correção (ver [releases](https://github.com/Timshel/OIDCWarden/releases) e comparar com o commit da tag `:testing` usada no teste).
2. Se o recurso foi incorporado ao projeto oficial `dani-garcia/vaultwarden` (acompanhar [discussões de SSO](https://github.com/dani-garcia/vaultwarden/discussions) no repositório oficial).
3. Trocar a imagem em `docker-compose.yml`/`.env` (`VAULTWARDEN_VERSION`/`image`) só depois de validar a tag escolhida com um Keycloak de teste — o mesmo tipo de teste ponta a ponta descrito acima.

Variáveis a configurar quando a imagem certa estiver definida (mesmos nomes usados pelo fork e documentados no [SSO.md](https://github.com/Timshel/OIDCWarden/blob/main/SSO.md) do projeto):

```
SSO_ENABLED=true
SSO_ONLY=false          # login híbrido: senha local OU Keycloak (decisão já tomada com o time)
SSO_PKCE=true
SSO_AUTHORITY=https://sso.rondonopolis.mt.gov.br/realms/<realm>
SSO_CLIENT_ID=vaultwarden-sso
SSO_CLIENT_SECRET=<gerar novamente no Keycloak>
SSO_SCOPES=openid profile email offline_access
```

No client do Keycloak, configure: tipo confidencial, `Standard Flow` habilitado, Redirect URI acima, escopo padrão `offline_access` e "Access Token Lifespan" de pelo menos 10 minutos (o padrão de 5 min conflita com a detecção de expiração do frontend do Bitwarden/Vaultwarden).

## 11. Atualização de versão

1. Consulte as tags disponíveis em https://hub.docker.com/r/vaultwarden/server/tags
2. Faça backup (seção 9) antes de atualizar.
3. Defina `VAULTWARDEN_VERSION=<tag-desejada>` no `.env`.
4. Aplique:

```bash
docker compose pull vaultwarden
docker compose up -d vaultwarden
docker compose logs -f vaultwarden
```

## 12. Checklist de produção

- [ ] IP `192.168.0.225` atribuído à interface de rede do host e porta 8081/3012 livres
- [ ] `.env` gerado (via `./scripts/setup-env.sh` ou manualmente) com senha forte de banco e fora do controle de versão
- [ ] `ADMIN_TOKEN` configurado como hash Argon2id, com `$` escapado (`$$`) no `.env`
- [ ] `SIGNUPS_ALLOWED=false` após criação das contas iniciais
- [ ] SMTP configurado e testado (reset de senha / convites)
- [ ] TLS válido configurado no proxy reverso, domínio confere com `DOMAIN`
- [ ] `VAULTWARDEN_VERSION` e `POSTGRES_VERSION` fixados (não usando `latest` de forma indefinida)
- [ ] Firewall no host `192.168.0.225` liberando 8081/3012 só para `192.168.0.218`
- [ ] Rotina de backup agendada e testada (restauração validada em ambiente de teste)
- [ ] Teste de fumaça pós-deploy (seção 8) executado com sucesso

## 13. Troubleshooting

| Sintoma | Causa provável | Ação |
|---|---|---|
| `vaultwarden-db` fica `unhealthy` | Senha incorreta ou volume corrompido | `docker compose logs vaultwarden-db` |
| `vaultwarden` não inicia, erro de conexão com banco | `DATABASE_URL` com credenciais divergentes do `.env` | Confirme `POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB` e recrie: `docker compose up -d --force-recreate vaultwarden` |
| Painel `/admin` retorna 404 ou não autentica | `ADMIN_TOKEN` com `$` não escapado (Compose interpola e corrompe o hash) | Confirme com `docker compose exec vaultwarden printenv ADMIN_TOKEN` que o hash está íntegro; no `.env` cada `$` deve estar duplicado (`$$`) — veja passo 4 |
| WebSocket não sincroniza em tempo real | Proxy reverso não repassando `/notifications/hub` para a porta 3012 | Revise o bloco `location /notifications/hub` no Nginx |
| E-mails de convite/reset não chegam | SMTP não configurado ou credenciais inválidas | Preencha as variáveis `SMTP_*` no `.env` e reinicie: `docker compose up -d vaultwarden` |
