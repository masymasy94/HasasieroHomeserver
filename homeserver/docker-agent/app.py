import json
import os
import queue
import re
import sqlite3
import subprocess
import threading
import uuid
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path

import docker
import requests
from flask import (
    Flask, render_template, request, Response, stream_with_context, jsonify,
)

app = Flask(__name__)

# ─── Configuration ──────────────────────────────────────────────────────────
OLLAMA_URL = "http://ollama:11434"
MODEL = "qwen3:8b"
DATA_DIR = Path("/app/data")
CONTEXT_DIR = DATA_DIR / "context"
DB_PATH = DATA_DIR / "agent.db"
MAX_TOOL_ROUNDS = 8
MAX_CONTEXT_CHARS = 3000
HISTORY_LIMIT = 30


# ─── Helpers ────────────────────────────────────────────────────────────────
def sse(event_type, data=""):
    """Build an SSE data line."""
    if isinstance(data, dict):
        payload = {"type": event_type, **data}
    else:
        payload = {"type": event_type, "content": data}
    return f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"


# ─── Database ───────────────────────────────────────────────────────────────
@contextmanager
def get_db():
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init_db():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with get_db() as db:
        db.execute("""CREATE TABLE IF NOT EXISTS chats (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT 'Nuova chat',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )""")
        db.execute("""CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            chat_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY (chat_id) REFERENCES chats(id) ON DELETE CASCADE
        )""")


# ─── Context files ──────────────────────────────────────────────────────────
def init_context():
    CONTEXT_DIR.mkdir(parents=True, exist_ok=True)
    defaults = {
        "sistema.md": (
            "# Profilo Sistema\n\n"
            "Questo file viene aggiornato dall'agente con informazioni sull'hardware,\n"
            "il sistema operativo, la rete e le risorse del server.\n"
            "Usa il tool `system_info` per raccogliere dati e aggiorna questo file.\n"
        ),
        "servizi.md": (
            "# Servizi e Container\n\n"
            "Questo file descrive i servizi Docker attivi, il loro scopo e le dipendenze.\n"
            "L'agente lo aggiorna quando apprende nuove informazioni sui container.\n"
        ),
        "note.md": (
            "# Note Persistenti\n\n"
            "Appunti dell'agente: problemi noti, soluzioni trovate, configurazioni particolari,\n"
            "preferenze dell'utente e qualsiasi informazione utile per conversazioni future.\n"
        ),
    }
    for name, content in defaults.items():
        path = CONTEXT_DIR / name
        if not path.exists():
            path.write_text(content)


def _context_list(_):
    files = sorted(CONTEXT_DIR.glob("*.md"))
    if not files:
        return "Nessun file di contesto trovato."
    return "\n".join(f"- {f.name} ({f.stat().st_size} bytes)" for f in files)


def _context_read(name):
    name = name.strip()
    if not name.endswith(".md"):
        name += ".md"
    path = CONTEXT_DIR / name
    if not path.exists():
        return f"File '{name}' non trovato. Usa context_list per vedere i file disponibili."
    content = path.read_text()
    if len(content) > MAX_CONTEXT_CHARS:
        return content[:MAX_CONTEXT_CHARS] + "\n... [troncato]"
    return content


def _context_write(params):
    sep = params.find("|")
    if sep == -1:
        return "Formato: context_write|nome_file.md|contenuto"
    name = params[:sep].strip()
    content = params[sep + 1:]
    if not name.endswith(".md"):
        name += ".md"
    name = re.sub(r"[^\w\-.]", "_", name)
    (CONTEXT_DIR / name).write_text(content)
    return f"File '{name}' aggiornato ({len(content)} bytes)."


