##############################################################################
# 74_WhatsAppMCP.pm
#
# FHEM-Modul zur Integration des whatsapp-mcp Servers.
# Ermoeglicht das Senden und Empfangen von WhatsApp-Nachrichten direkt
# aus FHEM heraus ueber die REST-API des whatsapp-mcp Containers.
#
# Funktionen:
#   * Nachrichten senden (Einzel- und Gruppenempfaenger)
#   * Kontakte suchen
#   * Nachrichten-History lesen
#   * Eingehende Nachrichten als FHEM-Readings empfangen (Polling)
#   * History-Sync ausloesen
#
# Voraussetzungen:
#   * whatsapp-mcp Server (github.com/michael171185-coder/whatsapp-mcp)
#     laeuft und ist per HTTP erreichbar
#   * Perl-Module: HttpUtils (FHEM-intern), JSON
#
# Konfiguration:
#   define <name> WhatsAppMCP <url>
#   Beispiel: define WA WhatsAppMCP http://whatsapp-mcp:8000
#
# Autor:    ahlers2mi (basierend auf FHEM-MCP Struktur)
# Version:  v0.1.0
# Lizenz:   GPL v2 oder hoeher (wie FHEM)
##############################################################################

package main;

use strict;
use warnings;
use JSON;
use HttpUtils;

use vars qw($readingFnAttributes $init_done %defs %attr);

# ------------------------------------------------------------------
# WhatsAppMCP_Initialize
# ------------------------------------------------------------------
sub WhatsAppMCP_Initialize {
    my ($hash) = @_;

    $hash->{DefFn}    = \&WhatsAppMCP_Define;
    $hash->{UndefFn}  = \&WhatsAppMCP_Undef;
    $hash->{SetFn}    = \&WhatsAppMCP_Set;
    $hash->{GetFn}    = \&WhatsAppMCP_Get;
    $hash->{AttrFn}   = \&WhatsAppMCP_Attr;

    $hash->{AttrList} =
        "disable:1,0 " .
        "pollInterval " .         # Sekunden zwischen Nachrichten-Abfragen (0 = kein Polling)
        "defaultRecipient " .     # Standard-Empfaenger (JID oder Telefonnummer)
        "notifyReading:1,0 " .    # eingehende Nachrichten als Reading speichern
        "maxMessages " .          # max. Anzahl beim Abrufen von Nachrichten (Default 20)
        $readingFnAttributes;
}

# ------------------------------------------------------------------
# WhatsAppMCP_Define   "define <name> WhatsAppMCP <url>"
# ------------------------------------------------------------------
sub WhatsAppMCP_Define {
    my ($hash, $def) = @_;
    my @param = split('[ \t]+', $def);

    return "Usage: define <name> WhatsAppMCP <url>\n" .
           "Beispiel: define WA WhatsAppMCP http://whatsapp-mcp:8000"
        if(int(@param) != 3);

    $hash->{URL}      = $param[2];
    $hash->{FVERSION} = "74_WhatsAppMCP.pm:v0.1.0";

    readingsBeginUpdate($hash);
    readingsBulkUpdateIfChanged($hash, "state",    "initialized");
    readingsBulkUpdateIfChanged($hash, "lastSent",  "---");
    readingsBulkUpdateIfChanged($hash, "lastRecv",  "---");
    readingsBulkUpdateIfChanged($hash, "connected", "unknown");
    readingsEndUpdate($hash, 0);

    # Verbindungstest beim Start
    InternalTimer(gettimeofday() + 2, "WhatsAppMCP_CheckConnection", $hash, 0);

    return undef;
}

sub WhatsAppMCP_Undef {
    my ($hash, $name) = @_;
    RemoveInternalTimer($hash);
    return undef;
}

