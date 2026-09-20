# zeit.koplugin

Ein [KOReader](https://koreader.rocks/)-Plugin, mit dem du dich mit deinem
**ZEIT+**-Abo anmeldest und einzelne zeit.de-Artikel (Volltext, inklusive
Bilder) als EPUB herunterlädst – zum bequemen Lesen auf deinem E-Reader statt
auf dem Handy.

## Funktionsweise

1. **Anmelden**: Das Plugin schickt E-Mail und Passwort an
   `https://meine.zeit.de/anmelden` und speichert das dabei gesetzte
   Session-Cookie.
2. **Artikel herunterladen**: Entweder fügst du die URL eines zeit.de-Artikels
   direkt ein, oder du stöberst dich über die konfigurierten Übersichtsseiten
   zum Artikel durch. Das Plugin lädt die Seite mit dem gespeicherten
   Session-Cookie (wodurch ZEIT+-Inhalte freigeschaltet werden statt der
   Bezahlschranken-Vorschau), extrahiert den Artikeltext samt Bildern und
   packt daraus ein EPUB in deinen Downloads-Ordner.
3. **Ganze Ausgabe herunterladen**: Für den Link einer Ausgabe auf
   `epaper.zeit.de` (z. B. `https://epaper.zeit.de/abo/diezeit/17.09.2026`)
   lädt das Plugin stattdessen direkt das von ZEIT selbst erzeugte,
   fertige EPUB der gesamten Ausgabe herunter (über den „EPUB“-Button auf
   dieser Seite, technisch ein Link auf `media-delivery.zeit.de`) – ganz
   ohne eigene Text-Extraktion.

**In der App (Menü → ZEIT+): „Stöbern“** zeigt die in den Einstellungen
hinterlegten Quellen (Startseite, ZEIT+-exklusive Artikel, Ausgaben des
Jahres, …) als Menüs an: RSS/Atom-Feeds werden als Artikelliste angezeigt,
HTML-Übersichtsseiten wie `zeit.de/index` werden nach Artikel- und weiteren
Überblicks-Links (z. B. eine bestimmte Wochenausgabe) durchsucht, in die du
weiter hineintippen kannst. Antippen eines Artikels lädt ihn direkt als EPUB
herunter – die Liste bleibt dabei offen, sodass du mehrere Artikel
nacheinander auswählen kannst, ohne jedes Mal eine URL abzutippen oder zu
teilen.

## Installation

1. Repo-Inhalt nach `koreader/plugins/zeit.koplugin/` kopieren (der
   Ordnername `zeit.koplugin` ist wichtig, damit KOReader das Plugin
   erkennt).
2. KOReader neu starten.
3. Im Hauptmenü erscheint ein neuer Eintrag **„ZEIT+“**.

## Nutzung

Das Plugin öffnet sich als **eigene, vollbild‑„App“** (Menü → **ZEIT+**)
mit der DIE‑ZEIT‑Kopfzeile und dem Abo‑Status:

- **Stöbern** → konfigurierte Übersichtsseiten (Startseite, ZEIT+‑Artikel,
  Ausgaben des Jahres, …); Artikel antippen lädt sie direkt als EPUB.
- **Ausgaben des Jahres** → direkt zu den Wochenausgaben des aktuellen
  Jahres (`zeit.de/<Jahr>/index`), von dort in eine Ausgabe und weiter zu
  deren Artikeln.
- **Meine Artikel** → die bereits heruntergeladenen EPUBs im Zielordner
  (neueste zuerst); antippen öffnet sie im Reader, lange drücken löscht sie.
- **Link hinzufügen** → Artikel‑URL, `epaper.zeit.de`‑Ausgabenlink oder
  direkten EPUB‑Link einfügen; das EPUB landet im eingestellten Zielordner
  (Standard: `<koreader-daten>/zeitplus/`).
- **Downloads‑Ordner öffnen** verlässt die App und öffnet den Ordner im
  Dateimanager.
- **Einstellungen** erlaubt das Laden der Session‑Cookies, das Ändern des
  Zielordners, der Stöbern‑Quellen, das Ein‑/Ausschalten von Bildern sowie
  das Anpassen der CSS‑Selektoren zur Artikel‑Erkennung (siehe unten).
- Der unterste Eintrag zeigt den Anmeldestatus; antippen meldet ab bzw.
  lädt die Session‑Cookies aus der Datei.

Innerhalb der App navigierst du wie im Dateimanager: Das „X“ (oder Wischen
nach Süden) führt eine Ebene zurück, das Home‑Symbol links oben springt
zurück zum Startbildschirm.

## Hinweis zum Login: Session-Cookies per SSH einfügen (empfohlen)

Der automatische E-Mail/Passwort-Login des Plugins funktioniert derzeit
**nicht mehr**: ZEIT hat die Anmeldung auf ein OpenID-Connect-/Keycloak-SSO
(`login.zeit.de`) umgestellt und blockt zusätzlich automatisierte Logins mit
einem „Bitte bestätigen Sie, dass Sie kein Roboter sind“-Gate. E-Mail und
Passwort sind also nicht das Problem – der Login-Abgriff aus einem Skript
heraus ist es.

Der zuverlässige Weg ist daher, **einmal im Browser anzumelden und die
Session-Cookies ins Plugin zu legen** – ganz ohne Tippen auf dem E-Reader:

1. Auf dem Gerät KOReaders **SSH-Server** aktivieren (Menü → Hilfe →
   „SSH-Server starten“) – du bekommst dann eine IP sowie
   Login/Passwort angezeigt.
2. Am Rechner verbinden: `ssh root@<IP>` (Passwort aus dem KOReader-Menü).
3. Im Browser (am Rechner oder Handy) unter `https://www.zeit.de` anmelden.
   Dann Entwicklertools (F12) → **Application → Cookies → www.zeit.de**
   öffnen und die Werte der beiden Cookies **`zeit_sso_201501`** und
   **`zeit_sso_session_201501`** kopieren.
4. Auf dem Reader die Datei `koreader/settings/zeitplus_cookies.txt`
   öffnen (fällt der Menüpunkt im Plugin an, wird eine Vorlage angelegt)
   – z. B. mit `vi` oder besser per `scp` vom Rechner:

   ```
   scp zeitplus_cookies.txt root@<IP>:/mnt/us/koreader/settings/
   ```

   Format: eine `name=value`-Zeile pro Cookie (leere Zeilen und `#`-Kommentare
   werden ignoriert).
5. Im Plugin **ZEIT+ → Einstellungen → Session-Cookies laden (Datei)**
   antippen (bzw. einfach den untersten Eintrag „Nicht angemeldet“). Die
   App zeigt danach „Angemeldet als: <deine E-Mail>“.

Haltbarkeit: Das Cookie `zeit_sso_201501` ist ca. **1 Jahr** gültig, das
Session-Cookie `zeit_sso_session_201501` nur **etwa 3 Tage**. Läuft es ab,
landen Artikel wieder hinter der Bezahlschranke; dann Schritt 3–5 einfach
wiederholen.

## Hinweis zu den Stöbern-Quellen

Als Standard sind drei Quellen hinterlegt (unter **ZEIT+ → Einstellungen →
Quellen zum Stöbern anpassen** änderbar, eine Zeile pro Quelle im Format
`Name = URL`):

- `Übersicht` → `https://www.zeit.de/index` (aktuelle Artikel)
- `Nur ZEIT+` → `https://www.zeit.de/exklusive-zeit-artikel`
- `Ausgaben des Jahres` → `https://www.zeit.de/<aktuelles Jahr>/index`
  (führt zu den einzelnen Wochenausgaben, aus denen wiederum die
  einzelnen Artikel gewählt werden können)

Diese Seiten konnten in der Entwicklungsumgebung, in der dieses Plugin
gebaut wurde, nicht gegen das echte `zeit.de` getestet werden (siehe
Hinweis zu den Artikel-Selektoren unten) – die Erkennung von Artikel- bzw.
Unterordner-Links basiert auf der üblichen zeit.de-URL-Struktur
(`/ressort/JJJJ-MM/…` bzw. `/JJJJ/Ausgabe/…` für Artikel, `/…/index` für
weitere Übersichtsseiten). Falls eine Quelle leer bleibt oder Fehler zeigt,
prüfe die URL im Browser und passe sie ggf. an; unterstützt werden neben
solchen HTML-Übersichtsseiten auch klassische RSS-2.0- und Atom-Feeds
(z. B. von der [ZEIT-Feed-Übersicht](https://www.zeit.de/rss-index)).

## Hinweis zu epaper.zeit.de / ganzen Ausgaben

Ein Link auf eine `epaper.zeit.de`-Ausgabenseite (z. B.
`https://epaper.zeit.de/abo/diezeit/17.09.2026`) wird nicht wie ein
Artikel behandelt: Das Plugin sucht auf dieser Seite nach dem
„EPUB“-Download-Link (`media-delivery.zeit.de/….epub`) und lädt dieses
von ZEIT selbst erzeugte EPUB direkt herunter. Auch ein direkt
eingefügter `media-delivery.zeit.de/….epub`-Link wird sofort
heruntergeladen. Auch dieser Mechanismus konnte mangels Netzwerkzugriff
auf `zeit.de` aus der Entwicklungsumgebung heraus nicht gegen die echte
Seite getestet werden.

## Wichtiger Hinweis zu den Artikel-Selektoren

Das Plugin extrahiert den Artikeltext über eine Liste möglicher CSS-Selektoren
(`article`, `div.article-body`, `div[itemprop='articleBody']`, …) – ähnlich
wie KOReaders eingebautes NewsDownloader-Plugin. Da `zeit.de` aus der
Entwicklungsumgebung, in der dieses Plugin gebaut wurde, nicht erreichbar
war, konnten diese Selektoren **nicht gegen das echte (eingeloggte) Markup
von zeit.de getestet werden**.

Falls nach der Anmeldung weiterhin nur eine Kurzvorschau statt des
Volltexts im EPUB landet:

1. Öffne einen ZEIT+-Artikel eingeloggt in einem Desktop-Browser.
2. Öffne die Entwicklertools (Rechtsklick → „Untersuchen“) und finde das
   Element, das den Artikeltext umschließt (Klasse oder Tag, z. B.
   `div.article-body`).
3. Trage den Selektor unter **ZEIT+ → Einstellungen → Artikel-Selektoren
   anpassen** ein (kommagetrennt, mehrere Kandidaten möglich).
4. Störende Elemente (Social-Buttons, Kommentare, Newsletter-Boxen) lassen
   sich analog unter „Auszuschließende Elemente anpassen“ ausschließen.

Das Plugin warnt zusätzlich, wenn der heruntergeladene Artikel noch typische
Bezahlschranken-Texte enthält (z. B. „Diesen Artikel weiterlesen“) – das
deutet meist auf eine abgelaufene Anmeldung oder eine geänderte Seitenstruktur
hin.

## Sicherheitshinweis

E-Mail und Passwort werden – wie bei anderen KOReader-Plugins mit
Login (z. B. Wallabag) üblich – unverschlüsselt in
`<koreader-daten>/settings/zeitplus.lua` auf dem Gerät gespeichert. Nutze das
Plugin nur auf Geräten, denen du vertraust.

## Nutzungsbedingungen

Dieses Plugin automatisiert lediglich den Login- und Abruf-Vorgang mit
*deinem eigenen* ZEIT+-Abo, so wie es ein Browser auch täte. Die Nutzung
liegt in deiner Verantwortung; bitte beachte die Nutzungsbedingungen von
ZEIT ONLINE.

## Technische Basis

Die HTTP-/Cookie-/EPUB-Logik in `zeitapi.lua` ist an KOReaders eigenes
[`newsdownloader.koplugin`](https://github.com/koreader/koreader/tree/master/plugins/newsdownloader.koplugin)
angelehnt (AGPL-3.0, wie KOReader selbst), das genau dieses Muster – Login
per Cookie, HTML-Abruf, EPUB-Erzeugung inklusive Bildern – bereits produktiv
nutzt.
