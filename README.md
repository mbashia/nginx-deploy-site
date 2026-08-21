# nginx-vhost-cert

A small bash script that automates the boring, error-prone part of standing up
a new site behind nginx: writing the reverse-proxy vhost config, enabling it,
and provisioning a free Let's Encrypt TLS certificate with certbot.

Point it at a backend app (anything listening on `127.0.0.1:<port>` — Node,
Phoenix/Elixir, Django, Rails, whatever) and one or more domains, and it does
the rest.

## What it does

1. Validates your inputs (root check, port range, required binaries present)
2. Refuses to overwrite an existing config — you won't accidentally nuke a
   working site
3. Checks that each domain actually resolves in DNS before touching nginx,
   and warns you if not (this is the #1 cause of failed certbot runs)
4. Writes a clean nginx server block with sane default proxy headers
   (WebSocket upgrade support included)
5. Symlinks it into `sites-enabled`
6. Runs `nginx -t` — if the config is invalid, it automatically rolls back
   the symlink and config file so you're never left with a broken enabled
   site
7. Reloads nginx
8. Runs `certbot --nginx` to issue and install the certificate

## Requirements

- Ubuntu/Debian-style server with `nginx` installed
- `certbot` installed with the nginx plugin (`sudo apt install certbot python3-certbot-nginx`)
- Root access
- DNS A/AAAA records already pointed at your server (the script checks this
  and will ask for confirmation if a record is missing, but won't create DNS
  records for you)

## Usage

```bash
chmod +x domain-script.sh

sudo ./domain-script.sh -u <upstream_name> -p <port> -d <domain> [-d <domain2> ...]
```

| Flag | Description |
|------|-------------|
| `-u` | Upstream name — an internal identifier nginx uses for the backend pool |
| `-p` | Port your app listens on locally (e.g. `4000`, `2300`) |
| `-d` | A domain to serve. Repeatable. **The first `-d` is treated as the primary domain** and is used as the config filename and certbot cert name |
| `-h` | Show usage |

### Example

Standing up `app.example.com` (with `www`) for a backend running on
port `4000`:

```bash
sudo ./domain-script.sh -u myapp -p 4000 \
  -d app.example.com \
  -d www.app.example.com
```

This creates `/etc/nginx/sites-available/app.example.com`,
symlinks it into `sites-enabled`, reloads nginx, and requests a cert covering
both domains.

### Single-domain example

```bash
sudo ./domain-script.sh -u blog -p 8080 -d blog.example.com
```

## What the generated config looks like

```nginx
upstream myapp {
    server 127.0.0.1:4000;
}

server {
    listen 80;
    listen [::]:80;
    server_name app.example.com www.app.example.com;

    location / {
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Host $http_host;
        proxy_set_header X-Cluster-Client-Ip $remote_addr;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_pass http://myapp;
    }
}
```

`certbot --nginx` then edits this file in place to add the `listen 443 ssl`
block and certificate paths.

## Removing a site

The script only adds sites; removal is a manual (and safer) step:

```bash
sudo rm /etc/nginx/sites-enabled/<domain>
sudo nginx -t && sudo systemctl reload nginx
# optionally also remove the cert:
sudo certbot delete --cert-name <domain>
# and the config itself, once you're sure:
sudo rm /etc/nginx/sites-available/<domain>
```

## Renewals

Certbot's systemd timer / cron job (installed automatically with certbot)
handles renewals for all certificates on the box, including ones issued by
this script. Verify it's working with:

```bash
sudo certbot renew --dry-run
```

## Troubleshooting

**`nginx: [warn] conflicting server name "..." ... ignored`**
This means another enabled site already declares the same `server_name`.
Search for it across all enabled configs:

```bash
grep -rin "yourdomain.com" /etc/nginx/sites-enabled/
nginx -T | grep -B3 -A3 "server_name.*yourdomain"
```

If it only ever appears once and the warning still fires specifically during
a `certbot --nginx` run (not during a plain `nginx -t`), certbot's nginx
plugin may be misparsing the file. Work around it with the webroot method
instead:

```bash
sudo mkdir -p /var/www/certbot
# add this location block inside your existing port-80 server block:
#   location /.well-known/acme-challenge/ { root /var/www/certbot; }
sudo nginx -t && sudo systemctl reload nginx
sudo certbot certonly --webroot -w /var/www/certbot -d yourdomain.com -d www.yourdomain.com
```

Then manually add the `listen 443 ssl` block pointing at the resulting cert
paths under `/etc/letsencrypt/live/yourdomain.com/`.

**`Domain: ... Type: dns ... NXDOMAIN`**
The domain has no DNS record at all. Add an A (or AAAA) record at your DNS
provider pointing to your server's IP, wait for propagation, then confirm
with `dig yourdomain.com +short` before retrying.

**`Invalid response ... 404` during the HTTP-01 challenge**
Usually means the port-80 request isn't reaching the site block you expect —
check for the conflicting-server-name case above, or confirm your firewall
allows inbound traffic on port 80.

## License

Source-available, free for personal and non-commercial use. Commercial use
requires a separate agreement — see [LICENSE](LICENSE) for full terms.

## Contributing

Issues and PRs welcome. This is intentionally a small, single-file script —
keep additions minimal and dependency-free (no additional packages beyond
`nginx`, `certbot`, and standard coreutils/bash).