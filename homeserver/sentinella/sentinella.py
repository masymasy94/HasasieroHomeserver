"""Sentinella: ogni 5 minuti controlla container, catena VPN e server.

Ripara da sola i guasti che conosciamo (container orfani di gluetun, container
staccati dalla loro rete, slskd scollegato da Soulseek) e manda una push sul
telefono tramite un webhook di Home Assistant. Un problema si segnala solo se
c'e' per due giri di fila (niente allarmi per i riavvii di watchtower), una
volta sola, e poi arriva il "risolto".

Solo stdlib + docker CLI: gira nell'immagine di secrets-ui (python, docker,
compose, sops). Prova della logica: python3 prova_sentinella.py
"""
import http.client
import json
import os
import shlex
import socket
import subprocess
import sys
import time
import urllib.request

GIRO = 300
PIENO = 0.90
DISCHI = ["/", "/mnt/hdd"]  # spazio + montato; i NAS solo montati e leggibili
NAS = ["/mnt/nas/Elements", "/mnt/nas/Seagate_Backup_Plus_Drive"]
WEBHOOK = "http://192.168.3.54:8123/api/webhook/" + os.environ.get("SENTINELLA_WEBHOOK", "")
SLSKD = "hasasierofy-slskd-1"
TAILSCALE = "/host-run/tailscale/tailscaled.sock"  # /run montato intero, vedi compose


def sh(*cmd, timeout=60, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kw)


def containers():
    ids = sh("docker", "ps", "-aq").stdout.split()
    return json.loads(sh("docker", "inspect", *ids).stdout) if ids else []


def push(testo):
    print(time.strftime("%F %T"), testo.replace("\n", " | "), flush=True)
    corpo = json.dumps({"title": "Sentinella", "message": testo}).encode()
    try:
        urllib.request.urlopen(urllib.request.Request(
            WEBHOOK, corpo, {"Content-Type": "application/json"}), timeout=15)
    except Exception as e:  # noqa: BLE001 - senza HA non c'e' altro canale
        print("push fallita:", e, file=sys.stderr, flush=True)


# --- logica pura (provata in prova_sentinella.py) ---------------------------

def orfani(cs):
    """Container agganciati alla netns di un gluetun che non esiste piu'.
    Saltati quelli gia' fermi prima che nascesse il gluetun attuale: spenti
    apposta. ponytail: l'unico padrone di netns qui e' gluetun."""
    g = next((c for c in cs if c["Name"] == "/gluetun"), None)
    if not g or not g["State"]["Running"]:
        return []  # gluetun giu' o in ricreazione: riagganciare adesso fallirebbe
    ids, nato = {c["Id"] for c in cs}, g["Created"][:19]
    return [c for c in cs
            if c["HostConfig"]["NetworkMode"].startswith("container:")
            and c["HostConfig"]["NetworkMode"][10:] not in ids
            and (c["State"]["Running"] or c["State"]["FinishedAt"][:19] >= nato)]


def problemi_container(cs, visti):
    """visti = nomi visti girare da quando parte la sentinella: chi era gia'
    spento (masiero) non e' un guasto. Restart policy "no" = una tantum."""
    p = {}
    for c in cs:
        n, s = c["Name"][1:], c["State"]
        if s["Running"]:
            visti.add(n)
        if s["Restarting"]:
            p[f"riavvio:{n}"] = f"{n} si riavvia in continuazione"
        elif not s["Running"] and n in visti and c["HostConfig"]["RestartPolicy"]["Name"] != "no":
            p[f"fermo:{n}"] = f"{n} si è fermato (uscita {s['ExitCode']})"
        elif s.get("Health", {}).get("Status") == "unhealthy":
            p[f"malato:{n}"] = f"{n} è unhealthy"
    return p


def aggiorna(conta, avvisati, problemi):
    """Ritorna (da avvisare, risolti). Avvisa al 2o giro di fila, una volta."""
    for k in list(conta):
        if k not in problemi:
            del conta[k]
    risolti = [avvisati.pop(k) for k in list(avvisati) if k not in problemi]
    nuovi = []
    for k, msg in problemi.items():
        conta[k] = conta.get(k, 0) + 1
        if conta[k] == 2:
            avvisati[k] = msg
            nuovi.append(msg)
    return nuovi, risolti


# --- riparazioni -------------------------------------------------------------

