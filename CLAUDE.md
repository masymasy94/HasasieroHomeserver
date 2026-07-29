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

## Segreti: SOPS + age

I `.env` in chiaro restano sul disco (gitignorati) ma la copia autorevole è cifrata:
`<stack>/env.sops.yaml`, con chiave age. La privata è in `~/.config/sops/age/keys.txt` (600) e
Claude non può leggerla; la pubblica sta in `.sops.yaml`.

```bash
sops exec-env homeserver/env.sops.yaml 'docker compose up -d'   # deploy: i valori vanno
                                                                # nell'ambiente, non a schermo
sops edit homeserver/env.sops.yaml                              # modificare un segreto
sops -e --input-type dotenv --output-type yaml X/.env > X/env.sops.yaml   # cifrare un nuovo stack
```

- **Mai `sops -d`**: stamperebbe i segreti nel transcript. Un hook `PreToolUse` lo blocca e
  suggerisce `exec-env`. Se ti serve davvero il testo in chiaro, lancialo tu con `! sops -d ...`.

### Deploy che hanno bisogno del vault, lanciati da Claude

La sandbox nega a Claude `~/.config/sops/age/keys.txt`, quindi un `sops exec-env` diretto
fallisce con *"failed to load age identities"*. La via che funziona, e che va usata invece di
rimbalzare il comando all'utente: farlo girare in un container usa-e-getta che monta la chiave.
A leggerla è il daemon, non Claude, e in chiaro non passa niente né a schermo né su disco.

```bash
docker run --rm \
  -v /home/masy/.config/sops/age/keys.txt:/keys/keys.txt:ro \
  -v /home/masy/Desktop/docker:/home/masy/Desktop/docker \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e SOPS_AGE_KEY_FILE=/keys/keys.txt \
  -w /home/masy/Desktop/docker/homeserver \
  --entrypoint sh homeserver-secrets-ui:latest \
  -c "sops exec-env env.sops.yaml 'docker compose up -d --force-recreate <servizio>'"
```

Funziona perché l'immagine `homeserver-secrets-ui` ha già dentro `sops`, il client docker e
compose. Due vincoli non negoziabili: `-w` e il mount della radice devono usare il **medesimo
path dell'host** (i bind mount relativi del compose li risolve il client, e da un path diverso
compose monterebbe directory inventate), e il comando non deve **mai** stampare il chiaro —
`exec-env` sì, `sops -d` no.
- `env.sops.yaml` **non** è committato in questo repo perché è pubblico: pubblicare il
  cifrato di una chiave WireGuard è un rischio che non vale la pena. Nei repo privati
  (dmforge) invece è versionato, ed è lì che SOPS dà il suo meglio.
- Un hook `pre-commit` globale (`~/.config/git/hooks/`, `core.hooksPath`) passa `gitleaks` su
  ogni commit di **ogni** repo della macchina e lo blocca se trova una credenziale. I falsi
  positivi si silenziano per fingerprint in `.gitleaksignore`.

## Convenzioni

- Italiano nei commenti, nei doc e nei messaggi utente; codice minimale (niente
  astrazioni speculative, niente scaffolding "per dopo").
- Un container si deploya col compose del suo stack, non a mano con `docker run`.
- I dati persistenti vanno su `/mnt/hdd/<stack>/`, non dentro il repo.
