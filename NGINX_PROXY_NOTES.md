# Nginx Proxy Configuration & Proxy-Awareness

This document summarizes the changes made to ensure the Nutanix Cluster Management (ntnx-cm) application functions correctly behind an Nginx reverse proxy (specifically when hosted at a subpath like `/cm/`).

## 1. Flask ProxyFix Middleware
The application uses the `ProxyFix` middleware from `Werkzeug` to interpret standard proxy headers. This ensures that `url_for` generates paths that include the correct prefix and protocol.

```python
# app.py
from werkzeug.middleware.proxy_fix import ProxyFix
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_port=1, x_prefix=1)
```

## 2. API-Aware Authentication Guard
To prevent "Malformed JSON" errors in the frontend (caused by the browser receiving a 302 Redirect to an HTML login page when a session expires), the authentication guard was refactored. 

- **Behavior**: If a request to an `/api/` endpoint is unauthorized, the server now returns a **401 Unauthorized** JSON response instead of a redirect.
- **Frontend Benefit**: This allows the frontend status-polling logic to catch the 401 and gracefully alert the user to re-log, rather than crashing on a "Unexpected token '<'" (HTML login page) error.

```python
# app.py snippet
if is_ajax:
    return {"error": "Session expired. Please refresh the page and login again."}, 401
return redirect(url_for('login'))
```

## 3. Dynamic Session Cookie Path
The application automatically adjusts the `SESSION_COOKIE_PATH` to match the `X-Forwarded-Prefix` header if one is provided. This ensures session persistence when the app is proxied under a subpath.

## 4. Recommended Nginx Configuration
To support these features, your Nginx location block should look like this:

```nginx
location /cm/ {
    proxy_pass http://<backend_ip>:5005/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    
    # CRITICAL: This allows the app to know its subpath
    proxy_set_header X-Forwarded-Prefix /cm;
    
    proxy_redirect / /cm/;
    proxy_cookie_path / /cm/;
}
```

## How to Undo These Changes

If you want to revert to a standard, non-proxy-aware setup (e.g., if you are no longer using Nginx or a subpath):

### 1. In `app.py`:
- Remove the `ProxyFix` middleware line: `app.wsgi_app = ProxyFix(...)`.
- Revert the `requires_auth` decorator to always redirect to login:
  ```python
  # Revert this block:
  if is_ajax:
      return {"error": "..."}, 401
  return redirect(url_for('login'))
  
  # Back to:
  return redirect(url_for('login'))
  ```
- Remove the `handle_proxy_prefix` before-request handler.

### 2. In Nginx:
- Remove the `proxy_set_header X-Forwarded-Prefix /cm;` line.
- (Optional) Revert `proxy_redirect` and `proxy_cookie_path` to `/ /;` if the subpath is removed.

