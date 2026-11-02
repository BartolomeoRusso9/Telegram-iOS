# Google Cast nel fork di Telegram-iOS

## Struttura

| Percorso | Ruolo |
| --- | --- |
| `third-party/googlecast/` | Import Bazel dell'SDK, scaricato da Google con sha256 fisso (`MODULE.bazel`) |
| `submodules/TelegramCast/` | Modulo isolato: sessioni, player remoto, server locale, logica SWITCH, pulsante, avviso aggiornamenti |
| `submodules/GalleryUI/Sources/Items/CastGalleryItemController.swift` | Collegamento tra il player del gallery e il modulo |
| `cast-receiver/index.html` | Custom Web Receiver |
| `scripts/cast/` | Controllo integrazione, merge da upstream, build IPA, test del server |
| `.github/workflows/` | `upstream-sync.yml` e `cast-build.yml` |

Il codice originale di Telegram riceve solo pochi punti d'aggancio, elencati in
`scripts/cast/check-integration.py`: se un aggiornamento ne rimuove uno, il controllo fallisce.

## Versione dell'SDK

Si usa la **4.8.4 statica**, l'ultima compatibile con iOS 15, il minimo di Telegram. La 4.8.6
richiede iOS 16 (verificato sugli oggetti compilati); passarci significa alzare
`minimum_os_version` in `Telegram/BUILD`, e aggiornare URL, `strip_prefix` e `sha256` in
`MODULE.bazel`. La 4.8.6 aggiunge il Wake-on-LAN per alcuni dispositivi.

La 4.8.4 mostra all'utente i Termini di Cast. Un rifiuto arriva come `GCKErrorCodeCancelled`:
Google vieta di ritentare automaticamente, e `TelegramCastPlayer` non ritenta.

## Receiver

Il receiver si sceglie **in fase di build**, perché il Cast context accetta una sola
configurazione per processo.

- **Default Media Receiver:** `CC1AD845`, predefinito.
- **Custom Web Receiver:**
  1. Pubblica `cast-receiver/index.html` su HTTPS.
  2. Registralo nella [Google Cast SDK Developer Console](https://cast.google.com/publish/) (quota
     di registrazione una tantum a Google) e registra anche il tuo Chromecast come dispositivo di test.
  3. In `Telegram/BUILD`, nel target `GoogleCastInfoPlist`, imposta
     `telegram_cast_receiver_app_id` con il tuo ID: la stessa variabile alimenta
     `TelegramCastReceiverApplicationID` e la voce `NSBonjourServices`.

Un ID malformato ricade sul Default Media Receiver.

## Build

Serve la versione di Xcode indicata in `versions.json`; il percorso del repository non deve
contenere spazi.

```bash
python3 build-system/Make/Make.py --cacheDir="$HOME/telegram-bazel-cache" build --disableProvisioningProfiles --configurationPath=<config.json> --codesigningInformationPath=build-system/fake-codesigning --buildNumber=1 --configuration=debug_sim_arm64
```

Per il simulatore la configurazione deve usare `bundle_id` e `team_id` di
`build-system/appstore-configuration.json`, gli unici che corrispondono ai profili fittizi.
Quei profili sono scaduti il 2026-10-30, perciò la build del simulatore li disattiva.

## Sideload con Apple ID gratuito

Non serve un account a pagamento: l'IPA viene rifirmato da uno strumento di sideload col tuo
Apple ID. Crea un file di configurazione fuori dal repository, copiando
`build-system/appstore-configuration.json` e inserendo il tuo `api_id` e `api_hash`, lasciando
`bundle_id` e `team_id` com'erano, poi:

```bash
bash scripts/cast/build-sideload-ipa.sh <config.json> 1
```

Il risultato è `output/Telegram-Cast-sideload.ipa`, che **non si installa da solo**: va aperto
con Sideloadly o AltStore. In Sideloadly attiva la rimozione delle estensioni: un Apple ID
gratuito ha limiti stretti sugli App ID.

Limiti di un Apple ID gratuito:

- La firma dura 7 giorni: poi va rifatto il sideload, e i dati restano se il bundle non cambia.
- Massimo 3 app sideloaded attive.
- Niente notifiche push: i messaggi arrivano solo ad app aperta.
- Niente condivisione verso Telegram, widget e altre estensioni, se rimosse.
- Un codice di accesso impostato in Telegram va verificato: dipende dal portachiavi rifirmato.

Il fallback di `SideloadAppContainer.swift` evita il blocco «Error 2» quando l'App Group non
coincide col bundle rifirmato.

## Generazione dell'IPA e firma Apple

1. Ottieni `api_id` e `api_hash` da <https://my.telegram.org/apps>.
2. Crea un App ID con bundle tuo, più uno per ogni estensione: `.Share`, `.SiriIntents`, `.Widget`,
   `.NotificationContent`, `.NotificationService`, `.BroadcastUpload`.
3. Crea un certificato `Apple Distribution` e i profili ad hoc o App Store. La cartella va
   strutturata come `build-system/fake-codesigning`: `certs/` e `profiles/<Nome>.mobileprovision`.
4. Copia `build-system/appstore-configuration.json` fuori dal repository e inserisci i tuoi dati.
5. Esegui:

```bash
bash scripts/cast/build-ipa.sh --configuration <config.json> --signing <cartella> --build-number 1
```

Il risultato è `output/Telegram-Cast.ipa` con `output/Telegram-Cast.xcarchive`. Con Bazel è
Telegram stesso a firmare e impacchettare l'IPA, quindi `xcodebuild -exportArchive` non serve:
l'archivio viene ricavato dall'IPA e contiene la stessa app.

Non esiste una modalità senza firma: `rules_apple` rifiuta un'app per dispositivo senza un
profilo valido. Per controllare compilazione e link release senza firma si può costruire il solo
framework:

```bash
python3 build-system/Make/Make.py --cacheDir="$HOME/telegram-bazel-cache" build --disableProvisioningProfiles --target=Telegram/TelegramUIFramework --configurationPath=<config.json> --codesigningInformationPath=build-system/fake-codesigning --buildNumber=1 --configuration=release_arm64
```

Spazio su disco misurato per una singola configurazione: circa 20-25 GB, più la cache.

`output/` non va mai committata: contiene binari firmati.

## Sincronizzazione con Telegram ufficiale

Rami del fork: `master` segue upstream, `cast/main` contiene le personalizzazioni ed è il ramo
di default.

Ogni giorno `upstream-sync.yml` confronta upstream con `cast/main`. Se ci sono novità crea
`sync/upstream-<sha>`, fa il merge lì, controlla l'integrazione e apre una Pull Request.
`cast/main` non viene mai toccato dal workflow, e non si usano rebase o push forzati: per
tornare indietro basta chiudere la PR o annullare il merge con `git revert -m 1`.

Il `build.yml` ereditato da upstream parte sui push a `master`, è fermo al 2023 e nel fork
fallirebbe: disattivalo in *Actions*.

### Risoluzione di un conflitto

Se il merge va in conflitto il workflow lo annulla e apre una Issue con i percorsi coinvolti.

```bash
git fetch upstream
git switch -c sync/manuale cast/main
git config rerere.enabled true
git merge upstream/master
```

Risolvi preservando sia il codice ufficiale sia gli agganci Cast, poi esegui
`python3 scripts/cast/check-integration.py`. Se Telegram ha riscritto un componente usato da Cast,
adatta `CastGalleryItemController.swift` invece di rimuovere l'integrazione.

Per riutilizzare una soluzione nelle sincronizzazioni future, committa `.git/rr-cache` copiandola
in `.rr-cache/`: il workflow risolve da solo solo i conflitti già risolti da una persona, e non
tenta mai di indovinare.

### GitHub Actions: cosa configurare

| Nome | Tipo | Scopo |
| --- | --- | --- |
| `SYNC_TOKEN` | Secret | Token con `contents`, `pull-requests`, `workflows`: senza, la PR non avvia `cast-build.yml` |
| `TELEGRAM_API_ID`, `TELEGRAM_API_HASH` | Secret | Credenziali Telegram |
| `BUILD_CONFIGURATION_JSON` | Secret | Il JSON di configurazione della build firmata |
| `SIGNING_ARCHIVE_BASE64` | Secret | `tar -cz certs profiles \| base64`; `certs/distribution.p12` è obbligatorio |
| `SIGNING_CERTIFICATE_PASSWORD` | Secret | Password del `.p12` |
| `CAST_BUILD_RUNNER` | Variabile | Etichetta di un Mac self-hosted |

