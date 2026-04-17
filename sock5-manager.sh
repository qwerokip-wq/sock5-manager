#!/bin/bash

# Пути к файлам
DB_FILE="/etc/sock5-manager/proxies.db"
CONFIG_DIR="/etc/sock5-manager"
DANTE_CONF="/etc/danted.conf"
DANTE_ALT_CONF="/etc/dante.conf"

# Глобальные переменные
SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || echo "YOUR_IP")

if [[ -z "$SERVER_IP" || "$SERVER_IP" == "YOUR_IP" ]]; then
    SERVER_IP="YOUR_IP"
    echo "Предупреждение: Не удалось определить внешний IP. В ссылках будет 'YOUR_IP'."
fi

# Создаем директорию для базы данных, если её нет
mkdir -p "$CONFIG_DIR"
touch "$DB_FILE"

# Функция для установки необходимых пакетов
function install_requirements() {
    if ! command -v danted &> /dev/null; then
        echo "Установка необходимых пакетов..."
        apt update && apt install -y dante-server apache2-utils qrencode curl ufw
    fi
}

# Функция для определения сетевого интерфейса
function get_interface() {
    ip route get 8.8.8.8 | awk -- '{print $5}' | head -n 1
}

# Функция для генерации случайного порта
function generate_random_port() {
    local gen_port
    while :; do
        gen_port=$((RANDOM % 64512 + 1024))
        if ! ss -tulnp | awk '{print $4}' | grep -q ":$gen_port"; then
            echo $gen_port
            return
        fi
    done
}

# Функция для генерации случайной строки
function generate_random_string() {
    local length=$1
    tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "$length"
}

# Функция для обновления конфигурации dante
function update_dante_config() {
    local INTERFACE=$(get_interface)
    local count=0
    local db_user db_pass db_port
    
    # Сначала собираем все internal блоки в переменную
    local INTERNAL_LINES=""
    while IFS=":" read -r db_user db_pass db_port || [[ -n "$db_user" ]]; do
        db_user=$(echo "$db_user" | tr -d '\r' | xargs)
        db_port=$(echo "$db_port" | tr -d '\r' | xargs)
        if [[ -n "$db_user" && -n "$db_port" ]]; then
            INTERNAL_LINES="${INTERNAL_LINES}internal: 0.0.0.0 port = $db_port\n"
            ((count++))
        fi
    done < "$DB_FILE"

    # Если прокси нет, danted не запустится. Используем заглушку на 1080
    if [[ $count -eq 0 ]]; then
        INTERNAL_LINES="internal: 0.0.0.0 port = 1080\n"
    fi

    # ПЕРЕЗАПИСЫВАЕМ конфиг ПОЛНОСТЬЮ (как в sock5.sh)
    # Используем Heredoc для гарантии того, что старый конфиг будет стерт
    cat > "$DANTE_CONF" <<EOL
logoutput: stderr
$(printf "$INTERNAL_LINES")
external: $INTERFACE
socksmethod: username
user.privileged: root
user.notprivileged: nobody

client pass {
        from: 0.0.0.0/0 to: 0.0.0.0/0
        log: error
}

socks pass {
        from: 0.0.0.0/0 to: 0.0.0.0/0
        method: username
        protocol: tcp udp
        log: error
}
EOL

    # Дублируем в альтернативный путь для надежности
    cat "$DANTE_CONF" > "$DANTE_ALT_CONF"

    # Перезапуск службы
    systemctl restart danted
    sleep 2
    if ! systemctl is-active --quiet danted; then
        echo "Ошибка: Служба danted не смогла запуститься. Причина:"
        journalctl -u danted -n 10 --no-pager
        return 1
    fi
}