# ─── Host command execution ─────────────────────────────────────────────────
def run_on_host(cmd, timeout=30):
    try:
        result = subprocess.run(
            ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--",
             "bash", "-c", cmd],
            capture_output=True, text=True, timeout=timeout,
        )
        output = result.stdout
        if result.stderr:
            output += f"\nSTDERR: {result.stderr}"
        if result.returncode != 0:
            output += f"\n(exit code {result.returncode})"
        if len(output) > 6000:
            output = output[:6000] + "\n... [troncato]"
        return output.strip() or "(nessun output)"
    except subprocess.TimeoutExpired:
        return f"Comando scaduto dopo {timeout}s"
    except Exception as e:
        return f"Errore: {e}"


# ─── Docker tools ───────────────────────────────────────────────────────────
def get_container_status():
    try:
        client = docker.DockerClient(base_url="unix:///var/run/docker.sock")
        containers = client.containers.list(all=True)
        lines = []
        for c in containers:
            name = c.name
            image = c.image.tags[0] if c.image.tags else c.attrs["Config"]["Image"]
            status = c.status
            health = ""
            if "Health" in c.attrs.get("State", {}):
                health = f" ({c.attrs['State']['Health']['Status']})"
            ports = c.attrs.get("NetworkSettings", {}).get("Ports", {})
            port_str = ""
            if ports:
                mappings = []
                for cp, hb_list in ports.items():
                    if hb_list:
                        for hb in hb_list:
                            mappings.append(f"{hb['HostPort']}->{cp}")
                    else:
                        mappings.append(cp)
                port_str = ", ".join(mappings)
            stats_str = ""
            if status == "running":
                try:
                    s = c.stats(stream=False)
                    mem = s["memory_stats"].get("usage", 0)
                    lim = s["memory_stats"].get("limit", 1)
                    stats_str = f" | RAM: {mem / 1048576:.0f}MB ({mem / lim * 100:.1f}%)"
                except Exception:
                    pass
            lines.append(f"- {name}: {status}{health} | image: {image} | ports: {port_str or 'none'}{stats_str}")
        client.close()
        return "\n".join(sorted(lines))
    except Exception as e:
        return f"Errore Docker: {e}"


def get_container_status_light():
    try:
        client = docker.DockerClient(base_url="unix:///var/run/docker.sock")
        containers = client.containers.list(all=True)
        lines = []
        for c in containers:
            name = c.name
            image = c.image.tags[0] if c.image.tags else c.attrs["Config"]["Image"]
            status = c.status
            health = ""
            if "Health" in c.attrs.get("State", {}):
                health = f" ({c.attrs['State']['Health']['Status']})"
            ports = c.attrs.get("NetworkSettings", {}).get("Ports", {})
            port_str = ""
            if ports:
                mappings = []
                for cp, hb_list in ports.items():
                    if hb_list:
                        for hb in hb_list:
                            mappings.append(f"{hb['HostPort']}->{cp}")
                    else:
                        mappings.append(cp)
                port_str = ", ".join(mappings)
            lines.append(f"- {name}: {status}{health} | image: {image} | ports: {port_str or 'none'}")
        client.close()
        return "\n".join(sorted(lines))
    except Exception as e:
        return f"Errore Docker: {e}"


def get_container_logs(container_name, tail=30):
    try:
        client = docker.DockerClient(base_url="unix:///var/run/docker.sock")
        container = client.containers.get(container_name.strip())
        logs = container.logs(tail=tail, timestamps=True).decode("utf-8", errors="replace")
        client.close()
        return logs
    except Exception as e:
        return f"Errore log {container_name}: {e}"


