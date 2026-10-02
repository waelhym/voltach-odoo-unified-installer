# Installation Guide

## 1. Prepare the server

Login through SSH as a user with sudo privileges.

```bash
sudo -i
apt update
```

## 2. Get the project

```bash
git clone https://github.com/waelhym/voltach-odoo-unified-installer.git
cd voltach-odoo-unified-installer
```

## 3. Run

```bash
chmod +x install.sh
sudo ./install.sh
```

Follow the interactive prompts to select the Odoo version, instance name and passwords.

## 4. Create additional Odoo instances

Run the installer again. Existing instances are kept and a new isolated instance can be created with a different name and ports.

## 5. Management CLI

```bash
voltach-odoo list
voltach-odoo logs INSTANCE_NAME
voltach-odoo restart INSTANCE_NAME
voltach-odoo backup INSTANCE_NAME
```

## Production checklist

- Point your domain/subdomain to the server.
- Configure the Odoo host in Nginx Proxy Manager.
- Enable SSL/TLS.
- Restrict management ports with a firewall/VPN where possible.
- Schedule backups and test restoration.
- Do not commit generated secrets, database dumps or Odoo filestore data to GitHub.
