GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

local_ip=$(hostname -I | awk '{print $1}')
server_hostname=$(hostname)
server_kernel=$(uname -r)
server_uptime=$(uptime -p 2>/dev/null || uptime)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

setup_mongodb_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        sudo apt-get update -y
        sudo apt-get install -y docker.io
    fi

    sudo systemctl enable --now docker >/dev/null 2>&1 || true
    sudo systemctl disable --now mongod >/dev/null 2>&1 || true

    if sudo docker ps -a --format '{{.Names}}' | grep -qx 'mongo-genieacs'; then
        sudo docker update --restart unless-stopped mongo-genieacs >/dev/null 2>&1 || true
        sudo docker start mongo-genieacs >/dev/null 2>&1 || true
    fi

    docker_mongo_tags=("4.4.18" "4.2.25")
    for tag in "${docker_mongo_tags[@]}"; do
        if ! sudo docker ps -a --format '{{.Names}}' | grep -qx 'mongo-genieacs'; then
            sudo docker pull "mongo:${tag}" >/dev/null
            sudo docker run -d \
                --name mongo-genieacs \
                --restart unless-stopped \
                -p 127.0.0.1:27017:27017 \
                -v /var/lib/mongo-genieacs:/data/db \
                "mongo:${tag}" >/dev/null
        fi

        for ((i = 1; i <= 40; i++)); do
            if command -v mongosh >/dev/null 2>&1; then
                mongosh "mongodb://127.0.0.1:27017/admin" --quiet --eval 'db.runCommand({ ping: 1 })' >/dev/null 2>&1 && return 0
            elif command -v mongo >/dev/null 2>&1; then
                mongo --host 127.0.0.1 --port 27017 --quiet --eval 'db.runCommand({ ping: 1 })' >/dev/null 2>&1 && return 0
            else
                return 0
            fi
            sleep 1
        done

        sudo docker logs --tail 120 mongo-genieacs >/dev/null 2>&1 || true
        sudo docker rm -f mongo-genieacs >/dev/null 2>&1 || true
    done

    sudo docker logs --tail 120 mongo-genieacs >/dev/null 2>&1 || true
    return 1
}

ensure_mongodb_running() {
    sudo systemctl enable --now mongod >/dev/null 2>&1 || true
    sudo systemctl restart mongod >/dev/null 2>&1 || true

    for ((i = 1; i <= 40; i++)); do
        if systemctl is-active --quiet mongod; then
            if command -v mongosh >/dev/null 2>&1; then
                mongosh "mongodb://127.0.0.1:27017/admin" --quiet --eval 'db.runCommand({ ping: 1 })' >/dev/null 2>&1 && return 0
            elif command -v mongo >/dev/null 2>&1; then
                mongo --host 127.0.0.1 --port 27017 --quiet --eval 'db.runCommand({ ping: 1 })' >/dev/null 2>&1 && return 0
            else
                return 0
            fi
        fi
        sleep 1
    done

    mongod_status="$(systemctl show -p ExecMainStatus --value mongod 2>/dev/null || true)"
    mongod_signal="$(systemctl show -p ExecMainSignal --value mongod 2>/dev/null || true)"
    if [ "$mongod_status" = "4" ] && { [ "$mongod_signal" = "ILL" ] || [ "$mongod_signal" = "SIGILL" ] || [ "$mongod_signal" = "4" ]; }; then
        echo -e "${RED}mongod crash (SIGILL). Mencoba MongoDB via Docker...${NC}"
        if setup_mongodb_docker; then
            return 0
        fi
    elif journalctl -u mongod --no-pager -n 50 2>/dev/null | grep -qE 'status=4/ILL|signal=ILL|SIGILL'; then
        echo -e "${RED}mongod crash (SIGILL). Mencoba MongoDB via Docker...${NC}"
        if setup_mongodb_docker; then
            return 0
        fi
    fi

    systemctl status mongod --no-pager -l || true
    journalctl -u mongod --no-pager -n 120 || true
    return 1
}

apply_darkmode_assets() {
    global_node_modules="$(npm root -g 2>/dev/null || true)"
    if [ -z "$global_node_modules" ]; then
        global_node_modules="/usr/lib/node_modules"
    fi
    installed_genieacs_dir="${global_node_modules%/}/GACS"
    if [ -d "${SCRIPT_DIR%/}/dpublic" ] && [ -d "$installed_genieacs_dir/public" ]; then
        backup_dir="${installed_genieacs_dir%/}/dpublic.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "${installed_genieacs_dir%/}/dpublic" "$backup_dir"
        cp -a "${SCRIPT_DIR%/}/dpublic/." "${installed_genieacs_dir%/}/public/"
        return 0
    fi
    echo -e "${RED}Folder public darkmode atau GenieACS terinstall tidak ditemukan. Skip copy darkmode.${NC}"
    return 1
}

#Install NodeJS
check_node_version() {
    if command -v node > /dev/null 2>&1; then
        NODE_VERSION=$(node -v | cut -d 'v' -f 2)
        NODE_MAJOR_VERSION=$(echo $NODE_VERSION | cut -d '.' -f 1)

        if [ "$NODE_MAJOR_VERSION" -lt 20 ] || [ "$NODE_MAJOR_VERSION" -gt 22 ]; then
            return 1
        else
            return 0
        fi
    else
        return 1
    fi
}

