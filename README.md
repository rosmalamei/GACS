# INSTALL GENIEACS OTOMATIS
This is autoinstall GenieACS 

# Usage

Install Genieacs Multitab Normal

```
apt install git curl -y
git clone https://github.com/rosmalamei/GACS
cd GACS
chmod +x *.sh
bash genieacs-arm1.sh
```

Baca terlebih dahulu !!!

#=== Script update GenieACS ====#

Config sebelumnya akan terhapus dan tergantikan oleh config baru

Jika anda memiliki config/script custom buatan anda sendiri,<br> 
Silahkan backup terlebih dahulu, kemudian setelah update lakukan config manual lagi sesuai config custom anda.<br>

Akses GenieACS

Web UI: http://localhost:3000
Username: admin
Password: admin (menu virtualparameter dll di sembunyikan)<br>
API: http://localhost:7557 <br>
CWMP (TR-069): http://your-server-ip:7547<br>

======= CARA RESTORE ========<br>
```
cd
```
```
sudo mongorestore --db=genieacs --drop genieacs-backup/genieacs
```
Selamat Mencoba