def ricrea(c):
    """Ricrea il container dal compose del suo stack, coi segreti del vault se
    lo stack ne ha uno. Le etichette di compose dicono dove e cosa."""
    l = c["Config"]["Labels"]
    wd = l.get("com.docker.compose.project.working_dir")
    if not wd:
        return False
    cmd = ["docker", "compose", "-p", l["com.docker.compose.project"]]
    for f in l["com.docker.compose.project.config_files"].split(","):
        cmd += ["-f", f]
    cmd += ["up", "-d", "--no-deps", "--no-build", "--force-recreate", l["com.docker.compose.service"]]
    if os.path.exists(f"{wd}/env.sops.yaml"):
        cmd = ["sops", "exec-env", "env.sops.yaml", shlex.join(cmd)]
    r = sh(*cmd, cwd=wd, timeout=300)
    if r.returncode:
        print("ricrea", c["Name"], "fallita:", r.stderr[-500:], file=sys.stderr, flush=True)
    return r.returncode == 0


# Gira sull'host (nsenter). Uscita: 0 rimontato, 3 disco assente, 4 smontato
# a mano o rimontaggio gia' fallito dopo questo aggancio, 5 gia' montato, altro =
# mount fallito. Il criterio: il disco e' arrivato DOPO che il .mount si e' spento.
RIMONTA = r'''
u=$(systemd-escape -p --suffix=mount "$1")
systemctl is-active -q "$u" && exit 5
dev=$(systemd-escape -p --suffix=device "$(systemctl show -p What --value "$u")")
systemctl is-active -q "$dev" || exit 3
arrivato=$(systemctl show --timestamp=unix -p ActiveEnterTimestamp --value "$dev")
spento=$(systemctl show --timestamp=unix -p InactiveEnterTimestamp --value "$u")
spento=${spento#@}
[ "${arrivato#@}" -gt "${spento:-0}" ] || exit 4
systemctl start "$u"
'''


def rimonta(d):
    """Un disco USB che si stacca e torna (calo di corrente, 2026-11-08) cambia
    nome (sdc1 -> sdd1) e il .mount di systemd non si rifa' da solo."""
    # tag fisso (ultima stabile al 10/11): con "alpine" nudo un container privilegiato
    # con --pid=host girava l'immagine che il registry dava quel giorno
    return sh("docker", "run", "--rm", "--privileged", "--pid=host", "alpine:3.24.4",
              "nsenter", "-t", "1", "-m", "-p", "--", "sh", "-c", RIMONTA, "_", d,
              timeout=180).returncode


def volumi(cs):
    """{nome volume: cartella dell'host}, per i volumi locali fatti di bind."""
    nomi = {m["Name"] for c in cs for m in c["Mounts"] if m["Type"] == "volume"}
    vs = json.loads(sh("docker", "volume", "inspect", *nomi).stdout) if nomi else []
    return {v["Name"]: (v["Options"] or {}).get("device", "") for v in vs}


def dipendenti(cs, d, vol):
    """Container accesi che vedono d: il loro bind punta ancora al disco vecchio
    finche' non ripartono. Chi monta un padre di d (sentinella, rslave) no."""
    def sotto(p):
        return p == d or p.startswith(d + "/")
    return [c["Name"][1:] for c in cs if c["State"]["Running"] and any(
        sotto(m["Source"] if m["Type"] == "bind" else vol.get(m.get("Name"), ""))
        for m in c["Mounts"])]


def staccati(cs):
    """Dopo un reboot un container puo' risultare Up ma fuori dalla sua rete."""
    fuori = ("default", "bridge", "host", "none")
    return [(c, c["HostConfig"]["NetworkMode"]) for c in cs
            if c["State"]["Running"]
            and c["HostConfig"]["NetworkMode"] not in fuori
            and not c["HostConfig"]["NetworkMode"].startswith("container:")
            and c["HostConfig"]["NetworkMode"] not in (c["NetworkSettings"]["Networks"] or {})]


# --- controlli del server ----------------------------------------------------

def problemi_server():
    p = {}
    for d in DISCHI + NAS:
        try:
            if not os.path.ismount(d):
                p[f"disco:{d}"] = f"{d} non è montato"
                continue
            st = os.statvfs(d)
            usato = 1 - st.f_bavail / st.f_blocks
            if d in DISCHI and usato > PIENO:
                p[f"disco:{d}"] = f"{d} è pieno al {usato:.0%}"
        except OSError as e:
            p[f"disco:{d}"] = f"{d} non è leggibile ({e.strerror})"

    try:
        casa = urllib.request.urlopen("http://ipinfo.io/ip", timeout=15).read().decode().strip()
        r = sh("docker", "exec", "gluetun", "wget", "-qO-", "-T", "15", "http://ipinfo.io/ip")
        if r.returncode:
            p["vpn"] = "la VPN (gluetun) non esce su internet"
        elif r.stdout.strip() == casa:
            p["vpn"] = "gluetun esce con l'IP di casa!"
    except Exception:  # noqa: BLE001 - internet di casa giu': lo dice gia' tutto il resto
        pass

    try:
        s = _tailscale_status()
        if s["BackendState"] != "Running" or not s["Self"]["Online"]:
            p["tailscale"] = f"Tailscale è giù ({s['BackendState']})"
        elif s["Self"].get("KeyExpiry", "9999")[:10] < time.strftime("%F", time.gmtime(time.time() + 7 * 86400)):
            p["tailscale"] = f"la chiave di Tailscale scade il {s['Self']['KeyExpiry'][:10]}"
    except Exception as e:  # noqa: BLE001
        p["tailscale"] = f"Tailscale non risponde ({e.__class__.__name__})"
    return p