def get_container_stats(container_name):
    try:
        client = docker.DockerClient(base_url="unix:///var/run/docker.sock")
        container = client.containers.get(container_name.strip())
        s = container.stats(stream=False)
        mem = s["memory_stats"].get("usage", 0)
        lim = s["memory_stats"].get("limit", 1)
        cpu_d = s["cpu_stats"]["cpu_usage"]["total_usage"] - s["precpu_stats"]["cpu_usage"]["total_usage"]
        sys_d = s["cpu_stats"].get("system_cpu_usage", 0) - s["precpu_stats"].get("system_cpu_usage", 0)
        ncpu = s["cpu_stats"].get("online_cpus", 1)
        cpu_pct = (cpu_d / sys_d) * ncpu * 100 if sys_d > 0 else 0
        net = s.get("networks", {})
        rx = sum(v.get("rx_bytes", 0) for v in net.values()) / 1048576
        tx = sum(v.get("tx_bytes", 0) for v in net.values()) / 1048576
        client.close()
        return (
            f"Container: {container_name}\n"
            f"CPU: {cpu_pct:.2f}%\n"
            f"Memory: {mem / 1048576:.1f}MB / {lim / 1048576:.0f}MB ({mem / lim * 100:.1f}%)\n"
            f"Network: RX {rx:.1f}MB / TX {tx:.1f}MB"
        )
    except Exception as e:
        return f"Errore stats {container_name}: {e}"


PROTECTED_CONTAINERS = {
    "docker-agent", "ollama", "portainer", "nginx-proxy-manager",
    "homeassistant", "gluetun",
}


def restart_container(name):
    name = name.strip()
    if name in PROTECTED_CONTAINERS:
        return f"RIFIUTATO: '{name}' e' protetto."
    try:
        client = docker.DockerClient(base_url="unix:///var/run/docker.sock")
        client.containers.get(name).restart(timeout=30)
        client.close()
        return f"Container '{name}' riavviato."
    except Exception as e:
        return f"Errore riavvio {name}: {e}"


def stop_container(name):
    name = name.strip()
    if name in PROTECTED_CONTAINERS:
        return f"RIFIUTATO: '{name}' e' protetto."
    try:
        client = docker.DockerClient(base_url="unix:///var/run/docker.sock")
        client.containers.get(name).stop(timeout=30)
        client.close()
        return f"Container '{name}' fermato."
    except Exception as e:
        return f"Errore stop {name}: {e}"


def start_container(name):
    name = name.strip()
    try:
        client = docker.DockerClient(base_url="unix:///var/run/docker.sock")
        client.containers.get(name).start()
        client.close()
        return f"Container '{name}' avviato."
    except Exception as e:
        return f"Errore avvio {name}: {e}"


# ─── Host system tools ──────────────────────────────────────────────────────
def run_command(cmd):
    cmd = cmd.strip()
    return run_on_host(cmd, timeout=60) if cmd else "Nessun comando."


def read_file(path):
    path = path.strip()
    return run_on_host(f"cat '{path}' 2>&1 | head -200", timeout=10) if path else "Nessun percorso."


def write_file(params):
    sep = params.find("|")
    if sep == -1:
        return "Formato: write_file|percorso|contenuto"
    path = params[:sep].strip()
    content = params[sep + 1:]
    return run_on_host(f"cat > '{path}' << 'AGENT_EOF'\n{content}\nAGENT_EOF", timeout=10)


def system_info(_):
    return run_on_host(
        "echo '=== HOSTNAME ===' && hostname && "
        "echo '=== UPTIME ===' && uptime && "
        "echo '=== OS ===' && cat /etc/os-release 2>/dev/null | head -4 && "
        "echo '=== CPU ===' && lscpu 2>/dev/null | grep -E '^(Architecture|CPU\\(s\\)|Model name|Thread)' && "
        "echo '=== MEMORY ===' && free -h && "
        "echo '=== DISK ===' && df -h / /home /mnt/* 2>/dev/null && "
        "echo '=== GPU ===' && (nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu "
        "--format=csv,noheader 2>/dev/null || echo 'N/A') && "
        "echo '=== NETWORK ===' && ip -4 addr show 2>/dev/null | grep -E '(^[0-9]|inet )' && "
        "echo '=== LOAD ===' && cat /proc/loadavg",
        timeout=15,
    )