if ! check_node_version; then
    echo -e "${GREEN}================== Menginstall NodeJS ==================${NC}"
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -
    sudo apt-get install -y nodejs
    echo -e "${GREEN}================== Sukses NodeJS ==================${NC}"
else
    NODE_VERSION=$(node -v | cut -d 'v' -f 2)
    echo -e "${GREEN}============================================================================${NC}"
    echo -e "${GREEN}============== NodeJS sudah terinstall versi ${NODE_VERSION}. ==============${NC}"
    echo -e "${GREEN}========================= Lanjut install GenieACS ==========================${NC}"
fi

#MongoDB
echo "Cek MongoDB..."
if ensure_mongodb_running; then
    echo -e "${GREEN}============================================================================${NC}"
    echo -e "${GREEN}=================== MongoDB sudah ada & bisa diakses. ======================${NC}"
else
    echo -e "${GREEN}================== Menginstall MongoDB ==================${NC}"
    ubuntu_codename=""
    if [ -r /etc/os-release ]; then
        ubuntu_codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}")"
    fi
    if [ -z "$ubuntu_codename" ] && command -v lsb_release >/dev/null 2>&1; then
        ubuntu_codename="$(lsb_release -sc)"
    fi

    mongodb_major="4.4"
    if [ "$ubuntu_codename" = "jammy" ] || [ "$ubuntu_codename" = "noble" ]; then
        mongodb_major="8.0"
    fi

    sudo apt-get update -y
    sudo apt-get install -y gnupg curl
    sudo install -d -m 0755 /usr/share/keyrings
    curl -fsSL "https://www.mongodb.org/static/pgp/server-${mongodb_major}.asc" | sudo gpg --dearmor --batch --yes --output "/usr/share/keyrings/mongodb-server-${mongodb_major}.gpg"
    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-${mongodb_major}.gpg ] https://repo.mongodb.org/apt/ubuntu ${ubuntu_codename:-focal}/mongodb-org/${mongodb_major} multiverse" | sudo tee "/etc/apt/sources.list.d/mongodb-org-${mongodb_major}.list" > /dev/null
    sudo apt-get update -y
    sudo apt-get install -y mongodb-org
    if ensure_mongodb_running; then
        echo -e "${GREEN}================== Sukses MongoDB ==================${NC}"
    else
        echo -e "${RED}MongoDB gagal jalan. Pastikan arsitektur OS support, lalu cek log mongod di atas.${NC}"
        exit 1
    fi
fi

#GenieACS
if !  systemctl is-active --quiet genieacs-{cwmp,fs,ui,nbi}; then
    echo -e "${GREEN}================== Menginstall genieACS CWMP, FS, NBI, UI ==================${NC}"
    cd
    cd /opt
    git clone https://github.com/rosmalamei/genieacs.git
    cd genieacs
    npm install
    npm run build
    useradd --system --no-create-home --user-group genieacs   
    mkdir -p /opt/genieacs/ext     
    chown genieacs:genieacs /opt/genieacs/ext
#Isi data Genieacs.env    
    cat << EOF > /opt/genieacs/genieacs.env
GENIEACS_CWMP_ACCESS_LOG_FILE=/var/log/genieacs/genieacs-cwmp-access.log
GENIEACS_NBI_ACCESS_LOG_FILE=/var/log/genieacs/genieacs-nbi-access.log
GENIEACS_FS_ACCESS_LOG_FILE=/var/log/genieacs/genieacs-fs-access.log
GENIEACS_UI_ACCESS_LOG_FILE=/var/log/genieacs/genieacs-ui-access.log
GENIEACS_DEBUG_FILE=/var/log/genieacs/genieacs-debug.yaml
NODE_OPTIONS=--enable-source-maps
GENIEACS_EXT_DIR=/opt/genieacs/ext
EOF
    node -e "console.log(\"GENIEACS_UI_JWT_SECRET=\" + require('crypto').randomBytes(128).toString('hex'))" >> /opt/genieacs/genieacs.env
    sudo chown genieacs:genieacs /opt/genieacs/genieacs.env
    sudo chmod 600 /opt/genieacs/genieacs.env
    mkdir -p /var/log/genieacs
    chown genieacs:genieacs /var/log/genieacs
    # create systemd unit files
## CWMP
    cat << EOF > /etc/systemd/system/genieacs-cwmp.service
[Unit]
Description=GenieACS CWMP
After=network.target

[Service]
User=genieacs
EnvironmentFile=/opt/genieacs/genieacs.env
ExecStart=/opt/genieacs/dist/bin/genieacs-cwmp

[Install]
WantedBy=default.target
EOF

## NBI
    cat << EOF > /etc/systemd/system/genieacs-nbi.service
[Unit]
Description=GenieACS NBI
After=network.target
 
[Service]
User=genieacs
EnvironmentFile=/opt/genieacs/genieacs.env
ExecStart=/opt/genieacs/dist/bin/genieacs-nbi
 