# ------------------------------------------------------------------
# WhatsAppMCP_Set
# ------------------------------------------------------------------
sub WhatsAppMCP_Set {
    my ($hash, $name, $cmd, @args) = @_;
    return "\"set $name\" braucht mindestens ein Argument" if(!defined($cmd));

    my $list =
        "msg " .
        "msg_group " .
        "historysync:noArg " .
        "connect:noArg";

    # ---------- msg <empfaenger> <nachricht> ----------
    if($cmd eq "msg") {
        my $recipient = shift(@args);
        my $message   = join(" ", @args);

        # Fallback auf defaultRecipient
        if(!defined($recipient) || $recipient eq "") {
            $recipient = AttrVal($name, "defaultRecipient", "");
            return "Kein Empfaenger angegeben und kein defaultRecipient gesetzt."
                if($recipient eq "");
            # Wenn recipient fehlt, sind alle args die Nachricht
            $message = join(" ", ($recipient_was_empty_so_all_args_are_msg = $recipient, @args)) if(0);
        }

        return "Nachricht darf nicht leer sein." if(!defined($message) || $message eq "");

        # Telefonnummer -> JID konvertieren
        $recipient = WhatsAppMCP_toJID($recipient, 0);

        WhatsAppMCP_SendMessage($hash, $recipient, $message);
        return undef;
    }

    # ---------- msg_group <gruppen-jid> <nachricht> ----------
    if($cmd eq "msg_group") {
        my $recipient = shift(@args);
        my $message   = join(" ", @args);

        return "Gruppen-JID erforderlich (z.B. 491234567890-1234567890\@g.us)"
            if(!defined($recipient) || $recipient eq "");
        return "Nachricht darf nicht leer sein."
            if(!defined($message) || $message eq "");

        # Gruppe hat kein @g.us? Ergaenzen.
        $recipient .= "\@g.us" if($recipient !~ /\@/);

        WhatsAppMCP_SendMessage($hash, $recipient, $message);
        return undef;
    }

    # ---------- historysync ----------
    if($cmd eq "historysync") {
        WhatsAppMCP_HistorySync($hash);
        return undef;
    }

    # ---------- connect ----------
    if($cmd eq "connect") {
        WhatsAppMCP_CheckConnection($hash);
        return undef;
    }

    return "Unknown argument $cmd, choose one of $list";
}

# ------------------------------------------------------------------
# WhatsAppMCP_Get
# ------------------------------------------------------------------
sub WhatsAppMCP_Get {
    my ($hash, $name, $cmd, @args) = @_;
    return "\"get $name\" braucht mindestens ein Argument" if(!defined($cmd));

    my $list =
        "chats:noArg " .
        "messages " .
        "contacts ";

    # ---------- chats ----------
    if($cmd eq "chats") {
        WhatsAppMCP_GetChats($hash);
        return undef;
    }

    # ---------- messages [chat_jid] ----------
    if($cmd eq "messages") {
        my $chat_jid = $args[0] // "";
        my $limit    = AttrVal($name, "maxMessages", 20);
        WhatsAppMCP_GetMessages($hash, $chat_jid, $limit);
        return undef;
    }

    # ---------- contacts <suchbegriff> ----------
    if($cmd eq "contacts") {
        my $query = join(" ", @args);
        return "Suchbegriff erforderlich." if($query eq "");
        WhatsAppMCP_SearchContacts($hash, $query);
        return undef;
    }

    return "Unknown argument $cmd, choose one of $list";
}

# ------------------------------------------------------------------
# WhatsAppMCP_Attr
# ------------------------------------------------------------------
sub WhatsAppMCP_Attr {
    my ($cmd, $name, $attrName, $attrVal) = @_;
    my $hash = $defs{$name};

    if($cmd eq "set" && $attrName eq "pollInterval") {
        return "pollInterval muss eine nicht-negative Ganzzahl (Sekunden) sein."
            if($attrVal !~ /^\d+$/);
        RemoveInternalTimer($hash, "WhatsAppMCP_Poll");
        if($attrVal > 0) {
            InternalTimer(gettimeofday() + $attrVal, "WhatsAppMCP_Poll", $hash, 0);
        }
    }

    if($cmd eq "del" && $attrName eq "pollInterval") {
        RemoveInternalTimer($hash, "WhatsAppMCP_Poll");
    }

    return undef;
}

# ==================================================================
# HTTP-Helfer
# ==================================================================

# Nicht-blockierender HTTP-POST
sub WhatsAppMCP_HttpPost {
    my ($hash, $path, $body, $callback) = @_;
    my $url = $hash->{URL} . $path;

    HttpUtils_NonblockingGet({
        url         => $url,
        method      => "POST",
        header      => "Content-Type: application/json\r\nAccept: application/json",
        data        => $body,
        timeout     => 10,
        hash        => $hash,
        callback    => $callback,
    });
}

