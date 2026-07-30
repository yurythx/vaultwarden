#!/usr/bin/env bash
# Gera o arquivo .env de produção a partir do .env.example, automatizando os
# dois passos manuais mais propensos a erro (senha do banco e hash Argon2id
# do ADMIN_TOKEN, já com o "$" escapado corretamente para o Docker Compose).
#
# Uso:
#   ./scripts/setup-env.sh
#
# Requer: docker, openssl. Não precisa rodar como root.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then
  read -r -p ".env já existe. Sobrescrever? [y/N] " resp
  case "$resp" in
    [yY]*) ;;
    *) echo "Cancelado. Nada foi alterado."; exit 0 ;;
  esac
fi

cp .env.example .env

echo "==> Gerando POSTGRES_PASSWORD..."
DB_PASSWORD=$(openssl rand -hex 32)
sed -i.bak "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${DB_PASSWORD}|" .env

echo "==> Senha do painel administrativo (/admin)"
echo "    Esta é a senha que você vai digitar depois para entrar em /admin."
echo "    Só o hash Argon2id dela vai para o .env; guarde a senha em um"
echo "    cofre/gestor de senhas da equipe de infraestrutura."
while true; do
  read -r -s -p "Digite a senha do admin: " ADMIN_PASS; echo
  read -r -s -p "Confirme a senha do admin: " ADMIN_PASS_CONFIRM; echo
  if [ "$ADMIN_PASS" = "$ADMIN_PASS_CONFIRM" ] && [ -n "$ADMIN_PASS" ]; then
    break
  fi
  echo "As senhas não coincidem (ou estão vazias). Tente novamente."
done

echo "==> Gerando hash Argon2id (preset m=65540,t=3,p=4)..."
SALT=$(openssl rand -base64 32)
RAW_HASH=$(printf '%s' "$ADMIN_PASS" | docker run --rm -i alpine sh -c \
  "apk add --no-cache argon2 >/dev/null 2>&1 && argon2 '$SALT' -e -id -k 65540 -t 3 -p 4")
ESCAPED_HASH=$(printf '%s' "$RAW_HASH" | sed 's/\$/\$\$/g')

# Usa um delimitador incomum (#) no sed porque o hash contém "/" e "$"
sed -i.bak "s#^ADMIN_TOKEN=.*#ADMIN_TOKEN=${ESCAPED_HASH}#" .env
rm -f .env.bak
unset ADMIN_PASS ADMIN_PASS_CONFIRM RAW_HASH

chmod 600 .env

echo ""
echo "==> .env gerado com sucesso (permissões 600)."
echo ""
echo "Ainda faltam ajustes manuais antes de subir a stack:"
echo "  - Confira DOMAIN (já vem preenchido com o domínio de produção)"
echo "  - Preencha as variáveis SMTP_* (comentadas no .env)"
echo "  - Opcional: fixe VAULTWARDEN_VERSION/POSTGRES_VERSION em vez de latest/16-alpine"
echo ""
echo "Depois: docker compose up -d && docker compose ps"