[Install]
WantedBy=default.target
EOF

## FS
    cat << EOF > /etc/systemd/system/genieacs-fs.service
[Unit]
Description=GenieACS FS
After=network.target
 
[Service]
User=genieacs
EnvironmentFile=/opt/genieacs/genieacs.env
ExecStart=/opt/genieacs/dist/bin/genieacs-fs
 
[Install]
WantedBy=default.target
EOF

## UI
    cat << EOF > /etc/systemd/system/genieacs-ui.service
[Unit]
Description=GenieACS UI
After=network.target
 
[Service]
User=genieacs
EnvironmentFile=/opt/genieacs/genieacs.env
ExecStart=/opt/genieacs/dist/bin/genieacs-ui
 
[Install]
WantedBy=default.target
EOF

# config logrotate
  cat << EOF > /etc/logrotate.d/genieacs
/var/log/genieacs/*.log /var/log/genieacs/*.yaml {
    daily
    rotate 30
    compress
    delaycompress
    dateext
}
EOF
    echo -e "${GREEN}========== Install APP GenieACS selesai... ==============${NC}"
    systemctl daemon-reload
    systemctl enable --now genieacs-{cwmp,fs,ui,nbi}
    systemctl start genieacs-{cwmp,fs,ui,nbi}    
    echo -e "${GREEN}================== Sukses genieACS CWMP, FS, NBI, UI ==================${NC}"
    
    
else
    echo -e "${GREEN}============================================================================${NC}"
    echo -e "${GREEN}=================== GenieACS sudah terinstall sebelumnya. ==================${NC}"
fi

#Sukses
echo -e "${GREEN}============================================================================${NC}"
echo -e "${GREEN}========== GenieACS UI akses port 3000. : http://$local_ip:3000 ============${NC}"
echo -e "${GREEN}============================================================================${NC}"
echo -e "${GREEN}Sekarang install parameter. Apakah anda ingin melanjutkan? (y/n)${NC}"
read confirmation

if [ "$confirmation" != "y" ]; then
    echo -e "${GREEN}Install dibatalkan..${NC}"
    
    exit 1
fi
for ((i = 5; i >= 1; i--)); do
    sleep 1
    echo "Lanjut Install Parameter $i. Tekan ctrl+c untuk membatalkan"
done

if ! ensure_mongodb_running; then
    echo -e "${RED}MongoDB tidak bisa diakses. Install parameter dibatalkan.${NC}"
    exit 1
fi
systemctl stop --now genieacs-{cwmp,fs,ui,nbi} >/dev/null 2>&1 || true
if [ ! -d "${SCRIPT_DIR%/}/db" ]; then
    echo -e "${RED}Folder 'db' tidak ditemukan. Pastikan folder db ada di ${SCRIPT_DIR}.${NC}"
    exit 1
fi
sudo mongodump --host 127.0.0.1 --port 27017 --db=genieacs --out "${SCRIPT_DIR%/}/genieacs-backup" || true
db_dir="${SCRIPT_DIR%/}/db"
echo -e "${GREEN}Restore DB GenieACS (termasuk config/custom) ...${NC}"
if [ -d "${db_dir%/}/genieacs" ]; then
    if ! mongorestore --host 127.0.0.1 --port 27017 --drop "$db_dir"; then
        echo -e "${RED}Restore DB gagal. Cek error mongorestore di atas.${NC}"
        exit 1
    fi
else
    shopt -s nullglob
    bson_files=("${db_dir%/}"/*.bson)
    shopt -u nullglob
    if [ "${#bson_files[@]}" -eq 0 ]; then
        echo -e "${RED}Tidak ada file .bson di ${db_dir}. Restore dibatalkan.${NC}"
        exit 1
    fi
    for bson_path in "${bson_files[@]}"; do
        collection="$(basename "$bson_path" .bson)"
        if ! mongorestore --host 127.0.0.1 --port 27017 --drop --db=genieacs --collection="$collection" "$bson_path"; then
            echo -e "${RED}Restore koleksi ${collection} gagal. Cek error mongorestore di atas.${NC}"
            exit 1
        fi
    done
fi
apply_darkmode_assets || true
systemctl start --now genieacs-{cwmp,fs,ui,nbi} >/dev/null 2>&1 || true
echo -e "${GREEN}============================================================================${NC}"
echo -e "${GREEN}=================== VIRTUAL PARAMETER BERHASIL DI INSTALL. =================${NC}"
echo -e "${GREEN}===Jika ACS URL berbeda, silahkan edit di Admin >> Provosions >> inform ====${NC}"
echo -e "${GREEN}========== GenieACS UI akses port 3000. : http://$local_ip:3000 ============${NC}"
echo -e "${GREEN}============================================================================${NC}"

echo -e "${GREEN}Selesai. Apakah ingin reboot server sekarang? (y/n)${NC}"
read reboot_confirmation
if [ "$reboot_confirmation" = "y" ]; then
    echo -e "${GREEN}Reboot...${NC}"
    if command -v sudo >/dev/null 2>&1; then
        sudo reboot
    else
        reboot
    fi
fi
