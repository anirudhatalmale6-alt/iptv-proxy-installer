#!/bin/bash
# IPTV Encrypted Proxy Installer
# Installs nginx + Flask proxy with encrypted URLs, HTTPS, and web admin panel
# Usage: ./install-proxy.sh <domain> <upstream_url>
# Example: ./install-proxy.sh gama.445566.org http://cc.efridol.com:80

set -e

if [ $# -lt 2 ]; then
    echo "Usage: $0 <domain> <upstream_url>"
    echo "Example: $0 gama.445566.org http://cc.efridol.com:80"
    echo ""
    echo "  domain: Your domain pointing to this server (A record must exist)"
    echo "  upstream_url: The IPTV panel URL (e.g. http://cc.efridol.com:80)"
    exit 1
fi

DOMAIN="$1"
UPSTREAM="$2"
ADMIN_PASS="proxy$(date +%Y)!"
ENC_KEY=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
APP_DIR="/opt/iptv-proxy"

echo "========================================="
echo "  IPTV Encrypted Proxy Installer"
echo "========================================="
echo "Domain: $DOMAIN"
echo "Upstream: $UPSTREAM"
echo "Admin: admin / $ADMIN_PASS"
echo "========================================="
echo ""

# Extract upstream host for nginx config
UPSTREAM_HOST=$(echo "$UPSTREAM" | sed 's|http://||;s|:.*||')
UPSTREAM_PORT=$(echo "$UPSTREAM" | grep -oP ':\K[0-9]+' || echo "80")

echo "[1/6] Installing packages..."
apt-get update -qq
apt-get install -y -qq nginx python3 python3-pip python3-venv certbot python3-certbot-nginx > /dev/null 2>&1
pip3 install flask requests > /dev/null 2>&1

echo "[2/6] Setting up Flask proxy app..."
mkdir -p $APP_DIR/templates

cat > $APP_DIR/app.py << 'APPEOF'
from flask import Flask, render_template, request, redirect, url_for, session, Response, jsonify
import hashlib
import hmac
import base64
import json
import os
import requests
import functools
import time
import re
from urllib.parse import urlparse

app = Flask(__name__)
app.secret_key = os.urandom(32).hex()

ADMIN_USER = 'admin'
ADMIN_PASS = os.environ.get('PROXY_ADMIN_PASS', 'proxy2026!')
UPSTREAM = os.environ.get('PROXY_UPSTREAM', 'http://cc.efridol.com:80')
LINKS_FILE = '/opt/iptv-proxy/links.json'
ENC_KEY = os.environ.get('PROXY_ENC_KEY', 'Pr0xyK3y!IPTV2026SecureStream!!').encode('utf-8')

def encrypt_path(path):
    data = path.encode('utf-8')
    key_len = len(ENC_KEY)
    encrypted = bytes([data[i] ^ ENC_KEY[i % key_len] for i in range(len(data))])
    return base64.urlsafe_b64encode(encrypted).decode('utf-8').rstrip('=')

def decrypt_path(token):
    padding = 4 - len(token) % 4
    if padding != 4:
        token += '=' * padding
    try:
        encrypted = base64.urlsafe_b64decode(token)
        key_len = len(ENC_KEY)
        decrypted = bytes([encrypted[i] ^ ENC_KEY[i % key_len] for i in range(len(encrypted))])
        return decrypted.decode('utf-8')
    except:
        return None

def load_links():
    try:
        with open(LINKS_FILE, 'r') as f:
            return json.load(f)
    except:
        return []

def save_links(links):
    with open(LINKS_FILE, 'w') as f:
        json.dump(links, f, indent=2)

def login_required(f):
    @functools.wraps(f)
    def decorated(*args, **kwargs):
        if not session.get('logged_in'):
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated

@app.route('/admin/login', methods=['GET', 'POST'])
def login():
    error = None
    if request.method == 'POST':
        if request.form.get('username') == ADMIN_USER and request.form.get('password') == ADMIN_PASS:
            session['logged_in'] = True
            return redirect(url_for('dashboard'))
        error = 'Invalid credentials'
    return render_template('login.html', error=error)

@app.route('/admin/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))

@app.route('/admin')
@login_required
def dashboard():
    links = load_links()
    return render_template('dashboard.html', links=links, host=request.host)

@app.route('/admin/add', methods=['POST'])
@login_required
def add_link():
    name = request.form.get('name', '').strip()
    original_url = request.form.get('original_url', '').strip()
    if name and original_url:
        if '://' in original_url:
            parsed = urlparse(original_url)
            path = parsed.path
            if parsed.query:
                path += '?' + parsed.query
        else:
            path = original_url if original_url.startswith('/') else '/' + original_url

        token = encrypt_path(path)
        links = load_links()
        links.append({
            'name': name,
            'original': path,
            'token': token,
            'created': time.strftime('%Y-%m-%d %H:%M'),
            'active': True
        })
        save_links(links)
    return redirect(url_for('dashboard'))

@app.route('/admin/delete/<int:idx>')
@login_required
def delete_link(idx):
    links = load_links()
    if 0 <= idx < len(links):
        links.pop(idx)
        save_links(links)
    return redirect(url_for('dashboard'))

@app.route('/admin/toggle/<int:idx>')
@login_required
def toggle_link(idx):
    links = load_links()
    if 0 <= idx < len(links):
        links[idx]['active'] = not links[idx].get('active', True)
        save_links(links)
    return redirect(url_for('dashboard'))

@app.route('/admin/generate_m3u', methods=['POST'])
@login_required
def generate_m3u():
    username = request.form.get('username', '').strip()
    password = request.form.get('password', '').strip()
    output = request.form.get('output', 'mpegts')
    if not username or not password:
        return redirect(url_for('dashboard'))

    path = f'/get.php?username={username}&password={password}&type=m3u&output={output}'
    token = encrypt_path(path)

    links = load_links()
    existing = [l for l in links if l.get('original') == path]
    if not existing:
        links.append({
            'name': f'M3U Playlist - {username}',
            'original': path,
            'token': token,
            'created': time.strftime('%Y-%m-%d %H:%M'),
            'active': True
        })
        save_links(links)

    return redirect(url_for('dashboard'))

def is_m3u_request(path, content_type=''):
    return ('get.php' in path and 'type=m3u' in path) or \
           'mpegurl' in content_type.lower() or \
           'audio/x-mpegurl' in content_type.lower()

def rewrite_m3u_content(content, scheme, host):
    upstream_host = UPSTREAM.replace('http://', '').replace('https://', '').split(':')[0]
    lines = content.split('\n')
    new_lines = []
    for line in lines:
        line = line.strip()
        if line.startswith('#EXTINF'):
            line = re.sub(
                r'http://' + re.escape(upstream_host) + r'(?::\d+)?/[^\s"]*',
                lambda m: f'{scheme}://{host}/img/{encrypt_path(urlparse(m.group(0)).path)}',
                line
            )
            new_lines.append(line)
        elif line.startswith(f'http://{upstream_host}/') or line.startswith(f'http://{upstream_host}:'):
            parsed = urlparse(line)
            path = parsed.path
            if parsed.query:
                path += '?' + parsed.query
            token = encrypt_path(path)
            new_lines.append(f'{scheme}://{host}/view/{token}')
        elif line.startswith('http://') and upstream_host in line:
            parsed = urlparse(line)
            path = parsed.path
            if parsed.query:
                path += '?' + parsed.query
            token = encrypt_path(path)
            new_lines.append(f'{scheme}://{host}/view/{token}')
        else:
            new_lines.append(line)
    return '\n'.join(new_lines)

@app.route('/view/<token>')
def stream_view(token):
    path = decrypt_path(token)
    if not path:
        return 'Invalid link', 404

    upstream_url = UPSTREAM + path
    try:
        if is_m3u_request(path):
            resp = requests.get(upstream_url, timeout=15, allow_redirects=True)
            scheme = 'https' if request.is_secure or request.headers.get('X-Forwarded-Proto') == 'https' else 'http'
            host = request.host
            rewritten = rewrite_m3u_content(resp.text, scheme, host)
            return Response(rewritten, status=resp.status_code,
                            content_type='audio/x-mpegurl')

        resp = requests.get(upstream_url, stream=True, timeout=10, allow_redirects=True)
        content_type = resp.headers.get('Content-Type', '')

        if is_m3u_request(path, content_type):
            body = resp.content.decode('utf-8', errors='replace')
            scheme = 'https' if request.is_secure or request.headers.get('X-Forwarded-Proto') == 'https' else 'http'
            host = request.host
            rewritten = rewrite_m3u_content(body, scheme, host)
            return Response(rewritten, status=resp.status_code,
                            content_type='audio/x-mpegurl')

        headers = {}
        if content_type:
            headers['Content-Type'] = content_type

        def generate():
            for chunk in resp.iter_content(chunk_size=65536):
                if chunk:
                    yield chunk

        return Response(generate(), status=resp.status_code, headers=headers)
    except Exception as e:
        return f'Stream error', 502

@app.route('/img/<token>')
def img_proxy(token):
    path = decrypt_path(token)
    if not path:
        return 'Not found', 404
    upstream_url = UPSTREAM.replace(':80', ':8080') + path
    try:
        resp = requests.get(upstream_url, timeout=10, allow_redirects=True)
        return Response(resp.content, status=resp.status_code,
                        content_type=resp.headers.get('Content-Type', 'image/jpeg'))
    except:
        return 'Not found', 404

if __name__ == '__main__':
    if not os.path.exists(LINKS_FILE):
        save_links([])
    app.run(host='127.0.0.1', port=9090, debug=False, threaded=True)
APPEOF

cat > $APP_DIR/templates/login.html << 'LOGINEOF'
<!DOCTYPE html>
<html>
<head>
<title>Proxy Manager - Login</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:Arial,sans-serif;background:#0f0f23;display:flex;justify-content:center;align-items:center;min-height:100vh;color:#eee}
.box{background:#1a1a3e;padding:40px;border-radius:12px;width:360px;box-shadow:0 8px 32px rgba(0,0,0,.4)}
h1{text-align:center;margin-bottom:30px;color:#00d4ff;font-size:22px}
input{width:100%;padding:12px 16px;margin:8px 0;border:1px solid #333;border-radius:8px;background:#12122a;color:#eee;font-size:15px}
input:focus{outline:none;border-color:#00d4ff}
button{width:100%;padding:14px;margin-top:16px;background:#00d4ff;color:#000;border:none;border-radius:8px;font-size:16px;cursor:pointer;font-weight:bold}
button:hover{background:#00b8d9}
.error{color:#ff6b6b;text-align:center;margin-top:10px;font-size:14px}
</style>
</head>
<body>
<div class="box">
<h1>IPTV Proxy Manager</h1>
<form method="post">
<input type="text" name="username" placeholder="Username" required>
<input type="password" name="password" placeholder="Password" required>
<button type="submit">Login</button>
</form>
{% if error %}<p class="error">{{ error }}</p>{% endif %}
</div>
</body>
</html>
LOGINEOF

cat > $APP_DIR/templates/dashboard.html << 'DASHEOF'
<!DOCTYPE html>
<html>
<head>
<title>IPTV Proxy Manager</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:Arial,sans-serif;background:#0f0f23;color:#eee;padding:20px}
.header{display:flex;justify-content:space-between;align-items:center;margin-bottom:24px;padding-bottom:16px;border-bottom:1px solid #333}
.header h1{color:#00d4ff;font-size:22px}
.header a{color:#aaa;text-decoration:none;font-size:14px}
.header a:hover{color:#00d4ff}
.section{background:#1a1a3e;border-radius:10px;padding:20px;margin-bottom:20px}
.section h2{color:#00d4ff;margin-bottom:16px;font-size:17px}
.form-row{display:flex;gap:10px;flex-wrap:wrap;align-items:end}
.form-group{flex:1;min-width:200px}
.form-group label{display:block;font-size:13px;color:#aaa;margin-bottom:4px}
.form-group input,.form-group select{width:100%;padding:10px;background:#12122a;border:1px solid #333;border-radius:6px;color:#eee;font-size:14px}
.form-group input:focus{outline:none;border-color:#00d4ff}
.btn{padding:10px 20px;border:none;border-radius:6px;cursor:pointer;font-size:14px;font-weight:bold;white-space:nowrap}
.btn-add{background:#00d4ff;color:#000}
.btn-add:hover{background:#00b8d9}
.btn-del{background:#ff4444;color:#fff;font-size:12px;padding:6px 12px}
.btn-del:hover{background:#cc3333}
.btn-gen{background:#4caf50;color:#fff}
.btn-gen:hover{background:#388e3c}
.btn-toggle{background:#ff9800;color:#fff;font-size:12px;padding:6px 12px}
table{width:100%;border-collapse:collapse;margin-top:12px;font-size:13px}
th{text-align:left;padding:10px;color:#00d4ff;border-bottom:1px solid #333}
td{padding:10px;border-bottom:1px solid #1f1f3f;word-break:break-all}
.url{font-family:monospace;font-size:12px;color:#8be9fd;cursor:pointer}
.url:hover{color:#fff}
.active{color:#4caf50}
.inactive{color:#ff4444}
.copy-btn{background:#333;color:#eee;border:none;padding:4px 8px;border-radius:4px;cursor:pointer;font-size:11px;margin-left:6px}
.copy-btn:hover{background:#555}
.info{color:#aaa;font-size:13px;margin-top:8px}
</style>
<script>
function copyUrl(text){navigator.clipboard.writeText(text);alert('Copied!')}
</script>
</head>
<body>
<div class="header">
<h1>IPTV Proxy Manager</h1>
<a href="/admin/logout">Logout</a>
</div>

<div class="section">
<h2>Add Encrypted Link</h2>
<form method="post" action="/admin/add">
<div class="form-row">
<div class="form-group">
<label>Name</label>
<input type="text" name="name" placeholder="e.g. Top Channel HD" required>
</div>
<div class="form-group">
<label>Original URL or Path</label>
<input type="text" name="original_url" placeholder="e.g. /test123/123hhjmnsdkjsdj/2 or full URL" required>
</div>
<button type="submit" class="btn btn-add">Add Link</button>
</div>
</form>
</div>

<div class="section">
<h2>Generate Encrypted M3U Playlist</h2>
<form method="post" action="/admin/generate_m3u">
<div class="form-row">
<div class="form-group">
<label>Username</label>
<input type="text" name="username" placeholder="IPTV username" required>
</div>
<div class="form-group">
<label>Password</label>
<input type="text" name="password" placeholder="IPTV password" required>
</div>
<div class="form-group">
<label>Output</label>
<select name="output">
<option value="mpegts">MPEG-TS</option>
<option value="m3u8">HLS (m3u8)</option>
</select>
</div>
<button type="submit" class="btn btn-gen">Generate</button>
</div>
</form>
<p class="info">Generates encrypted M3U link - appears in list below</p>
</div>

<div class="section">
<h2>Encrypted Links ({{ links|length }})</h2>
<table>
<tr><th>Name</th><th>Encrypted URL</th><th>Status</th><th>Created</th><th>Actions</th></tr>
{% for link in links %}
<tr>
<td>{{ link.name }}</td>
<td>
<span class="url" onclick="copyUrl('https://{{ host }}/view/{{ link.token }}')">https://{{ host }}/view/{{ link.token[:40] }}...</span>
<button class="copy-btn" onclick="copyUrl('https://{{ host }}/view/{{ link.token }}')">Copy</button>
</td>
<td><span class="{% if link.active %}active{% else %}inactive{% endif %}">{{ 'Active' if link.active else 'Disabled' }}</span></td>
<td>{{ link.created }}</td>
<td>
<a href="/admin/toggle/{{ loop.index0 }}" class="btn btn-toggle">Toggle</a>
<a href="/admin/delete/{{ loop.index0 }}" class="btn btn-del" onclick="return confirm('Delete?')">Delete</a>
</td>
</tr>
{% endfor %}
{% if not links %}
<tr><td colspan="5" style="color:#666;text-align:center">No links added yet</td></tr>
{% endif %}
</table>
</div>
</body>
</html>
DASHEOF

echo "[]" > $APP_DIR/links.json

# Set environment variables in app
sed -i "s|os.environ.get('PROXY_ADMIN_PASS', 'proxy2026!')|'$ADMIN_PASS'|" $APP_DIR/app.py
sed -i "s|os.environ.get('PROXY_UPSTREAM', 'http://cc.efridol.com:80')|'$UPSTREAM'|" $APP_DIR/app.py
sed -i "s|os.environ.get('PROXY_ENC_KEY', 'Pr0xyK3y!IPTV2026SecureStream!!')|'$ENC_KEY'|" $APP_DIR/app.py

echo "[3/6] Creating systemd service..."
cat > /etc/systemd/system/iptv-proxy.service << EOF
[Unit]
Description=IPTV Encrypted Proxy
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/python3 $APP_DIR/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable iptv-proxy
systemctl start iptv-proxy

echo "[4/6] Configuring nginx..."
cat > /etc/nginx/sites-available/iptv-proxy << NGINXEOF
server {
    listen 80;
    server_name $DOMAIN;
    resolver 1.1.1.1 8.8.8.8 valid=30s;

    proxy_connect_timeout 10s;
    proxy_send_timeout 600s;
    proxy_read_timeout 600s;
    send_timeout 600s;
    proxy_buffering off;
    proxy_request_buffering off;

    location /admin {
        proxy_pass http://127.0.0.1:9090;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location /view/ {
        proxy_pass http://127.0.0.1:9090;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }

    location /img/ {
        proxy_pass http://127.0.0.1:9090;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /get.php {
        proxy_pass $UPSTREAM;
        proxy_set_header Host $UPSTREAM_HOST;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Accept-Encoding "";
        sub_filter 'http://$UPSTREAM_HOST' 'http://\$host';
        sub_filter '$UPSTREAM_HOST' '\$host';
        sub_filter_once off;
        sub_filter_types text/plain application/x-mpegURL application/octet-stream *;
    }

    location /player_api.php {
        proxy_pass $UPSTREAM;
        proxy_set_header Host $UPSTREAM_HOST;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Accept-Encoding "";
        sub_filter 'http://$UPSTREAM_HOST' 'http://\$host';
        sub_filter '$UPSTREAM_HOST' '\$host';
        sub_filter_once off;
        sub_filter_types application/json text/plain text/html *;
    }

    location /panel_api.php {
        proxy_pass $UPSTREAM;
        proxy_set_header Host $UPSTREAM_HOST;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Accept-Encoding "";
        sub_filter 'http://$UPSTREAM_HOST' 'http://\$host';
        sub_filter '$UPSTREAM_HOST' '\$host';
        sub_filter_once off;
        sub_filter_types application/json text/plain text/html *;
    }

    location /xmltv.php {
        proxy_pass $UPSTREAM;
        proxy_set_header Host $UPSTREAM_HOST;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location / {
        proxy_pass $UPSTREAM;
        proxy_set_header Host $UPSTREAM_HOST;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_intercept_errors on;
        error_page 301 302 307 = @handle_redirect;
    }

    location @handle_redirect {
        set \$redirect_url \$upstream_http_location;
        proxy_pass \$redirect_url;
        proxy_buffering off;
        proxy_connect_timeout 10s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
    }

    access_log /var/log/nginx/iptv-proxy.log;
    error_log /var/log/nginx/iptv-proxy-error.log;
}
NGINXEOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/iptv-proxy /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

echo "[5/6] Getting SSL certificate..."
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect

# After certbot, update sub_filter for HTTPS
sed -i "s|sub_filter 'http://$UPSTREAM_HOST' 'http://|sub_filter 'http://$UPSTREAM_HOST' 'https://|g" /etc/nginx/sites-available/iptv-proxy

# Add port and protocol rewriting for player_api
sed -i "/location \/player_api.php/,/}/ s|sub_filter_once off;|sub_filter_once off;\n        sub_filter '\"port\":\"$UPSTREAM_PORT\"' '\"port\":\"443\"';\n        sub_filter '\"server_protocol\":\"http\"' '\"server_protocol\":\"https\"';|" /etc/nginx/sites-available/iptv-proxy
sed -i "/location \/panel_api.php/,/}/ s|sub_filter_once off;|sub_filter_once off;\n        sub_filter '\"port\":\"$UPSTREAM_PORT\"' '\"port\":\"443\"';\n        sub_filter '\"server_protocol\":\"http\"' '\"server_protocol\":\"https\"';|" /etc/nginx/sites-available/iptv-proxy

nginx -t && systemctl reload nginx

echo "[6/6] Verifying..."
sleep 2
if systemctl is-active --quiet iptv-proxy && systemctl is-active --quiet nginx; then
    echo ""
    echo "========================================="
    echo "  INSTALLATION COMPLETE!"
    echo "========================================="
    echo ""
    echo "Admin Panel: https://$DOMAIN/admin/login"
    echo "Login: admin / $ADMIN_PASS"
    echo ""
    echo "For ibo player / Smart IPTV (Xtream API):"
    echo "  Server: $DOMAIN"
    echo "  Port: 443"
    echo "  Username/Password: same as panel"
    echo ""
    echo "Encrypted M3U: generate from admin panel"
    echo "========================================="
else
    echo "ERROR: Something went wrong. Check:"
    echo "  systemctl status iptv-proxy"
    echo "  systemctl status nginx"
    exit 1
fi