# Функция добавления прокси
function add_proxy() {
    local username password port choice port_choice
    echo "--- Добавление нового прокси ---"
    
    # Логин и пароль
    read -p "Хотите ввести логин и пароль вручную? (y/n): " choice
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        read -p "Введите имя пользователя: " username
        read -s -p "Введите пароль: " password
        echo
    else
        username=$(generate_random_string 8)
        password=$(generate_random_string 12)
        echo "Сгенерированы: Логин: $username, Пароль: $password"
    fi

    # Проверка на существование пользователя
    if grep -q "^$username:" "$DB_FILE"; then
        echo "Ошибка: Пользователь $username уже существует!"
        return
    fi

    # Порт
    read -p "Хотите ввести порт вручную? (y/n): " port_choice
    if [[ "$port_choice" == "y" || "$port_choice" == "Y" ]]; then
        while :; do
            read -p "Введите порт (1024-65535): " port
            if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then
                if ! ss -tulnp | awk '{print $4}' | grep -q ":$port"; then
                    break
                else
                    echo "Этот порт уже занят в системе."
                fi
            else
                echo "Некорректный порт."
            fi
        done
    else
        port=$(generate_random_port)
        echo "Сгенерирован порт: $port"
    fi

    # Создаём системного пользователя
    useradd -r -s /bin/false "$username"
    echo "$username:$password" | chpasswd

    # Сохраняем в БД
    echo "$username:$password:$port" >> "$DB_FILE"
    
    # Открываем порт в ufw
    ufw allow "$port/tcp"

    # Обновляем конфиг dante
    update_dante_config
    
    # Вывод информации
    echo "============================================================="
    echo "SOCKS5-прокси добавлен успешно!"
    echo "IP: $SERVER_IP | Порт: $port"
    echo "Логин: $username | Пароль: $password"
    echo "-------------------------------------------------------------"
    echo "Ссылка для Telegram (нажмите):"
    echo "tg://socks?server=$SERVER_IP&port=$port&user=$username&pass=$password"
    echo "Или альтернативная ссылка:"
    echo "https://t.me/socks?server=$SERVER_IP&port=$port&user=$username&pass=$password"
    echo "-------------------------------------------------------------"
    echo "Строка для браузеров:"
    echo "$username:$password@$SERVER_IP:$port"
    echo "============================================================="
}

# Функция списка прокси
function list_proxies() {
    local i=1
    local l_user l_pass l_port
    echo "--- Список активных прокси ---"
    if [[ ! -s "$DB_FILE" ]]; then
        echo "Прокси пока не созданы."
        return
    fi
    
    echo "============================================================="
    while IFS=":" read -r l_user l_pass l_port || [[ -n "$l_user" ]]; do
        l_user=$(echo "$l_user" | tr -d '\r' | xargs)
        l_pass=$(echo "$l_pass" | tr -d '\r' | xargs)
        l_port=$(echo "$l_port" | tr -d '\r' | xargs)
        
        if [[ -n "$l_user" && -n "$l_port" ]]; then
            echo "[$i] Пользователь: $l_user"
            echo "    Порт:         $l_port"
            echo "    Пароль:       $l_pass"
            echo "    TG Ссылка:    tg://socks?server=$SERVER_IP&port=$l_port&user=$l_user&pass=$l_pass"
            echo "    HTTPS Ссылка: https://t.me/socks?server=$SERVER_IP&port=$l_port&user=$l_user&pass=$l_pass"
            echo "    Строка:       $l_user:$l_pass@$SERVER_IP:$l_port"
            echo "-------------------------------------------------------------"
            ((i++))
        fi
    done < "$DB_FILE"
    echo "============================================================="
}