def list_directory(path):
    path = path.strip() or "/"
    return run_on_host(f"ls -lah '{path}' 2>&1", timeout=10)


def manage_service(params):
    parts = params.strip().split(None, 1)
    if len(parts) < 2:
        return "Formato: manage_service|azione servizio (es: status ssh)"
    action, service = parts
    allowed = {"status", "start", "stop", "restart", "enable", "disable", "is-active", "is-enabled"}
    if action not in allowed:
        return f"Azione '{action}' non valida. Permesse: {', '.join(sorted(allowed))}"
    return run_on_host(f"systemctl {action} {service} 2>&1", timeout=15)


def list_processes(_):
    return run_on_host("ps aux --sort=-%mem | head -25", timeout=10)


# ─── Tool registry ──────────────────────────────────────────────────────────
TOOLS = {
    "get_container_status": lambda _: get_container_status(),
    "get_container_status_light": lambda _: get_container_status_light(),
    "get_container_logs": lambda p: get_container_logs(p),
    "get_container_stats": lambda p: get_container_stats(p),
    "restart_container": restart_container,
    "stop_container": stop_container,
    "start_container": start_container,
    "system_info": system_info,
    "run_command": run_command,
    "read_file": read_file,
    "write_file": write_file,
    "list_directory": list_directory,
    "manage_service": manage_service,
    "list_processes": list_processes,
    "context_list": _context_list,
    "context_read": _context_read,
    "context_write": _context_write,
}


# ─── System prompt ──────────────────────────────────────────────────────────
def build_system_prompt():
    prompt = """Sei un assistente esperto per la gestione completa di un homeserver Linux.
Puoi gestire container Docker, eseguire comandi, leggere/scrivere file, gestire servizi, e mantenere note persistenti.

Rispondi in italiano a meno che l'utente non scriva in un'altra lingua.
Sii conciso e diretto. Usa markdown quando utile.

## TOOL DISPONIBILI

### Docker
1. **get_container_status** - Stato dettagliato container CON uso RAM (MOLTO LENTO, ~1 min! Evita se possibile)
2. **get_container_status_light** - Stato container SENZA risorse (VELOCE, usa questo di default)
3. **get_container_logs** - Log di un container (param: nome)
4. **get_container_stats** - Risorse CPU/RAM di UN singolo container (param: nome, ~2s)
5. **restart_container** - Riavvia container (param: nome)
6. **stop_container** - Ferma container (param: nome)
7. **start_container** - Avvia container (param: nome)

IMPORTANTE: Per sapere quali container consumano piu' risorse, NON usare get_container_status.
Usa invece get_container_stats su singoli container, oppure run_command con "docker stats --no-stream --format '{{.Name}}: CPU {{.CPUPerc}} MEM {{.MemUsage}}'" che e' molto piu' veloce.

### Sistema
8. **system_info** - Panoramica sistema (CPU, RAM, disco, GPU, rete)
9. **run_command** - Esegui comando shell sull'host (param: comando)
10. **read_file** - Leggi file dall'host (param: percorso)
11. **write_file** - Scrivi file sull'host (param: percorso|contenuto)
12. **list_directory** - Elenca file (param: percorso)
13. **manage_service** - Gestisci servizi systemd (param: azione servizio)
14. **list_processes** - Processi piu' pesanti

### Contesto Persistente
15. **context_list** - Elenca file di contesto
16. **context_read** - Leggi file di contesto (param: nome_file.md)
17. **context_write** - Aggiorna file di contesto (param: nome_file.md|contenuto)

## COME USARE I TOOL

Rispondi con questo formato esatto (una riga da sola):
<tool>nome_tool|parametro</tool>

Esempi:
<tool>get_container_status_light|</tool>
<tool>run_command|docker stats --no-stream --format '{{.Name}}: CPU {{.CPUPerc}} MEM {{.MemUsage}}'</tool>
<tool>get_container_stats|plex</tool>
<tool>context_write|note.md|# Note\\n\\nContenuto aggiornato...</tool>

## REGOLE
- UN SOLO tool per volta. Analizza il risultato prima di procedere.
- Prima di azioni distruttive, spiega cosa intendi fare.
- Non inventare dati: usa i tool.
- Container PROTETTI: docker-agent, ollama, portainer, nginx-proxy-manager, homeassistant, gluetun
- USA I FILE DI CONTESTO: quando apprendi info utili, aggiorna i file di contesto con context_write.
"""

    ctx_parts = []
    for f in sorted(CONTEXT_DIR.glob("*.md")):
        content = f.read_text().strip()
        if len(content) > 30:
            if len(content) > MAX_CONTEXT_CHARS:
                content = content[:MAX_CONTEXT_CHARS] + "\n... [troncato]"
            ctx_parts.append(f"### {f.name}\n{content}")
    if ctx_parts:
        prompt += "\n\n## CONTESTO PERSISTENTE (tue note dalle conversazioni precedenti)\n\n"
        prompt += "\n\n".join(ctx_parts)

    return prompt


