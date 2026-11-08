"""Prova della logica pura della sentinella: python3 prova_sentinella.py"""
from sentinella import aggiorna, dipendenti, orfani, problemi_container

GLUETUN_ID = "g2"


def c(nome, running=True, net="home-net", finished="0001-01-01T00:00:00Z",
      restart="unless-stopped", restarting=False, health=None, exit_code=0):
    s = {"Running": running, "Restarting": restarting, "FinishedAt": finished,
         "ExitCode": exit_code}
    if health:
        s["Health"] = {"Status": health}
    return {"Id": nome + "-id", "Name": "/" + nome, "Created": "2026-10-29T12:05:01.3Z",
            "State": s, "HostConfig": {"NetworkMode": net, "RestartPolicy": {"Name": restart}}}


gluetun = c("gluetun")
gluetun["Id"] = GLUETUN_ID

# orfani: agganciato a un gluetun che non c'e' piu'
attaccato = c("qbittorrent", net="container:" + GLUETUN_ID)
orfano_vivo = c("audiobruh", net="container:g1")
orfano_morto_dopo = c("flaresolverr", running=False, net="container:g1",
                      finished="2026-10-29T12:06:07.2Z")
spento_prima = c("prowlarr", running=False, net="container:g1",
                 finished="2026-10-20T10:00:00Z")
trovati = [x["Name"] for x in orfani([gluetun, attaccato, orfano_vivo, orfano_morto_dopo, spento_prima])]
assert trovati == ["/audiobruh", "/flaresolverr"], trovati

# problemi_container: si fermano solo quelli visti girare e con una restart policy
visti = set()
assert problemi_container([c("jellyfin"), c("masiero", running=False)], visti) == {}
p = problemi_container([c("jellyfin", running=False, exit_code=137), c("masiero", running=False),
                        c("una-tantum", running=False, restart="no")], visti | {"una-tantum"})
assert list(p) == ["fermo:jellyfin"], p
p = problemi_container([c("plex", restarting=True), c("animehub", health="unhealthy")], set())
assert sorted(p) == ["malato:animehub", "riavvio:plex"], p

# aggiorna: avvisa al secondo giro di fila, "risolto" solo se aveva avvisato
conta, avvisati = {}, {}
assert aggiorna(conta, avvisati, {"x": "x rotto"}) == ([], [])
assert aggiorna(conta, avvisati, {"x": "x rotto"}) == (["x rotto"], [])
assert aggiorna(conta, avvisati, {"x": "x rotto"}) == ([], [])
assert aggiorna(conta, avvisati, {}) == ([], ["x rotto"])
assert aggiorna(conta, avvisati, {"y": "blip"}) == ([], [])
assert aggiorna(conta, avvisati, {}) == ([], [])  # sparito al primo giro: silenzio

# giro con slskd scollegato: se il riavvio lo ricollega niente push, altrimenti si'
import subprocess
import sentinella as s
spinte, riavvii, loggato = [], [], []
s.containers = lambda: [c("hasasierofy-slskd-1", net="bridge")]
s.problemi_server = lambda: {}
s.push = spinte.append
s.time.sleep = lambda _: None
s.sh = lambda *cmd, **kw: riavvii.append(cmd) or subprocess.CompletedProcess(cmd, 0)
s.slskd_loggato = lambda: loggato.pop(0)
stato = (set(), {}, {})
loggato += [False, False, True, True]  # giro 1, giro 2 + dopo il riavvio, giro 3
for _ in range(3):
    s.giro(*stato)
assert spinte == [] and len(riavvii) == 1, (spinte, riavvii)
loggato += [False, False, False, True]  # stavolta il riavvio non basta
for _ in range(3):
    s.giro(*stato)
assert spinte == ["slskd è scollegato da Soulseek: riavviato ma non si ricollega",
                  "risolto: slskd è scollegato da Soulseek: riavviato ma non si ricollega"], spinte

# dipendenti: chi vede il disco con un bind sotto di lui o un volume che ci punta
E = "/mnt/nas/Elements"


def m(nome, *mounts, running=True):
    x = c(nome, running=running, net="bridge")
    x["Mounts"] = [{"Type": t, "Source": src, "Name": n} for t, src, n in mounts]
    return x


cs = [m("plex", ("bind", E + "/Film", None), ("bind", "/mnt/nas/Seagate_Backup_Plus_Drive/Anime", None)),
      m("samba", ("bind", E, None)),
      m("minio", ("volume", "/var/lib/docker/volumes/minio_data/_data", "minio_data")),
      m("sentinella", ("bind", "/mnt/nas", None)),  # rslave: vede il rimontaggio da sola
      m("elementsfake", ("bind", E + "-bis", None)),
      m("spento", ("bind", E, None), running=False),
      m("redis", ("volume", "/var/lib/docker/volumes/redis/_data", "redis"))]
vol = {"minio_data": E + "/hasasierofy/minio_data", "redis": ""}
assert dipendenti(cs, E, vol) == ["plex", "samba", "minio"], dipendenti(cs, E, vol)

# giro col disco tornato: rimonta, riavvia chi lo usa, una push sola
spinte.clear()
riavvii.clear()
s.containers = lambda: cs
s.volumi = lambda cs: vol
s.os.path.ismount = lambda d: d != E
s.rimonta = lambda d: 0
s.giro(set(), {}, {})
assert [x[-1] for x in riavvii] == ["plex", "samba", "minio"], riavvii
assert spinte == [E + " si era staccato: l'ho rimontato e ho riavviato plex, samba, minio"], spinte

# rimontaggio fallito: una push subito (non al 2o giro), poi solo il "risolto".
# Al 2o giro lo script dell'host non riprova (4): il .mount e' fallito dopo il riaggancio.
spinte.clear()
esiti = [1, 4]
s.rimonta = lambda d: esiti.pop(0)
s.problemi_server = lambda: {"disco:" + E: E + " non è montato"}
stato = (set(), {}, {})
s.giro(*stato)
s.giro(*stato)
s.problemi_server = lambda: {}
s.os.path.ismount = lambda d: True
s.giro(*stato)
assert spinte == [E + " è tornato ma non riesco a rimontarlo (journalctl -u del suo .mount)",
                  "risolto: " + E + " è tornato ma non riesco a rimontarlo (journalctl -u del suo .mount)"], spinte

print("ok")
