import json
import time
import docker
import requests
from flask import Flask, render_template, request, Response, stream_with_context

app = Flask(__name__)

OLLAMA_URL = "http://ollama:11434"
MODEL = "qwen3:8b"


def get_container_status():
    """Get detailed status of all Docker containers."""
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
            started = c.attrs["State"].get("StartedAt", "N/A")
            ports = c.attrs.get("NetworkSettings", {}).get("Ports", {})
            port_str = ""
            if ports:
                mappings = []
                for container_port, host_bindings in ports.items():
                    if host_bindings:
                        for hb in host_bindings:
                            mappings.append(f"{hb['HostPort']}->{container_port}")
                    else:
                        mappings.append(container_port)
                port_str = ", ".join(mappings)

            # Get resource usage (CPU/memory) if running
            stats_str = ""
            if status == "running":
                try:
                    stats = c.stats(stream=False)
                    mem_usage = stats["memory_stats"].get("usage", 0)
                    mem_limit = stats["memory_stats"].get("limit", 1)
                    mem_mb = mem_usage / (1024 * 1024)
                    mem_pct = (mem_usage / mem_limit) * 100
                    stats_str = f" | RAM: {mem_mb:.0f}MB ({mem_pct:.1f}%)"
                except Exception:
                    pass

            lines.append(
                f"- {name}: {status}{health} | image: {image} | ports: {port_str or 'none'}{stats_str}"
            )
        client.close()
        return "\n".join(sorted(lines))
    except Exception as e:
        return f"Error reading Docker: {e}"


def get_container_status_light():
    """Get container status without resource stats (much faster)."""
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
                for container_port, host_bindings in ports.items():
                    if host_bindings:
                        for hb in host_bindings:
                            mappings.append(f"{hb['HostPort']}->{container_port}")
                    else:
                        mappings.append(container_port)
                port_str = ", ".join(mappings)
            lines.append(
                f"- {name}: {status}{health} | image: {image} | ports: {port_str or 'none'}"
            )
        client.close()
        return "\n".join(sorted(lines))
    except Exception as e:
        return f"Error reading Docker: {e}"


def get_container_logs(container_name, tail=30):
    """Get recent logs from a specific container."""
    try:
        client = docker.DockerClient(base_url="unix:///var/run/docker.sock")
        container = client.containers.get(container_name)
        logs = container.logs(tail=tail, timestamps=True).decode("utf-8", errors="replace")
        client.close()
        return logs
    except Exception as e:
        return f"Error getting logs for {container_name}: {e}"


def get_container_stats(container_name):
    """Get detailed resource stats for a specific container."""
    try:
        client = docker.DockerClient(base_url="unix:///var/run/docker.sock")
        container = client.containers.get(container_name)
        stats = container.stats(stream=False)
        mem_usage = stats["memory_stats"].get("usage", 0)
        mem_limit = stats["memory_stats"].get("limit", 1)
        mem_mb = mem_usage / (1024 * 1024)
        mem_pct = (mem_usage / mem_limit) * 100

        # CPU calculation
        cpu_delta = stats["cpu_stats"]["cpu_usage"]["total_usage"] - \
                    stats["precpu_stats"]["cpu_usage"]["total_usage"]
        system_delta = stats["cpu_stats"].get("system_cpu_usage", 0) - \
                       stats["precpu_stats"].get("system_cpu_usage", 0)
        n_cpus = stats["cpu_stats"].get("online_cpus", 1)
        cpu_pct = (cpu_delta / system_delta) * n_cpus * 100 if system_delta > 0 else 0

        # Network
        net = stats.get("networks", {})
        net_rx = sum(v.get("rx_bytes", 0) for v in net.values()) / (1024 * 1024)
        net_tx = sum(v.get("tx_bytes", 0) for v in net.values()) / (1024 * 1024)

        client.close()
        return (
            f"Container: {container_name}\n"
            f"CPU: {cpu_pct:.2f}%\n"
            f"Memory: {mem_mb:.1f}MB / {mem_limit / (1024*1024):.0f}MB ({mem_pct:.1f}%)\n"
            f"Network: RX {net_rx:.1f}MB / TX {net_tx:.1f}MB"
        )
    except Exception as e:
        return f"Error getting stats for {container_name}: {e}"


PROTECTED_CONTAINERS = {
    "docker-agent", "ollama", "portainer", "nginx-proxy-manager",
    "homeassistant", "gluetun",
}


def restart_container(container_name):
    """Restart a specific container."""
    container_name = container_name.strip()
    if container_name in PROTECTED_CONTAINERS:
        return f"RIFIUTATO: il container '{container_name}' è protetto e non può essere riavviato da questo tool."
    try:
        client = docker.DockerClient(base_url="unix:///var/run/docker.sock")
        container = client.containers.get(container_name)
        container.restart(timeout=30)
        client.close()
        return f"Container '{container_name}' riavviato con successo."
    except Exception as e:
        return f"Errore nel riavvio di {container_name}: {e}"


def stop_container(container_name):
    """Stop a specific container."""
    container_name = container_name.strip()
    if container_name in PROTECTED_CONTAINERS:
        return f"RIFIUTATO: il container '{container_name}' è protetto e non può essere fermato da questo tool."
    try:
        client = docker.DockerClient(base_url="unix:///var/run/docker.sock")
        container = client.containers.get(container_name)
        container.stop(timeout=30)
        client.close()
        return f"Container '{container_name}' fermato con successo."
    except Exception as e:
        return f"Errore nello stop di {container_name}: {e}"