# ─── Ollama ─────────────────────────────────────────────────────────────────
def call_ollama(messages):
    """Non-streaming call (used for title generation)."""
    resp = requests.post(
        f"{OLLAMA_URL}/api/chat",
        json={"model": MODEL, "messages": messages, "stream": False},
        timeout=120,
    )
    resp.raise_for_status()
    return resp.json()["message"]["content"]


def stream_ollama(messages):
    """Streaming call. Yields tokens as they arrive. Returns full text via .full_text after iteration."""
    resp = requests.post(
        f"{OLLAMA_URL}/api/chat",
        json={"model": MODEL, "messages": messages, "stream": True},
        timeout=300,
        stream=True,
    )
    resp.raise_for_status()
    return resp


def parse_tool_call(text):
    m = re.search(r"<tool>(\w+)\|([^<]*)</tool>", text)
    return (m.group(1), m.group(2)) if m else None


def _generate_title_bg(chat_id, first_message):
    try:
        resp = requests.post(
            f"{OLLAMA_URL}/api/chat",
            json={
                "model": MODEL,
                "messages": [{
                    "role": "user",
                    "content": (
                        "Genera un titolo brevissimo (3-5 parole, senza virgolette) "
                        f"per questa domanda:\n{first_message[:300]}"
                    ),
                }],
                "stream": False,
            },
            timeout=60,
        )
        raw = resp.json()["message"]["content"]
        title = re.sub(r"<think>.*?</think>", "", raw, flags=re.DOTALL).strip().strip("\"'")
        if title and 2 < len(title) < 80:
            with get_db() as db:
                db.execute("UPDATE chats SET title = ? WHERE id = ?", (title, chat_id))
    except Exception:
        pass


def execute_tool_with_keepalive(tool_func, param):
    """Run a tool in a background thread, yielding keepalive SSE events while waiting."""
    q = queue.Queue()

    def worker():
        try:
            q.put(("ok", tool_func(param)))
        except Exception as e:
            q.put(("err", str(e)))

    threading.Thread(target=worker, daemon=True).start()

    while True:
        try:
            status, result = q.get(timeout=4)
            return result if status == "ok" else f"Errore tool: {result}"
        except queue.Empty:
            yield sse("keepalive")


# ─── Flask: pages ───────────────────────────────────────────────────────────
@app.route("/")
def index():
    return render_template("index.html")


# ─── Flask: chat CRUD ──────────────────────────────────────────────────────
@app.route("/api/chats", methods=["GET"])
def api_list_chats():
    with get_db() as db:
        rows = db.execute(
            "SELECT id, title, created_at, updated_at FROM chats ORDER BY updated_at DESC"
        ).fetchall()
    return jsonify([dict(r) for r in rows])


