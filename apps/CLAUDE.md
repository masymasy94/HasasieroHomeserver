# apps — piattaforma di deploy multi-app

Deploya app Docker Compose arbitrarie prese da un repo git, con reverse proxy e DNS già
cablati. Gli script stanno in `scripts/`, i cloni in `deployments/` (**gitignorati**: ognuno
ha il suo repo, non committarli da qui).

```bash
scripts/deploy.sh <repo-url-o-path> <nome-app>    # primo deploy
scripts/update.sh <nome-app>                      # aggiorna un deploy esistente
scripts/{status,logs,start,stop,remove}.sh <nome-app>
```

`update.sh` legge `.deploy-profiles` **nella radice dell'app deployata** (una riga per
profilo) ed esporta `COMPOSE_PROFILES`, così i servizi gated si ricreano anche loro.

## App deployate

| Nome | Repo | Note |
|---|---|---|
| `hasasierofy` | `masymasy94/Hasasierofy` | ha un suo `CLAUDE.md`: leggi quello |
| `dndproject` | `masymasy94/DnDSupportProject` | |

## Credenziali

Le credenziali dei cloni in `deployments/` stanno nella configurazione git locale, che è
esclusa dalla lettura (`permissions.deny` in `~/.claude/settings.json`). Non stamparle, non
copiarle nei file e non citarle nei commit: **questo repo è pubblico**.

## Homepage

`homepage/config/services.yaml` è la dashboard. Le tile qui non sono controllate da
nessuno: quando un servizio muore va rimossa a mano (la tile "Open WebUI" punta a un
servizio che non esiste più).
