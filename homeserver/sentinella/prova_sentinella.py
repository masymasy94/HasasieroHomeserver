"""Prova della logica pura della sentinella: python3 prova_sentinella.py"""
from sentinella import aggiorna, orfani, problemi_container

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

print("ok")