@app.route("/api/chats", methods=["POST"])
def api_create_chat():
    chat_id = str(uuid.uuid4())
    now = datetime.now().isoformat()
    with get_db() as db:
        db.execute(
            "INSERT INTO chats (id,title,created_at,updated_at) VALUES (?,?,?,?)",
            (chat_id, "Nuova chat", now, now),
        )
    return jsonify({"id": chat_id, "title": "Nuova chat", "created_at": now, "updated_at": now})


@app.route("/api/chats/<chat_id>", methods=["GET"])
def api_get_chat(chat_id):
    with get_db() as db:
        chat = db.execute("SELECT * FROM chats WHERE id=?", (chat_id,)).fetchone()
        if not chat:
            return jsonify({"error": "not found"}), 404
        msgs = db.execute(
            "SELECT id,role,content,created_at FROM messages WHERE chat_id=? ORDER BY id",
            (chat_id,),
        ).fetchall()
    return jsonify({"chat": dict(chat), "messages": [dict(m) for m in msgs]})


@app.route("/api/chats/<chat_id>", methods=["DELETE"])
def api_delete_chat(chat_id):
    with get_db() as db:
        db.execute("DELETE FROM messages WHERE chat_id=?", (chat_id,))
        db.execute("DELETE FROM chats WHERE id=?", (chat_id,))
    return jsonify({"ok": True})


@app.route("/api/chats/<chat_id>", methods=["PUT"])
def api_update_chat(chat_id):
    title = (request.json or {}).get("title")
    if title:
        with get_db() as db:
            db.execute(
                "UPDATE chats SET title=?, updated_at=? WHERE id=?",
                (title, datetime.now().isoformat(), chat_id),
            )
    return jsonify({"ok": True})


