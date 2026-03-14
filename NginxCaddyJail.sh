#!/bin/bash

# Стили и цвета
BOLD='\033[1m'
B_CYAN='\033[1;36m'
B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'
B_RED='\033[1;31m'
NC='\033[0m'

# Проверка на запуск от root
if [ "$EUID" -ne 0 ]; then
    echo -e "${B_RED}Ошибка: Пожалуйста, запустите скрипт от имени root (sudo).${NC}"
    exit 1
fi

echo -e "${B_CYAN}${BOLD}Установка комплексной защиты сервера (RAW Table + ipset)${NC}"
echo -e "${BOLD}Выберите режим фильтрации:${NC}"
echo -e "1) ${B_GREEN}Nginx${NC} (через access.log)"
echo -e "2) ${B_GREEN}Caddy${NC} (через journalctl)"
echo -e "3) ${B_GREEN}Оба сервера${NC} (Nginx + Caddy)"
read -p "Ваш выбор (1-3): " CHOICE

# 1. Зависимости
echo -e "${B_YELLOW}Проверка компонентов (ipset, fail2ban, iptables-persistent)...${NC}"
apt-get update -qq && apt-get install -y ipset fail2ban iptables-persistent -qq > /dev/null 2>&1

# 2. Подготовка базы ipset
if ! ipset list bad_ips >/dev/null 2>&1; then
    echo -e "${B_YELLOW}Создание сетевой базы bad_ips...${NC}"
    ipset create -! bad_ips hash:net maxelem 1000000
fi

# 3. Создание экшена для интеграции Fail2Ban и ipset
cat << 'EOF' > /etc/fail2ban/action.d/ipset-allports.conf
[Definition]
actionstart = ipset create -! <name> hash:net maxelem 1000000
actionban = ipset add -! <name> <ip>
actionunban = ipset del -! <name> <ip>
actionstop = 
[Init]
name = bad_ips
EOF
chmod 644 /etc/fail2ban/action.d/ipset-allports.conf

# 4. Создание фильтров
echo -e "${B_YELLOW}Обновление фильтров в filter.d...${NC}"
cat << 'EOF' > /etc/fail2ban/filter.d/nginx-any-request.conf
[Definition]
failregex = ^<HOST> \-.*"(GET|POST|HEAD).*" (401|403|404|444)
ignoreregex =
EOF

cat << 'EOF' > /etc/fail2ban/filter.d/caddy-any-request.conf
[Definition]
failregex = .*"remote_ip":"<HOST>(:\d+)?".*
ignoreregex =
EOF

# 5. Формирование джейлов (Jails)
J_CONF="/etc/fail2ban/jail.d/custom-rate-limit.conf"
echo "" > $J_CONF

if [[ "$CHOICE" == "1" || "$CHOICE" == "3" ]]; then
    mkdir -p /var/log/nginx && touch /var/log/nginx/access.log
    cat << 'EOF' >> $J_CONF
[nginx-any-request]
enabled = true
port = http,https
filter = nginx-any-request
logpath = /var/log/nginx/access.log
banaction = ipset-allports[name=bad_ips]
findtime = 2
maxretry = 2
bantime = 24h
usedns = no
EOF
fi

if [[ "$CHOICE" == "2" || "$CHOICE" == "3" ]]; then
    cat << 'EOF' >> $J_CONF
[caddy-any-request]
enabled = true
port = http,https
filter = caddy-any-request
backend = systemd
journalmatch = _COMM=caddy
banaction = ipset-allports[name=bad_ips]
findtime = 2
maxretry = 2
bantime = 24h
usedns = no
EOF
fi

# 6. Настройка Firewall (RAW Table - сброс до conntrack)
echo -e "${B_YELLOW}Привязка правил к таблице RAW (экономия CPU)...${NC}"
if ! iptables -t raw -C PREROUTING -m set --match-set bad_ips src -j DROP 2>/dev/null; then
    iptables -t raw -I PREROUTING -m set --match-set bad_ips src -j DROP
    netfilter-persistent save > /dev/null 2>&1
fi

# 7. Финальный перезапуск
echo -e "${B_YELLOW}Перезапуск fail2ban...${NC}"
systemctl stop fail2ban
sleep 1
systemctl start fail2ban

echo -e "${B_GREEN}Установка успешно завершена!${NC}"
echo -e "-------------------------------------------------------"
echo -e "${BOLD}Статус защиты:${NC} ${B_CYAN}fail2ban-client status${NC}"
echo -e "${BOLD}Проверка RAW:${NC} ${B_RED}iptables -t raw -L -n -v | grep bad_ips${NC}"
echo -e "-------------------------------------------------------"
