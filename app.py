from flask import Flask, render_template, request, redirect, url_for, session, Response, jsonify
import hashlib
import hmac
import base64
import json
import os
import requests
import functools
import time

app = Flask(__name__)
app.secret_key = os.urandom(32).hex()

ADMIN_USER = 'admin'
ADMIN_PASS = 'proxy2026!'
UPSTREAM = 'http://cc.efridol.com:80'
LINKS_FILE = '/opt/iptv-proxy/links.json'

# Encryption key (32 bytes for AES-like encryption via XOR + shuffle)
ENC_KEY = b'Pr0xyK3y!IPTV2026SecureStream!!'

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
        # Extract path from full URL or use as-is
        if '://' in original_url:
            from urllib.parse import urlparse
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
    import re
    from urllib.parse import urlparse
    lines = content.split('\n')
    new_lines = []
    for line in lines:
        line = line.strip()
        if line.startswith('#EXTINF'):
            line = re.sub(
                r'http://cc\.efridol\.com(?::\d+)?/[^\s"]*',
                lambda m: f'{scheme}://{host}/img/{encrypt_path(urlparse(m.group(0)).path)}',
                line
            )
            new_lines.append(line)
        elif line.startswith('http://cc.efridol.com/') or line.startswith('http://cc.efridol.com:'):
            parsed = urlparse(line)
            path = parsed.path
            if parsed.query:
                path += '?' + parsed.query
            token = encrypt_path(path)
            new_lines.append(f'{scheme}://{host}/view/{token}')
        elif line.startswith('http://') and 'efridol' in line:
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
