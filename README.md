# zeit.koplugin

Ein [KOReader](https://koreader.rocks/)-Plugin, mit dem du dich mit deinem
**ZEIT+**-Abo anmeldest und einzelne zeit.de-Artikel (Volltext, inklusive
Bilder) als EPUB herunterlädst – zum bequemen Lesen auf deinem E-Reader statt
auf dem Handy.

## Funktionsweise

1. **Anmelden**: Das Plugin schickt E-Mail und Passwort an
   `https://meine.zeit.de/anmelden` und speichert das dabei gesetzte
   Session-Cookie.
2. **Artikel herunterladen**: Du fügst die URL eines zeit.de-Artikels ein.
   Das Plugin lädt die Seite mit dem gespeicherten Session-Cookie (wodurch
   ZEIT+-Inhalte freigeschaltet werden statt der Bezahlschranken-Vorschau),
   extrahiert den Artikeltext samt Bildern und packt daraus ein EPUB in
   deinen Downloads-Ordner.

Das Plugin lädt keine Übersicht/Feed automatisch – du fügst Artikel gezielt
über ihre URL hinzu (z. B. per Link-Teilen von Handy/Browser, oder indem du
die URL abtippst/einfügst).

## Installation

1. Repo-Inhalt nach `koreader/plugins/zeit.koplugin/` kopieren (der
   Ordnername `zeit.koplugin` ist wichtig, damit KOReader das Plugin
   erkennt).
2. KOReader neu starten.
3. Im Hauptmenü erscheint ein neuer Eintrag **„ZEIT+“**.

## Nutzung

- **ZEIT+ → Nicht angemeldet** antippen → E-Mail und Passwort eingeben.
- **ZEIT+ → Artikel-URL hinzufügen** → Artikel-URL einfügen → Download läuft,
  EPUB landet im eingestellten Zielordner (Standard:
  `<koreader-daten>/zeitplus/`).
- **ZEIT+ → Downloads-Ordner öffnen** öffnet diesen Ordner im Dateimanager.
- **ZEIT+ → Einstellungen** erlaubt das Ändern des Zielordners, das
  Ein-/Ausschalten von Bildern sowie das Anpassen der CSS-Selektoren zur
  Artikel-Erkennung (siehe unten).

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
