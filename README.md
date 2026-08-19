# Display Transformer

Kleine native macOS-App, die einen Quellmonitor per ScreenCaptureKit erfasst,
per Core Animation dreht bzw. spiegelt und über eine
`AVSampleBufferDisplayLayer` vollflächig auf einem Zielmonitor anzeigt. Das
Bild bleibt proportional;
freie Flächen werden schwarz dargestellt. Es gibt keine Drittanbieterpakete,
Hilfsprozesse oder Daemons.

Für niedrigen Ressourcenverbrauch skaliert ScreenCaptureKit die Aufnahme
bereits auf die maximal benötigte Zielauflösung. Die Pipeline arbeitet mit
30 Bildern pro Sekunde, zwei Capture-Puffern und einem einzelnen
Latest-Frame-Slot; Quellframes werden daher weder in voller unnötiger
Auflösung noch in einer wachsenden Warteschlange gehalten. Unveränderte ScreenCaptureKit-Idle-Frames werden verworfen und lösen kein
erneutes Rendering aus. Auf macOS 13 oder neuer reicht der bevorzugte
`AVSampleBufferDisplayLayer`-Pfad den IOSurface-gestützten Capture-Puffer ohne
Core-Image-Bildkopie direkt von der seriellen Capture-Queue an Core Animation
weiter. AVFoundation-Backpressure verwirft Frames, statt sie anzustauen. Falls
dieser Pfad einen Frame nicht unterstützt, nicht rechtzeitig in den
Rendering-Status wechselt oder beim Rendern fehlschlägt, wechselt die laufende
Ausgabe dauerhaft auf den bisherigen Core-Image/CALayer-Pfad. Dessen
Core-Image-Kontext und 30-Hz-Timer werden erst dann erstellt.

## Voraussetzungen

- macOS 13 Ventura oder neuer
- Mac mit Metal-Unterstützung
- Xcode/Command Line Tools mit Swift 6
- mindestens zwei Monitore für eine laufende Ausgabe

## Bauen und testen

```bash
git clone https://github.com/trsdn/mac-display-transformer.git
cd mac-display-transformer
swift test
./build-app.sh
open "dist/Display Transformer.app"
```

Das Skript erstellt ein Release-App-Bundle unter
`dist/Display Transformer.app`. Es verwendet automatisch eine
verfügbare stabile Apple-Development- oder Developer-ID-Signatur; nur ohne
passende Identität fällt es mit einer Warnung auf eine Ad-hoc-Signatur zurück.
Das Bundle wird mit Hardened Runtime signiert; Developer-ID-Builds erhalten
zusätzlich einen sicheren Apple-Zeitstempel.
Eine Identität kann fest vorgegeben werden:

```bash
CODE_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./build-app.sh
```

Stabile Signatur, Bundle-ID und App-Pfad helfen macOS, die
Bildschirmaufnahme-Berechtigung nach Updates wiederzuerkennen.

## Bedienung

1. Eines der genau drei Presets auswählen.
2. Quell- und Zielmonitor wählen.
3. Die Drehung mit **0° / 90° / 180° / 270°** einstellen.
4. Optional **Horizontal spiegeln** und/oder **Vertikal spiegeln** aktivieren.
5. Die Konfiguration ausdrücklich mit
   **Aktuelle Konfiguration speichern** in den gewählten Slot schreiben.
6. Falls nötig **Zugriff anfordern** und die App unter
   **Systemeinstellungen → Datenschutz & Sicherheit → Bildschirmaufnahme**
   erlauben.
7. **Übertragung starten** anklicken.

**Stoppen**, `Esc` im Ausgabefenster oder `⌘.` beendet die Ausgabe. Dreh- und
Spiegeländerungen werden während einer laufenden Aufnahme live übernommen;
die Aufnahme wird dafür nicht neu gestartet. **Zurücksetzen** stellt 0° ohne
Spiegelung ein.

Neue Presets tragen die Namen `Preset 1`, `Preset 2` und `Preset 3`. Die Namen
sind direkt editierbar. Aus Kompatibilitätsgründen startet eine neue
Konfiguration mit der bisherigen Einstellung 180° plus horizontale Spiegelung.
Ein Preset-Wechsel lädt nur den gespeicherten Inhalt. Ungespeicherte Änderungen
werden sichtbar markiert und niemals still in einen Slot geschrieben.

## Transformation und Darstellung

Die Transformation erfolgt genau einmal in dieser Reihenfolge:

1. Drehung im Uhrzeigersinn
2. horizontale Spiegelung in den Achsen des bereits gedrehten Bildes
3. vertikale Spiegelung in denselben Achsen
4. Normalisierung, proportionale Einpassung und Zentrierung

