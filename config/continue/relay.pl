#!/usr/bin/perl
# Relais d'autocomplétion Continue -> Ollama (11.B.1). Monté en lecture seule, exécuté par l'image Ollama épinglée (perl 5.38, modules de base).
# Expose UNIQUEMENT ce dont l'autocomplétion a besoin, pour UN modèle :
#   GET/HEAD /            -> « Ollama is running » (contrôle de disponibilité)
#   GET  /api/tags        -> liste réduite au modèle autorisé (rien d'autre n'est révélé)
#   POST /api/show        -> métadonnées du modèle autorisé uniquement
#   POST /api/generate    -> complétion (FIM) du modèle autorisé uniquement, keep_alive plafonné
# Tout le reste : 403. Corps > 1 Mio : 413. Autre modèle chargé (OpenCode actif) : 409, aucune substitution ni déchargement.
use strict; use warnings;
use IO::Socket::INET;
use POSIX ':sys_wait_h';

my $MODEL      = $ENV{RELAY_MODEL}      // 'qwen2.5-coder:1.5b';
my $UPSTREAM   = $ENV{RELAY_UPSTREAM}   // 'ollama:11434';
my $LISTEN     = $ENV{RELAY_LISTEN}     // '0.0.0.0:8080';
my $KEEP_ALIVE = $ENV{RELAY_KEEP_ALIVE} // '120';
my $MAX_BODY   = 1024 * 1024;
$| = 1;
$SIG{CHLD} = sub { 1 while waitpid(-1, WNOHANG) > 0 };
$SIG{PIPE} = 'IGNORE';

my $srv = IO::Socket::INET->new(LocalAddr => $LISTEN, Listen => 16, ReuseAddr => 1, Proto => 'tcp') or die "écoute $LISTEN : $!\n";
print "relais autocomplétion : $LISTEN -> $UPSTREAM (modèle $MODEL)\n";

sub logline { my ($m) = @_; my @t = gmtime; printf "%04d-%02d-%02dT%02d:%02d:%02dZ %s\n", $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0], $m; }
sub reply {
    my ($c, $code, $text, $body, $ctype) = @_;
    $ctype //= 'application/json';
    print $c "HTTP/1.1 $code $text\r\nContent-Type: $ctype\r\nContent-Length: " . length($body) . "\r\nConnection: close\r\n\r\n$body";
}
sub upstream_call {
    # Requête courte vers Ollama (contrôle /api/ps) ; renvoie le corps.
    my ($method, $path, $body) = @_;
    my $u = IO::Socket::INET->new(PeerAddr => $UPSTREAM, Proto => 'tcp', Timeout => 5) or return undef;
    $body //= '';
    print $u "$method $path HTTP/1.0\r\nHost: ollama\r\nContent-Type: application/json\r\nContent-Length: " . length($body) . "\r\nConnection: close\r\n\r\n$body";
    local $/; my $r = <$u>; close $u;
    return undef unless defined $r;
    $r =~ s/\A.*?\r\n\r\n//s; return $r;
}
sub models_in { my ($b) = @_; my @m = ($b =~ /(?<!\\)"model"\s*:\s*"((?:[^"\\]|\\.)*)"/g); return @m; }

while (1) {
    my $c = $srv->accept or next;   # accept interrompu par SIGCHLD (EINTR) : on continue
    my $pid = fork;
    if (!defined $pid) { reply($c, 503, 'Service Unavailable', '{"error":"relais saturé"}'); close $c; next; }
    if ($pid) { close $c; next; }
    # --- processus fils : une requête
    close $srv; $c->autoflush(1);
    local $SIG{ALRM} = sub { exit 0 }; alarm 30;
    my $line = <$c> // exit 0; $line =~ s/\r?\n\z//;
    my ($method, $path) = split / /, $line;
    my %h;
    while (my $hl = <$c>) { $hl =~ s/\r?\n\z//; last if $hl eq ''; my ($k, $v) = split /:\s*/, $hl, 2; $h{lc $k} = $v if defined $v; }
    $path //= ''; $path =~ s/\?.*//;
    my $len = $h{'content-length'} // 0;
    if ($len !~ /^\d+$/ || $len > $MAX_BODY) { reply($c, 413, 'Payload Too Large', '{"error":"corps trop volumineux"}'); exit 0; }
    my $body = ''; while (length($body) < $len) { my $n = read($c, $body, $len - length($body), length($body)); last unless $n; }
    alarm 0;
    if (($method eq 'GET' || $method eq 'HEAD') && $path eq '/') { reply($c, 200, 'OK', 'Ollama is running', 'text/plain'); logline("200 $method /"); exit 0; }
    if ($method eq 'GET' && $path eq '/api/tags') {
        reply($c, 200, 'OK', qq({"models":[{"name":"$MODEL","model":"$MODEL","details":{"family":"qwen2","format":"gguf"}}]})); logline("200 GET /api/tags (filtré)"); exit 0;
    }
    if ($method ne 'POST' || ($path ne '/api/generate' && $path ne '/api/show')) { reply($c, 403, 'Forbidden', '{"error":"opération non autorisée par le relais local-ai"}'); logline("403 $method $path"); exit 0; }
    my @m = models_in($body);
    if (!@m || grep { $_ ne $MODEL } @m) { reply($c, 403, 'Forbidden', qq({"error":"seul le modèle $MODEL est autorisé"})); logline("403 $path modèle refusé"); exit 0; }
    if ($path eq '/api/generate') {
        # Aucune concurrence : si un autre modèle est chargé (OpenCode), refus explicite sans déchargement ni substitution.
        my $ps = upstream_call('GET', '/api/ps');
        if (!defined $ps) { reply($c, 502, 'Bad Gateway', '{"error":"Ollama injoignable"}'); logline("502 /api/ps"); exit 0; }
        my @loaded = ($ps =~ /"name"\s*:\s*"([^"]+)"/g);
        if (grep { $_ ne $MODEL } @loaded) { reply($c, 409, 'Conflict', '{"error":"inférence OpenCode en cours (autre modèle chargé) : autocomplétion suspendue"}'); logline("409 conflit (" . join(',', @loaded) . ")"); exit 0; }
        # keep_alive plafonné (Continue envoie 1800 s par défaut)
        if ($body =~ /(?<!\\)"keep_alive"\s*:/) { $body =~ s/(?<!\\)"keep_alive"\s*:\s*("[^"]*"|-?[0-9.]+)/"keep_alive":$KEEP_ALIVE/; }
        else { $body =~ s/\}\s*\z/,"keep_alive":$KEEP_ALIVE}/; }
    }
    my $u = IO::Socket::INET->new(PeerAddr => $UPSTREAM, Proto => 'tcp', Timeout => 10);
    if (!$u) { reply($c, 502, 'Bad Gateway', '{"error":"Ollama injoignable"}'); logline("502 $path"); exit 0; }
    print $u "POST $path HTTP/1.0\r\nHost: ollama\r\nContent-Type: application/json\r\nContent-Length: " . length($body) . "\r\nConnection: close\r\n\r\n$body";
    # Réponse transmise telle quelle (flux NDJSON compris), HTTP/1.0 -> fermeture en fin de flux.
    my $buf; while (sysread($u, $buf, 65536)) { print $c $buf or last; }
    close $u; logline("relayé POST $path ($MODEL)");
    exit 0;
}