# Nicht-blockierender HTTP-GET
sub WhatsAppMCP_HttpGet {
    my ($hash, $path, $callback) = @_;
    my $url = $hash->{URL} . $path;

    HttpUtils_NonblockingGet({
        url      => $url,
        method   => "GET",
        header   => "Accept: application/json",
        timeout  => 10,
        hash     => $hash,
        callback => $callback,
    });
}

# JID-Hilfsfunktion: Telefonnummer -> WhatsApp JID
sub WhatsAppMCP_toJID {
    my ($recipient, $isGroup) = @_;
    return $recipient if($recipient =~ /\@/);   # bereits eine JID
    $recipient =~ s/[^0-9+]//g;                 # nur Ziffern und +
    $recipient =~ s/^\+//;                       # fuehrendes + entfernen
    my $suffix = $isGroup ? "\@g.us" : "\@s.whatsapp.net";
    return $recipient . $suffix;
}

# ==================================================================
# Aktionen
# ==================================================================

# --- Verbindungstest (GET /openapi.json) ---
sub WhatsAppMCP_CheckConnection {
    my ($hash) = @_;
    return if(IsDisabled($hash->{NAME}));

    WhatsAppMCP_HttpGet($hash, "/openapi.json", sub {
        my ($param, $err, $data) = @_;
        my $name = $hash->{NAME};
        if($err) {
            readingsSingleUpdate($hash, "connected", "error: $err", 1);
            readingsSingleUpdate($hash, "state", "disconnected", 1);
            Log3($name, 2, "$name: Verbindungsfehler: $err");
        } else {
            readingsSingleUpdate($hash, "connected", "yes", 1);
            readingsSingleUpdate($hash, "state", "connected", 1);
            Log3($name, 4, "$name: Verbindung OK");

            # Polling starten falls konfiguriert
            my $interval = AttrVal($name, "pollInterval", 0);
            if($interval > 0) {
                InternalTimer(gettimeofday() + $interval, "WhatsAppMCP_Poll", $hash, 0);
            }
        }
    });
}

# --- Nachricht senden (POST /send_message) ---
sub WhatsAppMCP_SendMessage {
    my ($hash, $recipient, $message) = @_;
    my $name = $hash->{NAME};
    return if(IsDisabled($name));

    my $body = to_json({
        recipient => $recipient,
        message   => $message,
    });

    Log3($name, 4, "$name: Sende an $recipient: $message");

    WhatsAppMCP_HttpPost($hash, "/send_message", $body, sub {
        my ($param, $err, $data) = @_;
        if($err) {
            Log3($name, 2, "$name: Sendefehler: $err");
            readingsSingleUpdate($hash, "lastError", "send: $err", 1);
            return;
        }
        my $res = eval { from_json($data) };
        if($@ || !$res || !$res->{success}) {
            my $msg = $res ? ($res->{message} // "unbekannter Fehler") : $@;
            Log3($name, 2, "$name: Senden fehlgeschlagen: $msg");
            readingsSingleUpdate($hash, "lastError", "send: $msg", 1);
            return;
        }
        my $ts = FmtDateTime(time());
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, "lastSent",       "$ts | $recipient | $message");
        readingsBulkUpdate($hash, "lastSentTo",     $recipient);
        readingsBulkUpdate($hash, "lastSentMsg",    $message);
        readingsBulkUpdate($hash, "lastSentTime",   $ts);
        readingsEndUpdate($hash, 1);
        Log3($name, 3, "$name: Nachricht gesendet an $recipient");
    });
}

# --- Chats abrufen (POST /list_chats) ---
sub WhatsAppMCP_GetChats {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    return if(IsDisabled($name));

    my $body = to_json({ limit => 20, sort_by => "last_active" });

    WhatsAppMCP_HttpPost($hash, "/list_chats", $body, sub {
        my ($param, $err, $data) = @_;
        if($err) {
            Log3($name, 2, "$name: Chats abrufen fehlgeschlagen: $err");
            return;
        }
        my $res = eval { from_json($data) };
        return if($@ || ref($res) ne 'ARRAY');

        my $count = scalar(@$res);
        my @chatNames = map { $_->{name} // $_->{jid} // "?" } @$res;
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, "chatCount", $count);
        readingsBulkUpdate($hash, "chatList",  join(", ", @chatNames[0..min($count-1,9)]));
        readingsEndUpdate($hash, 1);
        Log3($name, 4, "$name: $count Chats abgerufen");
    });
}