Bei 90° und 270° werden Breite und Höhe vor der Seitenverhältnisberechnung
vertauscht. Dadurch sind Letterboxing und Pillarboxing auch bei Vierteldrehungen
korrekt. Der bevorzugte Ausgabepfad ist
**ScreenCaptureKit → `AVSampleBufferDisplayLayer`**. Als robuste Rückfallebene
bleibt **ScreenCaptureKit → Core Image → `CALayer`** verfügbar. Die App
verwendet weder `MTKView` noch eine Metal-Darstellungsfläche.

## Persistenz und Monitoridentität

Die App speichert per `UserDefaults` in einem versionierten Codable-Datensatz:

- aktiver Preset-Slot und alle drei Namen
- Quell- und Zielidentität pro Preset
- Drehung und beide Spiegeloptionen
- automatische Ausgabe beim App-Start

Eine gespeicherte Monitoridentität verwendet Hersteller-, Produkt- und
Seriennummer, sofern macOS sie liefert. Als eindeutiger Fallback dienen
lokalisierter Name und rotationsunabhängige native Pixelgröße. Die veränderliche
`CGDirectDisplayID` wird nur für die aktuelle Sitzung benutzt. Ist ein
gespeicherter Monitor getrennt, wird seine Identität nicht überschrieben.
Mehrdeutige Treffer werden aus Sicherheitsgründen nicht automatisch gewählt.

## Automatischer Start und Wiederverbinden

**Ausgabe beim App-Start automatisch starten** aktiviert die gewünschte
Ausgabe für das aktive, gespeicherte Preset. Fehlt Quelle oder Ziel, zeigt die
App einen ruhigen Wartestatus. Sie reagiert auf macOS-Monitorbenachrichtigungen
und startet automatisch, sobald beide Monitore eindeutig vorhanden sind; es
gibt kein periodisches Polling.

Wird ein benötigter Monitor während der Ausgabe getrennt, werden Aufnahme,
Render-Timer und Vollbildfenster sicher beendet. Nach dem Wiederverbinden
startet die Ausgabe automatisch neu. Ein manueller Stopp unterdrückt diesen
Neustart für die laufende App-Sitzung, bis **Übertragung starten** gedrückt oder
ein Preset neu geladen/gewechselt wird. Echte Aufnahmefehler und verweigerte
Berechtigungen lösen keine Neustartschleife aus.

## Start bei Anmeldung

**Bei Anmeldung starten** registriert die Haupt-App mit Apples unterstützter
API `SMAppService.mainApp`. Der angezeigte Status stammt direkt von
ServiceManagement; Registrierungsfehler oder eine noch ausstehende Freigabe in
den Systemeinstellungen werden sichtbar gemeldet.

Für einen zuverlässigen Anmeldestart sollte das signierte App-Bundle zuerst
nach `/Applications` verschoben und anschließend von dort registriert werden.
Die separate Option **Ausgabe beim App-Start automatisch starten** sorgt dafür,
dass beim Login-Start das aktive Preset automatisch ausgegeben beziehungsweise
auf seine Monitore gewartet wird.

## Automatisierter Ausgabetest

```bash
open -n "dist/Display Transformer.app" --args --self-test
```

`--self-test` wählt ohne Benutzereingriff den Monitor mit der größten nativen
physischen Pixelfläche als Quelle und den kleinsten anderen Monitor als Ziel.
Damit bleibt ein im HiDPI-Modus als 1920×1080 dargestellter 4K-Monitor die
größte Quelle. Sobald der gewählte Rendering-Pfad einen Frame darstellt, wird
`SELF_TEST_PASS` einschließlich `AVSampleBufferDisplayLayer` oder
`CoreImage/CALayer` protokolliert; nach 15 Sekunden ohne Frame erscheint
`SELF_TEST_FAIL`. Der Test verändert keine gespeicherten Presets und hat auf
normale Starts keinen Einfluss. Die Marker `RENDER_PATH=...` zeigen zusätzlich
mit niedriger Logfrequenz den tatsächlich gewählten Pfad.

## Einschränkungen

- DRM-/HDCP-geschützte Inhalte können von macOS schwarz ausgegeben werden.
- Audio wird nicht übertragen; der Quell-Mauszeiger wird erfasst.
- Die Latenz hängt von Auflösung, Bildwiederholrate und GPU ab.
- Der Zielmonitor bleibt technisch Teil des macOS-Schreibtischs.
- Seriennummernlose, vollkommen identische Monitore können ohne eindeutigen
  Namen bzw. Pixel-Fallback absichtlich eine manuelle Auswahl erfordern.
- Das Build-Skript erzeugt standardmäßig die aktuelle Mac-Architektur, kein
  Universal Binary.

## Fehlerbehebung

Bei schwarzer Ausgabe zuerst die Bildschirmaufnahme-Berechtigung prüfen, die
App vollständig beenden und aus demselben signierten Pfad neu öffnen. Falls von
einer Ad-hoc- auf eine stabile Signatur gewechselt wurde, kann ein einmaliger
Reset nötig sein:

```bash
tccutil reset ScreenCapture com.github.trsdn.DisplayTransformer
```