def _tailscale_status():
    class Conn(http.client.HTTPConnection):
        def connect(self):
            self.sock = socket.socket(socket.AF_UNIX)
            self.sock.settimeout(10)
            self.sock.connect(TAILSCALE)
    c = Conn("local-tailscaled.sock")
    c.request("GET", "/localapi/v0/status")
    return json.load(c.getresponse())


def slskd_loggato():
    """True/False dal server Soulseek, None se l'API di slskd non risponde."""
    try:
        app = json.load(urllib.request.urlopen("http://gluetun:5030/api/v0/application", timeout=15))
        return app["server"]["isLoggedIn"]
    except Exception:  # noqa: BLE001 - irraggiungibile = orfano o gluetun giu': altri controlli
        return None


def slskd_scollegato(cs):
    c = next((c for c in cs if c["Name"] == "/" + SLSKD), None)
    if not c or not c["State"]["Running"]:
        return False  # se e' fermo lo dice gia' il controllo dei container
    return slskd_loggato() is False


# --- giro --------------------------------------------------------------------

def giro(visti, conta, avvisati):
    cs, fatti, falliti = containers(), [], {}
    for c in orfani(cs):
        n = c["Name"][1:]
        if ricrea(c):
            fatti.append(f"ho ricreato {n}: era rimasto orfano di gluetun")
        else:
            falliti[f"orfano:{n}"] = f"{n} è orfano di gluetun e non riesco a ricrearlo"
    for c, rete in staccati(cs):
        n = c["Name"][1:]
        if sh("docker", "network", "connect", rete, n).returncode == 0 and \
                sh("docker", "restart", n).returncode == 0:
            fatti.append(f"ho riattaccato {n} alla rete {rete}")
        else:
            falliti[f"staccato:{n}"] = f"{n} è staccato da {rete} e non riesco a riattaccarlo"
    for d in NAS:
        if os.path.ismount(d):
            continue
        esito = rimonta(d)
        if esito == 0:
            legati = dipendenti(cs, d, volumi(cs))
            ko = [n for n in legati if sh("docker", "restart", n, timeout=180).returncode]
            fatti.append(f"{d} si era staccato: l'ho rimontato e ho riavviato {', '.join(legati)}"
                         + (f" (non ripartono: {', '.join(ko)})" if ko else ""))
        elif esito not in (3, 4, 5):
            # avvisa subito e una volta: al giro dopo lo script non riprova (esce 4)
            k = f"disco:{d}"
            conta[k], avvisati[k] = 2, f"{d} è tornato ma non riesco a rimontarlo (journalctl -u del suo .mount)"
            fatti.append(avvisati[k])
    if fatti:
        cs = containers()

    problemi = {**problemi_container(cs, visti), **problemi_server(), **falliti}
    if slskd_scollegato(cs):
        problemi["slskd"] = "slskd è scollegato da Soulseek"
        if conta.get("slskd", 0) + 1 == 2:  # stesso giro in cui parte l'avviso
            # slskd 0.26 perde il server senza accorgersene piu' volte al giorno e il
            # riavvio basta sempre: si avvisa solo se non si ricollega (rientra in ~5 s).
            # ponytail: se torna a cadere a ogni giro non avvisa mai; il log lo dice.
            if sh("docker", "restart", SLSKD).returncode:
                problemi["slskd"] += " e non riesco a riavviarlo"
            else:
                time.sleep(30)
                if slskd_loggato():
                    print(time.strftime("%F %T"), "slskd scollegato da Soulseek: riavviato", flush=True)
                    del problemi["slskd"]
                else:
                    problemi["slskd"] += ": riavviato ma non si ricollega"

    nuovi, risolti = aggiorna(conta, avvisati, problemi)
    righe = fatti + nuovi + [f"risolto: {m}" for m in risolti]
    if righe:
        push("\n".join(righe))


def main():
    visti, conta, avvisati = set(), {}, {}
    while True:
        try:
            giro(visti, conta, avvisati)
        except Exception as e:  # noqa: BLE001 - un giro andato male non ferma la sentinella
            print("giro fallito:", repr(e), file=sys.stderr, flush=True)
        time.sleep(GIRO)


if __name__ == "__main__":
    main()
