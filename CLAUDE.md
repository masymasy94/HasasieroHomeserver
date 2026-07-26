# ~/Desktop/docker — radice dello sviluppo

Questa cartella **è** il repo `masymasy94/HasasieroHomeserver`. Contiene sia il suo
codice sia altri repo annidati e indipendenti.

| Cartella | Repo |
|---|---|
| `homeserver/`, `apps/`, `llm/` | parte di **questo** repo (HasasieroHomeserver) |
| `dmforge/` | repo separato `masymasy94/dmforge` |
| `audiobruh/` | repo separato `masymasy94/AudioBruh` |
| `hasasierogpt/` | repo separato `masymasy94/HasasieroGPT` |
| `apps/deployments/*` | cloni di deploy, **gitignorati** (hanno il loro repo) |

Conseguenza: un `git add -A` da qui non tocca i repo annidati, e viceversa. Ogni
progetto si committa dalla propria cartella.

## Avvia le sessioni dalla cartella del progetto

`cd dmforge && claude`, non `claude` da qui o da `~`. Partendo dalla radice si carica
solo questo file; il CLAUDE.md del progetto arriva soltanto quando Claude legge un file
lì dentro. Partire dal progetto carica entrambi e niente degli altri.

## Questa macchina

È **lei** l'homeserver: `192.168.3.54`, Ubuntu, 31 GiB RAM, GTX 1650 + iGPU Intel,
`/` da 233 GB e `/mnt/hdd` da 916 GB (i dati grossi dei container stanno su `/mnt/hdd`).
Il PC Windows `192.168.3.108` è il worker dei modelli locali (Ollama), spesso spento.

## Questo repo è PUBBLICO

`masymasy94/HasasieroHomeserver` è pubblico su GitHub: `homeserver/`, `apps/` e questo file
finiscono online a ogni push. `dmforge`, `audiobruh` e `hasasierogpt` sono privati.
Conseguenza: qui non vanno né segreti (i `.env` sono gitignorati, tienili così) né descrizioni
di falle aperte o credenziali da ruotare. Quelle stanno nelle note locali.

## Convenzioni

- Italiano nei commenti, nei doc e nei messaggi utente; codice minimale (niente
  astrazioni speculative, niente scaffolding "per dopo").
- Un container si deploya col compose del suo stack, non a mano con `docker run`.
- I dati persistenti vanno su `/mnt/hdd/<stack>/`, non dentro il repo.