# Функция удаления прокси
function delete_proxy() {
    local choice i d_user d_pass d_port index username port
    local users=()
    local ports=()
    echo "--- Удаление прокси ---"
    if [[ ! -s "$DB_FILE" ]]; then
        echo "Прокси пока не созданы."
        return
    fi

    # Сначала показываем нумерованный список
    echo "Выберите номер прокси для удаления:"
    i=1
    while IFS=":" read -r d_user d_pass d_port || [[ -n "$d_user" ]]; do
        d_user=$(echo "$d_user" | tr -d '\r' | xargs)
        d_port=$(echo "$d_port" | tr -d '\r' | xargs)
        
        if [[ -n "$d_user" && -n "$d_port" ]]; then
            echo "[$i] $d_user (Порт: $d_port)"
            users+=("$d_user")
            ports+=("$d_port")
            ((i++))
        fi
    done < "$DB_FILE"
    echo "[0] Отмена"
    
    read -p "Введите номер: " choice
    
    if [[ "$choice" == "0" ]]; then
        return
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$i" ]; then
        index=$((choice-1))
        username=${users[$index]}
        port=${ports[$index]}
        
        # Удаляем пользователя из системы
        userdel "$username"
        
        # Закрываем порт в ufw
        ufw delete allow "$port/tcp"
        
        # Удаляем из БД
        sed -i "/^$username:/d" "$DB_FILE"
        
        # Обновляем конфиг
        update_dante_config
        echo "Прокси #$choice ($username) удален успешно."
    else
        echo "Неверный номер."
    fi
}

# Функция удаления всего менеджера
function uninstall_manager() {
    local u_user u_pass u_port confirm
    read -p "Вы уверены, что хотите удалить всё? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        while IFS=":" read -r u_user u_pass u_port || [[ -n "$u_user" ]]; do
            u_user=$(echo "$u_user" | tr -d '\r' | xargs)
            u_port=$(echo "$u_port" | tr -d '\r' | xargs)
            if [[ -n "$u_user" ]]; then
                userdel "$u_user"
                ufw delete allow "$u_port/tcp"
            fi
        done < "$DB_FILE"
        
        apt purge -y dante-server
        rm -rf "$CONFIG_DIR"
        rm -f "$DANTE_CONF"
        rm -f "$DANTE_ALT_CONF"
        echo "SOCKS5 менеджер полностью удален."
        exit 0
    fi
}

# Функция проверки статуса
function check_status() {
    echo "--- Состояние системы ---"
    if systemctl is-active --quiet danted; then
        echo "[OK] Служба danted запущена"
    else
        echo "[FAIL] Служба danted ОСТАНОВЛЕНА"
        echo "--- Последние ошибки danted ---"
        journalctl -u danted -n 10 --no-pager
    fi
    
    if ufw status | grep -q "active"; then
        echo "[OK] Firewall (ufw) активен"
    else
        echo "[WARN] Firewall (ufw) выключен. Порты могут быть закрыты!"
    fi

    echo "--- Текущий конфиг ($DANTE_CONF) ---"
    if [[ -f "$DANTE_CONF" ]]; then
        cat "$DANTE_CONF"
    else
        echo "Файл конфигурации не найден!"
    fi
    
    echo "--- Открытые порты прокси (из БД) ---"
    local d_u d_p d_port
    while IFS=":" read -r d_u d_p d_port || [[ -n "$d_u" ]]; do
        d_port=$(echo "$d_port" | tr -d '\r' | xargs)
        if [[ -n "$d_port" ]]; then
            if ss -tulnp | grep -q ":$d_port"; then
                echo "Порт $d_port: СЛУШАЕТ"
            else
                echo "Порт $d_port: НЕ СЛУШАЕТ (Ошибка!)"
            fi
        fi
    done < "$DB_FILE"
}

# Главное меню
function main_menu() {
    install_requirements
    while :; do
        echo
        echo "===================================="
        echo "    SOCKS5 PROXY MANAGER"
        echo "===================================="
        echo "1. Добавить новый прокси"
        echo "2. Список прокси"
        echo "3. Удалить прокси"
        echo "4. Проверить состояние"
        echo "5. Удалить менеджер"
        echo "0. Выход"
        echo "===================================="
        read -p "Выберите действие: " choice
        
        case $choice in
            1) add_proxy ;;
            2) list_proxies ;;
            3) delete_proxy ;;
            4) check_status ;;
            5) uninstall_manager ;;
            0) exit 0 ;;
            *) echo "Неверный выбор." ;;
        esac
    done
}

# Проверка на root
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт должен быть запущен от имени root (sudo)." 
   exit 1
fi

main_menu