# --- Nachrichten abrufen (POST /list_messages) ---
sub WhatsAppMCP_GetMessages {
    my ($hash, $chat_jid, $limit) = @_;
    my $name = $hash->{NAME};
    return if(IsDisabled($name));

    my %req = ( limit => $limit + 0, include_context => JSON::false );
    $req{chat_jid} = $chat_jid if($chat_jid ne "");

    WhatsAppMCP_HttpPost($hash, "/list_messages", to_json(\%req), sub {
        my ($param, $err, $data) = @_;
        if($err) {
            Log3($name, 2, "$name: Nachrichten abrufen fehlgeschlagen: $err");
            return;
        }
        my $res = eval { from_json($data) };
        return if($@ || ref($res) ne 'ARRAY');

        my $count = scalar(@$res);
        readingsSingleUpdate($hash, "msgCount", $count, 1);

        if($count > 0) {
            my $last = $res->[0];
            readingsBeginUpdate($hash);
            readingsBulkUpdate($hash, "lastRecv",
                ($last->{timestamp} // "?") . " | " .
                ($last->{sender}    // "?") . ": " .
                ($last->{content}   // ""));
            readingsBulkUpdate($hash, "lastRecvSender",  $last->{sender}    // "");
            readingsBulkUpdate($hash, "lastRecvContent", $last->{content}   // "");
            readingsBulkUpdate($hash, "lastRecvTime",    $last->{timestamp} // "");
            readingsBulkUpdate($hash, "lastRecvChat",    $last->{chat_jid}  // "");
            readingsEndUpdate($hash, 1);
        }
        Log3($name, 4, "$name: $count Nachrichten abgerufen" . ($chat_jid ? " ($chat_jid)" : ""));
    });
}

# --- Kontakte suchen (POST /search_contacts) ---
sub WhatsAppMCP_SearchContacts {
    my ($hash, $query) = @_;
    my $name = $hash->{NAME};
    return if(IsDisabled($name));

    my $body = to_json({ query => $query });

    WhatsAppMCP_HttpPost($hash, "/search_contacts", $body, sub {
        my ($param, $err, $data) = @_;
        if($err) {
            Log3($name, 2, "$name: Kontaktsuche fehlgeschlagen: $err");
            return;
        }
        my $res = eval { from_json($data) };
        return if($@ || ref($res) ne 'ARRAY');

        my $count = scalar(@$res);
        my @names = map { ($_->{name} // $_->{phone_number} // "?") . " (" . ($_->{jid} // "") . ")" } @$res;
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, "searchResultCount", $count);
        readingsBulkUpdate($hash, "searchResults",     join(" | ", @names));
        readingsEndUpdate($hash, 1);
        Log3($name, 4, "$name: $count Kontakte gefunden fuer '$query'");
    });
}

# --- History Sync ausloesen (POST /api/historysync an Port 8080) ---
sub WhatsAppMCP_HistorySync {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    return if(IsDisabled($name));

    # History-Sync laeuft ueber den Bridge-Port (8080), nicht den MCP-Port (8000)
    my $bridgeUrl = $hash->{URL};
    $bridgeUrl =~ s/:8000\b/:8080/;
    $bridgeUrl =~ s|/+$||;

    HttpUtils_NonblockingGet({
        url      => "$bridgeUrl/api/historysync",
        method   => "POST",
        header   => "Content-Type: application/json",
        data     => "{}",
        timeout  => 10,
        hash     => $hash,
        callback => sub {
            my ($param, $err, $data) = @_;
            if($err) {
                Log3($name, 2, "$name: History Sync fehlgeschlagen: $err");
                return;
            }
            Log3($name, 3, "$name: History Sync gestartet: $data");
            readingsSingleUpdate($hash, "lastHistorySync", FmtDateTime(time()), 1);
        },
    });
}

# --- Polling: neue Nachrichten pruefen ---
sub WhatsAppMCP_Poll {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    return if(IsDisabled($name));

    my $interval = AttrVal($name, "pollInterval", 0);
    return if($interval <= 0);

    # Nachrichten der letzten Intervall-Sekunden abrufen
    my $since = FmtDateTimeGM(time() - $interval - 5);  # 5s Puffer

    my $body = to_json({
        limit          => AttrVal($name, "maxMessages", 20) + 0,
        include_context => JSON::false,
        after          => $since,
    });

    WhatsAppMCP_HttpPost($hash, "/list_messages", $body, sub {
        my ($param, $err, $data) = @_;
        if(!$err && $data) {
            my $res = eval { from_json($data) };
            if(!$@ && ref($res) eq 'ARRAY' && @$res) {
                my $count = scalar(@$res);
                my $last  = $res->[0];
                # Nur speichern wenn nicht von mir selbst
                if(!$last->{is_from_me}) {
                    readingsBeginUpdate($hash);
                    readingsBulkUpdate($hash, "lastRecv",
                        ($last->{timestamp} // "?") . " | " .
                        ($last->{sender}    // "?") . ": " .
                        ($last->{content}   // ""));
                    readingsBulkUpdate($hash, "lastRecvSender",  $last->{sender}    // "");
                    readingsBulkUpdate($hash, "lastRecvContent", $last->{content}   // "");
                    readingsBulkUpdate($hash, "lastRecvTime",    $last->{timestamp} // "");
                    readingsBulkUpdate($hash, "lastRecvChat",    $last->{chat_jid}  // "");
                    readingsEndUpdate($hash, 1);
                    Log3($name, 4, "$name: $count neue Nachricht(en) empfangen");
                }
            }
        }
        # Naechsten Poll-Durchlauf planen
        InternalTimer(gettimeofday() + $interval, "WhatsAppMCP_Poll", $hash, 0);
    });
}

# Hilfsfunktion min()
sub min { return $_[0] < $_[1] ? $_[0] : $_[1]; }

# Hilfsfunktion: UTC-Zeitstring fuer API-Filter
sub FmtDateTimeGM {
    my ($t) = @_;
    my @tm = gmtime($t);
    return sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ",
        $tm[5]+1900, $tm[4]+1, $tm[3], $tm[2], $tm[1], $tm[0]);
}

1;

=pod
=item device
=item summary    WhatsApp Integration ueber den whatsapp-mcp Server
=item summary_DE WhatsApp-Anbindung via whatsapp-mcp REST-API
=begin html

<a id="WhatsAppMCP"></a>
<h3>WhatsAppMCP</h3>
<ul>
  <p>
    <b>WhatsAppMCP</b> verbindet FHEM mit dem
    <a href="https://github.com/michael171185-coder/whatsapp-mcp">whatsapp-mcp</a>
    Server und ermoeglicht das Senden und Empfangen von WhatsApp-Nachrichten
    direkt aus FHEM heraus.
  </p>

  <a id="WhatsAppMCP-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; WhatsAppMCP &lt;url&gt;</code><br><br>
    <ul>
      <li><code>url</code> - URL des whatsapp-mcp Servers (MCP-Port 8000),
          z.B. <code>http://whatsapp-mcp:8000</code> oder
          <code>http://192.168.1.100:8092</code></li>
    </ul>
    Beispiel: <code>define WA WhatsAppMCP http://whatsapp-mcp:8000</code>
  </ul>
  <br>

  <a id="WhatsAppMCP-set"></a>
  <b>Set</b>
  <ul>
    <li><a id="WhatsAppMCP-set-msg"></a>
      <b>msg</b> <code>&lt;empfaenger&gt; &lt;nachricht&gt;</code> &ndash;
      Sendet eine Nachricht. Als Empfaenger kann eine Telefonnummer
      (z.B. <code>4917612345678</code>) oder eine WhatsApp-JID
      (z.B. <code>4917612345678@s.whatsapp.net</code>) angegeben werden.
      <br>Beispiel: <code>set WA msg 4917612345678 Hallo von FHEM!</code>
    </li>
    <li><a id="WhatsAppMCP-set-msg_group"></a>
      <b>msg_group</b> <code>&lt;gruppen-jid&gt; &lt;nachricht&gt;</code> &ndash;
      Sendet eine Nachricht in eine Gruppe.
      <br>Beispiel: <code>set WA msg_group 491234567890-1234567890@g.us Alarm!</code>
    </li>
    <li><a id="WhatsAppMCP-set-historysync"></a>
      <b>historysync</b> &ndash; Loest einen History-Sync aus
      (laedt aeltere Nachrichten nach).
    </li>
    <li><a id="WhatsAppMCP-set-connect"></a>
      <b>connect</b> &ndash; Prueft die Verbindung zum Server.
    </li>
  </ul>
  <br>

  <a id="WhatsAppMCP-get"></a>
  <b>Get</b>
  <ul>
    <li><a id="WhatsAppMCP-get-chats"></a>
      <b>chats</b> &ndash; Ruft die letzten 20 Chats ab und speichert sie
      in Readings.
    </li>
    <li><a id="WhatsAppMCP-get-messages"></a>
      <b>messages</b> <code>[chat_jid]</code> &ndash; Ruft Nachrichten ab,
      optional gefiltert nach Chat-JID.
    </li>
    <li><a id="WhatsAppMCP-get-contacts"></a>
      <b>contacts</b> <code>&lt;suchbegriff&gt;</code> &ndash; Sucht Kontakte
      nach Name oder Telefonnummer.
    </li>
  </ul>
  <br>

  <a id="WhatsAppMCP-attr"></a>
  <b>Attributes</b>
  <ul>
    <li><a id="WhatsAppMCP-attr-pollInterval"></a>
      <b>pollInterval</b> &ndash; Intervall in Sekunden fuer automatisches
      Abfragen neuer Nachrichten (0 = deaktiviert, Default 0).
    </li>
    <li><a id="WhatsAppMCP-attr-defaultRecipient"></a>
      <b>defaultRecipient</b> &ndash; Standard-Empfaenger wenn bei
      <code>set msg</code> keiner angegeben wird.
    </li>
    <li><a id="WhatsAppMCP-attr-maxMessages"></a>
      <b>maxMessages</b> &ndash; Maximale Anzahl Nachrichten beim Abruf
      (Default 20).
    </li>
    <li><b>disable</b> 1|0 &ndash; Deaktiviert das Modul.
    </li>
  </ul>
  <br>

  <a id="WhatsAppMCP-readings"></a>
  <b>Readings</b>
  <ul>
    <li><b>state</b> &ndash; connected / disconnected / initialized</li>
    <li><b>connected</b> &ndash; yes / error: ...</li>
    <li><b>lastSent</b> &ndash; Zeitstempel | Empfaenger | Nachricht der letzten gesendeten Nachricht</li>
    <li><b>lastSentTo</b> &ndash; JID des letzten Empfaengers</li>
    <li><b>lastSentMsg</b> &ndash; Text der letzten gesendeten Nachricht</li>
    <li><b>lastRecv</b> &ndash; Zeitstempel | Absender: Nachrichtentext</li>
    <li><b>lastRecvSender</b> &ndash; JID des letzten Absenders</li>
    <li><b>lastRecvContent</b> &ndash; Text der letzten empfangenen Nachricht</li>
    <li><b>lastRecvChat</b> &ndash; Chat-JID der letzten Nachricht</li>
    <li><b>chatCount</b> &ndash; Anzahl abgerufener Chats</li>
    <li><b>chatList</b> &ndash; Kommagetrennte Liste der letzten Chats</li>
    <li><b>searchResultCount</b> &ndash; Trefferanzahl der letzten Kontaktsuche</li>
    <li><b>searchResults</b> &ndash; Ergebnisse der letzten Kontaktsuche</li>
    <li><b>lastHistorySync</b> &ndash; Zeitpunkt des letzten History-Syncs</li>
    <li><b>lastError</b> &ndash; Letzter Fehler</li>
  </ul>

  <br>
  <b>Beispiel-Konfiguration:</b>
  <ul>
    <pre>
define WA WhatsAppMCP http://whatsapp-mcp:8000
attr WA defaultRecipient 4917612345678@s.whatsapp.net
attr WA pollInterval 60
attr WA maxMessages 10

# Nachricht senden:
set WA msg 4917612345678 Hallo von FHEM!

# Alarm via notify:
define n_WA_Alarm notify Alarmanlage:alarm.* {fhem("set WA msg 4917612345678 ALARM: $NAME hat ausgeloest!")}
    </pre>
  </ul>
</ul>

=end html
=cut