Una build completa richiede molto più disco di quello dei runner GitHub ospitati, ed è
necessaria la stessa versione di Xcode di `versions.json`: serve quasi certamente un Mac
self-hosted. Nessun certificato deve stare nel repository.

## Test dopo ogni aggiornamento

**Automatici**, in CI: `check-integration.py`, `scripts/cast/test-local-server.sh`, build per
simulatore. Il server locale viene provato con richieste HTTP reali: GET, HEAD, Range, 206,
416, 405, token errato, path traversal, concorrenza, header oversize, blocco del secondo client.

**Manuali**, serve un dispositivo Cast reale, che la CI non ha:

- [ ] Il pulsante compare nel player, apre il selettore, mostra lo stato su iPhone e iPad
- [ ] Permesso «Rete locale»: concessione e rifiuto
- [ ] Video Telegram già scaricato (MP4)
- [ ] Video Telegram non ancora scaricato
- [ ] Video con qualità multiple
- [ ] URL esterno MP4 e HLS
- [ ] Il player locale si ferma solo quando la TV riproduce
- [ ] Trasferimento fallito: il video locale continua
- [ ] Pausa, ripresa, seek, stop
- [ ] Disconnessione improvvisa: ripresa locale dalla posizione corretta
- [ ] Default Media Receiver e Custom Web Receiver
- [ ] Video segreto o protetto dalla copia: il pulsante non deve comparire

Un aggiornamento va unito solo dopo questa lista.

## Comportamento e limiti

- Il pulsante non compare per media segreti o protetti dalla copia, che non devono uscire dal telefono.
- Il server locale serve un solo video, con token casuale a 256 bit, solo GET e HEAD, e dopo il
  primo client valido accetta solo quell'indirizzo IP. Il traffico è HTTP in chiaro sulla LAN:
  chi osserva la rete può vedere il video, come per ogni sender Cast con media locali.
- Se il video lascia lo schermo la trasmissione termina, perché i byte smettono di essere serviti.
- URL esterni con cookie, autenticazione, DRM o CORS restrittivo non sono supportati.
- Testi di errore e avviso aggiornamento sono solo in inglese, per non toccare il sistema di localizzazione di Telegram.

## Distribuzione delle nuove versioni

Aggiornare il **codice del fork** non aggiorna l'**app sull'iPhone**: serve una nuova build firmata
installata attraverso un canale Apple.

| Canale | Adatto a | Limiti |
| --- | --- | --- |
| Ad hoc | Uso personale, pochi dispositivi | UDID registrati, massimo 100 per tipo; installazione manuale |
| TestFlight | Gruppo ristretto | Revisione per i tester esterni; build valide 90 giorni |
| App Store | Pubblico | Revisione Apple; le regole su nome e logo di Telegram sono vincolanti |
| Enterprise / MDM | Solo organizzazioni idonee | Vietato distribuire al pubblico |

**Scelta consigliata:** ad hoc per uso personale, TestFlight se ci sono altri utenti.

L'app può avvisare, ma non aggiornarsi da sola. Per attivare l'avviso pubblica un JSON via HTTPS
e imposta `telegram_cast_update_feed_url` in `Telegram/BUILD`:

```json
{
  "version": "13.1.2",
  "build": 42,
  "releaseDate": "2026-11-02",
  "notes": "Allineato a Telegram ufficiale.",
  "url": "https://example.com/release"
}
```

Con il valore vuoto predefinito l'app non effettua alcuna richiesta.

## Licenze

Questo non è un parere legale. Telegram-iOS è GPLv2, mentre l'SDK Cast è proprietario e soggetto
ai termini Google: **distribuire a terzi** un binario che li combina può porre un problema di
compatibilità delle licenze. Valutalo prima di distribuire oltre l'uso personale. Telegram
chiede inoltre di pubblicare il proprio codice, usare un `api_id` proprio, non usare il suo logo
e chiarire che l'app non è ufficiale.