# ─── Flask: send message (SSE with streaming thinking) ─────────────────────
@app.route("/api/chats/<chat_id>/messages", methods=["POST"])
def api_send_message(chat_id):
    user_msg = (request.json or {}).get("message", "").strip()
    if not user_msg:
        return jsonify({"error": "empty"}), 400

    now = datetime.now().isoformat()

    with get_db() as db:
        db.execute(
            "INSERT INTO messages (chat_id,role,content,created_at) VALUES (?,?,?,?)",
            (chat_id, "user", user_msg, now),
        )
        cnt = db.execute(
            "SELECT COUNT(*) as c FROM messages WHERE chat_id=?", (chat_id,)
        ).fetchone()["c"]
        is_first = cnt == 1
        if is_first:
            short = user_msg[:50] + ("..." if len(user_msg) > 50 else "")
            db.execute("UPDATE chats SET title=?, updated_at=? WHERE id=?", (short, now, chat_id))
        else:
            db.execute("UPDATE chats SET updated_at=? WHERE id=?", (now, chat_id))
        rows = db.execute(
            "SELECT role, content FROM messages WHERE chat_id=? ORDER BY id", (chat_id,)
        ).fetchall()

    ollama_msgs = [{"role": "system", "content": build_system_prompt()}]
    history = [dict(r) for r in rows]
    for msg in history[-HISTORY_LIMIT:]:
        ollama_msgs.append({"role": msg["role"], "content": msg["content"]})

    def generate():
        nonlocal ollama_msgs

        for round_num in range(MAX_TOOL_ROUNDS):
            # ── Stream from Ollama ──────────────────────────────────
            full_text = ""
            think_sent_len = 0
            think_finalized = False

            try:
                ollama_resp = stream_ollama(ollama_msgs)
            except Exception as e:
                yield sse("error", str(e))
                return

            # Signal that we're thinking
            yield sse("thinking_start")

            for raw_line in ollama_resp.iter_lines():
                if not raw_line:
                    continue
                try:
                    chunk = json.loads(raw_line)
                except json.JSONDecodeError:
                    continue

                token = chunk.get("message", {}).get("content", "")
                full_text += token

                # ── Stream thinking content in real time ──
                if not think_finalized:
                    think_start_idx = full_text.find("<think>")
                    think_end_idx = full_text.find("</think>")

                    if think_start_idx != -1 and think_end_idx == -1:
                        # Inside <think> tags — stream content
                        current = full_text[think_start_idx + 7:]
                        new_part = current[think_sent_len:]
                        if len(new_part) >= 3:
                            yield sse("thinking_delta", new_part)
                            think_sent_len = len(current)
                    elif think_start_idx != -1 and think_end_idx != -1:
                        # Thinking ended — send remaining
                        final = full_text[think_start_idx + 7:think_end_idx]
                        remaining = final[think_sent_len:]
                        if remaining:
                            yield sse("thinking_delta", remaining)
                        think_finalized = True
                        yield sse("thinking_end")

                if chunk.get("done"):
                    break

            # If thinking never ended explicitly, end it now
            if not think_finalized:
                # Maybe no <think> tags at all, or incomplete
                think_start_idx = full_text.find("<think>")
                if think_start_idx != -1:
                    think_end_idx = full_text.find("</think>")
                    end = think_end_idx if think_end_idx != -1 else len(full_text)
                    final = full_text[think_start_idx + 7:end]
                    remaining = final[think_sent_len:]
                    if remaining:
                        yield sse("thinking_delta", remaining)
                yield sse("thinking_end")

            # ── Check for tool call ─────────────────────────────────
            tc = parse_tool_call(full_text)
            if tc:
                tool_name, tool_param = tc
                if tool_name in TOOLS:
                    yield sse("tool_call", {"tool": tool_name, "param": tool_param})

                    # Execute tool with keepalive to prevent connection timeout
                    tool_result = None
                    for event_or_result in _execute_tool_gen(tool_name, tool_param):
                        if isinstance(event_or_result, str) and event_or_result.startswith("data:"):
                            yield event_or_result  # keepalive
                        else:
                            tool_result = event_or_result

                    ollama_msgs.append({"role": "assistant", "content": full_text})
                    ollama_msgs.append({
                        "role": "user",
                        "content": (
                            f"Risultato del tool {tool_name}:\n```\n{tool_result}\n```\n"
                            "Analizza il risultato e rispondi. Non usare altri tool se non necessario."
                        ),
                    })
                    continue
                else:
                    full_text = full_text.replace(
                        f"<tool>{tool_name}|{tool_param}</tool>",
                        f"[Tool sconosciuto: {tool_name}]",
                    )

            # ── Final response ──────────────────────────────────────
            clean = re.sub(r"<think>.*?</think>", "", full_text, flags=re.DOTALL).strip()

            resp_now = datetime.now().isoformat()
            with get_db() as db:
                db.execute(
                    "INSERT INTO messages (chat_id,role,content,created_at) VALUES (?,?,?,?)",
                    (chat_id, "assistant", clean, resp_now),
                )

            yield sse("response", clean)

            if is_first:
                threading.Thread(
                    target=_generate_title_bg, args=(chat_id, user_msg), daemon=True
                ).start()
            return

        yield sse("error", "Troppe chiamate tool consecutive.")

    return Response(stream_with_context(generate()), content_type="text/event-stream")


def _execute_tool_gen(tool_name, tool_param):
    """Execute a tool in background thread, yielding keepalive events."""
    q = queue.Queue()

    def worker():
        try:
            q.put(TOOLS[tool_name](tool_param))
        except Exception as e:
            q.put(f"Errore tool: {e}")

    threading.Thread(target=worker, daemon=True).start()

    while True:
        try:
            result = q.get(timeout=4)
            yield result  # final result (not a string starting with "data:")
            return
        except queue.Empty:
            yield sse("keepalive")


# ─── Main ───────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    init_db()
    init_context()
    app.run(host="0.0.0.0", port=5055, debug=False)
