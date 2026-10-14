#!/usr/bin/env bash
# Первичная настройка нового сервера Ubuntu 24.04. Запускать ОДИН раз от root.
# НЕ ТЕСТИРОВАНО на реальном сервере: прочитайте скрипт перед запуском.
# Что делает: обновляет систему, ставит Docker и базовую защиту, создаёт
# обычного пользователя vuli с вашим SSH-ключом, настраивает режим входа по SSH
# (вы выбираете строгость) и создаёт каталог /srv/git для репозиториев.
set -euo pipefail

NEW_USER="${NEW_USER:-vuli}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Запустите скрипт от root (sudo -i)." >&2
  exit 1
fi

echo "Вставьте ваш ПУБЛИЧНЫЙ SSH-ключ одной строкой (начинается с ssh-ed25519 или ssh-rsa):"
read -r PUBKEY
case "$PUBKEY" in
  ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *) ;;
  *) echo "Это не похоже на публичный ключ. Остановка." >&2; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade
apt-get install -y ufw fail2ban unattended-upgrades git curl tmux ca-certificates docker.io docker-compose-v2

# Пользователь без пароля: вход только по SSH-ключу.
if ! id "$NEW_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$NEW_USER"
fi
install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "/home/$NEW_USER/.ssh"
printf '%s\n' "$PUBKEY" > "/home/$NEW_USER/.ssh/authorized_keys"
chown "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh/authorized_keys"
chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"
# Группа docker даёт почти права root (замечание по безопасности: см. docs/09).
usermod -aG docker "$NEW_USER"
usermod -aG sudo "$NEW_USER"
read -rp "Разрешить пользователю $NEW_USER выполнять sudo (действия от root) без пароля? [y/N]: " SUDO_NOPASS
if [ "${SUDO_NOPASS:-n}" = "y" ] || [ "${SUDO_NOPASS:-n}" = "Y" ]; then
  echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-vuli
  chmod 440 /etc/sudoers.d/90-vuli
  visudo -cf /etc/sudoers.d/90-vuli
fi

# Фаервол: только SSH, HTTP, HTTPS.
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# Режим доступа по SSH (решает владелец).
echo
echo "Режим входа по SSH:"
echo "  1 = строгий: без root и без паролей (рекомендуется)"
echo "  2 = root разрешён только по ключу, пароли отключены"
echo "  3 = как есть: root и пароли разрешены (рискованно: ваш сервер будут подбирать боты;"
echo "      нужен очень длинный пароль root, fail2ban включён)"
read -rp "Выберите 1, 2 или 3 [1]: " SSH_MODE
SSH_MODE="${SSH_MODE:-1}"
case "$SSH_MODE" in
  1) printf 'PermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\n' > /etc/ssh/sshd_config.d/99-vuli-hardening.conf ;;
  2) printf 'PermitRootLogin prohibit-password\nPasswordAuthentication no\nPubkeyAuthentication yes\n' > /etc/ssh/sshd_config.d/99-vuli-hardening.conf ;;
  3) rm -f /etc/ssh/sshd_config.d/99-vuli-hardening.conf; echo "ВНИМАНИЕ: SSH оставлен без усиления." ;;
  *) echo "Нужно выбрать 1, 2 или 3." >&2; exit 1 ;;
esac
sshd -t

# Каталог для git-репозиториев на сервере.
install -d -m 750 -o "$NEW_USER" -g "$NEW_USER" /srv/git

systemctl enable --now fail2ban
dpkg-reconfigure -f noninteractive unattended-upgrades

systemctl reload ssh

cat <<MSG

Готово. ВАЖНО: не закрывайте эту консоль.
Откройте второе окно и проверьте вход:  ssh ${NEW_USER}@<IP-сервера>
(в режиме 2 и 3 можно проверить и root)
Только если вход работает, закрывайте root-сессию.
MSG
