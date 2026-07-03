# FHEM-WhatsAppMCP

FHEM-Modul zur Integration des [whatsapp-mcp](https://github.com/michael171185-coder/whatsapp-mcp) Servers.

## Voraussetzungen

* FHEM >= 5.8
* [whatsapp-mcp](https://github.com/michael171185-coder/whatsapp-mcp) Server läuft und ist erreichbar
* Perl-Modul: `JSON` (meist bereits in FHEM enthalten)

## Installation

### Option 1: Direkt aus GitHub (empfohlen)

In FHEM:
```
update add https://raw.githubusercontent.com/michael171185-coder/FHEM-WhatsAppMCP/main/controls_WhatsAppMCP.txt
update
```

### Option 2: Manuell

`FHEM/74_WhatsAppMCP.pm` ins FHEM-Verzeichnis kopieren und in FHEM:
```
reload 74_WhatsAppMCP
```

## Konfiguration

```
# Gerät anlegen (URL = MCP-Port 8000)
define WA WhatsAppMCP http://whatsapp-mcp:8000

# Extern erreichbar:
define WA WhatsAppMCP http://192.168.1.100:8092

# Optionale Attribute
attr WA defaultRecipient 4917612345678@s.whatsapp.net
attr WA pollInterval 60
attr WA maxMessages 20
```

## Verwendung

### Nachrichten senden

```perl
# Einzelperson (Telefonnummer oder JID)
set WA msg 4917612345678 Hallo von FHEM!
set WA msg 4917612345678@s.whatsapp.net Test

# Gruppe
set WA msg_group 491234567890-1234567890@g.us Gruppenalarm!

# In Perl (z.B. in notify/at/DOIF)
fhem("set WA msg 4917612345678 Temperatur: " . ReadingsVal("Thermometer","temperature","?") . "°C");
```

### Nachrichten empfangen

```
# Letzten Chat abrufen
get WA messages

# Nachrichten eines bestimmten Chats
get WA messages 4917612345678@s.whatsapp.net

# Chats auflisten
get WA chats

# Kontakt suchen
get WA contacts Maike
```

### Automatisches Polling (eingehende Nachrichten)

```
attr WA pollInterval 30
```

Dann wird alle 30 Sekunden nach neuen Nachrichten geschaut. Bei einer neuen Nachricht werden die Readings `lastRecv`, `lastRecvSender`, `lastRecvContent` etc. aktualisiert.

Mit `notify` darauf reagieren:
```
define n_WA notify WA:lastRecvContent.* {
  my $msg = ReadingsVal("WA","lastRecvContent","");
  my $from = ReadingsVal("WA","lastRecvSender","");
  Log 3, "WhatsApp von $from: $msg";
  # FHEM-Befehl aus WhatsApp ausführen (Vorsicht!)
  # fhem($msg) if($from eq "4917612345678@s.whatsapp.net");
}
```

## Readings

| Reading | Beschreibung |
|---|---|
| `state` | `connected` / `disconnected` / `initialized` |
| `connected` | `yes` oder `error: ...` |
| `lastSent` | Zeitstempel \| Empfänger \| Nachricht |
| `lastSentTo` | JID des letzten Empfängers |
| `lastSentMsg` | Text der letzten gesendeten Nachricht |
| `lastRecv` | Zeitstempel \| Absender: Text |
| `lastRecvSender` | JID des letzten Absenders |
| `lastRecvContent` | Text der letzten empfangenen Nachricht |
| `lastRecvChat` | Chat-JID der letzten Nachricht |
| `chatCount` | Anzahl abgerufener Chats |
| `chatList` | Liste der letzten Chats |
| `searchResults` | Ergebnisse der letzten Kontaktsuche |
| `lastHistorySync` | Zeitpunkt des letzten History-Syncs |
| `lastError` | Letzter Fehler |

## Attribute

| Attribut | Default | Beschreibung |
|---|---|---|
| `pollInterval` | 0 | Sekunden zwischen Abfragen (0 = kein Polling) |
| `defaultRecipient` | - | Standard-Empfänger für `set msg` |
| `maxMessages` | 20 | Max. Nachrichten beim Abruf |
| `disable` | 0 | Modul deaktivieren |

## Beispiel-Szenarien

### Alarm bei Bewegungsmelder
```
define n_WA_PIR notify PIR:motion {fhem("set WA msg 4917612345678 Bewegung erkannt!")}
```

### Temperatur-Report
```
define at_WA_Temp at *08:00 {fhem("set WA msg 4917612345678 Guten Morgen! Temperatur: " . ReadingsVal("Thermometer","temperature","?") . "°C")}
```

### Heizung per WhatsApp steuern
```
define n_WA_Cmd notify WA:lastRecvContent.heizung.* {
  my $msg = lc(ReadingsVal("WA","lastRecvContent",""));
  my $from = ReadingsVal("WA","lastRecvSender","");
  # Nur von bekannter Nummer
  if($from eq "4917612345678@s.whatsapp.net") {
    if($msg =~ /heizung an/)  { fhem("set Heizung desired-temp 21"); }
    if($msg =~ /heizung aus/) { fhem("set Heizung desired-temp 16"); }
  }
}
```

## whatsapp-mcp Server

Der zugehörige Server-Fork mit Dockerfile und allen Patches:
→ [github.com/michael171185-coder/whatsapp-mcp](https://github.com/michael171185-coder/whatsapp-mcp)

## Lizenz

GPL v2 oder höher (wie FHEM)