def start_container(container_name):
    """Start a stopped container."""
    container_name = container_name.strip()
    try:
        client = docker.DockerClient(base_url="unix:///var/run/docker.sock")
        container = client.containers.get(container_name)
        container.start()
        client.close()
        return f"Container '{container_name}' avviato con successo."
    except Exception as e:
        return f"Errore nell'avvio di {container_name}: {e}"


SYSTEM_PROMPT = """Sei un assistente esperto per la gestione di un homeserver Linux con Docker.
Il tuo compito è rispondere a domande sullo stato dei container Docker, diagnosticare problemi,
e intervenire per risolverli quando necessario.

Rispondi in italiano a meno che l'utente non ti scriva in un'altra lingua.
Sii conciso e diretto. Usa formattazione markdown quando utile.

Hai accesso a tool di LETTURA e di AZIONE sui container.

Tool di lettura:
1. get_container_status - Stato dettagliato di tutti i container (con uso RAM - lento)
2. get_container_status_light - Stato di tutti i container (senza risorse - veloce)
3. get_container_logs - Ultimi log di un container specifico
4. get_container_stats - Statistiche dettagliate di risorse per un container specifico

Tool di azione:
5. restart_container - Riavvia un container (utile se in errore o unhealthy)
6. stop_container - Ferma un container
7. start_container - Avvia un container fermo

REGOLE IMPORTANTI per i tool di azione:
- Prima di agire, SEMPRE diagnostica il problema con i tool di lettura (logs, stats, status)
- Spiega all'utente cosa hai trovato e cosa intendi fare PRIMA di eseguire l'azione
- Alcuni container sono PROTETTI e non possono essere toccati: docker-agent, ollama, portainer, nginx-proxy-manager, homeassistant, gluetun
- Non riavviare/fermare container senza una buona ragione

Per usare un tool, rispondi ESATTAMENTE con questo formato (su una riga da solo):
<tool>nome_tool|parametro</tool>

Esempi:
<tool>get_container_status_light|</tool>
<tool>get_container_logs|plex</tool>
<tool>restart_container|plex</tool>
<tool>stop_container|jackett</tool>
<tool>start_container|jackett</tool>

Puoi usare un solo tool per volta. Dopo aver ricevuto il risultato, analizzalo e rispondi all'utente.
Non inventare dati: usa sempre i tool per ottenere informazioni aggiornate.
Se non sai quale container l'utente intende, usa get_container_status_light per vedere la lista completa.
"""


TOOLS = {
    "get_container_status": lambda _: get_container_status(),
    "get_container_status_light": lambda _: get_container_status_light(),
    "get_container_logs": lambda name: get_container_logs(name.strip()),
    "get_container_stats": lambda name: get_container_stats(name.strip()),
    "restart_container": lambda name: restart_container(name),
    "stop_container": lambda name: stop_container(name),
    "start_container": lambda name: start_container(name),
}

MAX_TOOL_ROUNDS = 5


def call_ollama(messages):
    """Call Ollama and return the full response text (non-streaming)."""
    resp = requests.post(
        f"{OLLAMA_URL}/api/chat",
        json={"model": MODEL, "messages": messages, "stream": False},
        timeout=120,
    )
    resp.raise_for_status()
    return resp.json()["message"]["content"]


def parse_tool_call(text):
    """Extract tool call from response text. Returns (tool_name, param) or None."""
    import re
    match = re.search(r"<tool>(\w+)\|([^<]*)</tool>", text)
    if match:
        return match.group(1), match.group(2)
    return None


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/chat", methods=["POST"])
def chat():
    data = request.json
    user_message = data.get("message", "")
    history = data.get("history", [])

    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    for h in history:
        messages.append({"role": h["role"], "content": h["content"]})
    messages.append({"role": "user", "content": user_message})

    def generate():
        nonlocal messages
        for round_num in range(MAX_TOOL_ROUNDS):
            # Call Ollama
            try:
                assistant_text = call_ollama(messages)
            except Exception as e:
                yield f"data: {json.dumps({'type': 'error', 'content': f'Errore Ollama: {e}'})}\n\n"
                return

            # Check for tool call
            tool_call = parse_tool_call(assistant_text)
            if tool_call:
                tool_name, tool_param = tool_call
                if tool_name in TOOLS:
                    # Notify frontend about tool usage
                    yield f"data: {json.dumps({'type': 'tool_call', 'tool': tool_name, 'param': tool_param})}\n\n"

                    # Execute tool
                    tool_result = TOOLS[tool_name](tool_param)

                    # Add assistant message and tool result to conversation
                    messages.append({"role": "assistant", "content": assistant_text})
                    messages.append({
                        "role": "user",
                        "content": f"Risultato del tool {tool_name}:\n```\n{tool_result}\n```\nOra analizza il risultato e rispondi alla domanda originale dell'utente. Non usare altri tool a meno che non sia necessario."
                    })
                    # Continue loop to get final response
                    continue
                else:
                    # Unknown tool
                    assistant_text = assistant_text.replace(
                        f"<tool>{tool_name}|{tool_param}</tool>",
                        f"[Tool sconosciuto: {tool_name}]"
                    )

            # No tool call (or unknown tool) - this is the final response
            # Clean up any thinking tags from qwen3
            import re
            clean_text = re.sub(r"<think>.*?</think>", "", assistant_text, flags=re.DOTALL).strip()
            yield f"data: {json.dumps({'type': 'response', 'content': clean_text})}\n\n"
            return

        # Max rounds reached
        yield f"data: {json.dumps({'type': 'error', 'content': 'Troppe chiamate tool, interrompo.'})}\n\n"

    return Response(
        stream_with_context(generate()),
        content_type="text/event-stream",
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5055, debug=False)
