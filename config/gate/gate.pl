#!/usr/bin/perl
# Passerelle d'inférence local-ai (14.B.1) — SEUL chemin vers Ollama pour OpenCode (Web, TUI, agents) et le relais Continue.
# Ollama est sur le réseau interne local-ai-inference, joint uniquement par cette passerelle (alias « ollama » sur local-ai-core).
#  - Routes : lecture (/, /api/version, /api/tags, /api/ps, /v1/models, POST /api/show) et inférence (/api/generate, /api/chat,
#    /v1/chat/completions, /v1/completions, /api/embed[dings], /v1/embeddings). Tout le reste (pull, push, create, copy, delete,
#    blobs…) : 403. Corps JSON analysé strictement (LocalAiJson : clé dupliquée = refus), modèle limité au registre (GATE_MODELS).
#  - Exclusion mutuelle RÉELLE : un verrou unique pour toute inférence. OpenCode attend son tour (file, GATE_QUEUE_S) ; Continue
#    (en-tête X-Local-AI-Client: continue) reçoit 409 immédiatement si une inférence est en cours.
#  - RAM AVANT : admission d'un modèle non chargé si la VM peut le contenir ET si la RAM Windows projetée après chargement reste
#    >= GATE_WIN_MIN_GIB (mesure de la sentinelle hôte, runtime/state/host-ram.json). Croissance projetée = min(RAM libre VM,
#    GATE_GROWTH_FACTOR x taille - modèle déchargé) : poids + cache de pages (R24). Mesure absente/périmée : seuls les modèles
#    <= GATE_UNVERIFIED_MAX_GIB sont admis (seuils non garantis -> 30B/20B/14B bloqués).
#  - RAM PENDANT : contrôle chaque seconde ; RAM Windows < minimum ou VM < 0,5 Gio pendant GATE_ABORT_AFTER_S s -> abandon de la
#    requête (Ollama annule), déchargement du modèle, erreur explicite.
#  - Arrêt d'urgence : runtime/state/emergency.json présent -> toute inférence refusée (503).
use strict; use warnings;
use IO::Socket::INET; use IO::Select; use POSIX ':sys_wait_h'; use Fcntl ':flock';
use lib '/etc/local-ai'; use LocalAiJson qw(decode_json encode_json);

my $LISTEN   = '0.0.0.0:11434';
my $UP       = $ENV{GATE_UPSTREAM} // 'ollama-engine:11434';
my %ALLOWED  = map { $_ => 1 } grep { length } split /,/, ($ENV{GATE_MODELS} // '');
my $WIN_MIN  = $ENV{GATE_WIN_MIN_GIB} // 4;
my $UNVER    = $ENV{GATE_UNVERIFIED_MAX_GIB} // 8;
my $GROWTH   = $ENV{GATE_GROWTH_FACTOR} // 2;
my $STATE    = $ENV{GATE_STATE_DIR} // '/run/local-ai/state';
my $STALE    = $ENV{GATE_HOST_STALE_S} // 20;
my $QUEUE    = $ENV{GATE_QUEUE_S} // 900;
my $ABORT_S  = $ENV{GATE_ABORT_AFTER_S} // 3;
my $ADMIT_WAIT = $ENV{GATE_ADMIT_WAIT_S} // 20;
my $VM_MIN   = 0.5;
my $LOCK     = '/tmp/local-ai-gate.lock';
my $MAX_BODY = 32 * 1024 * 1024;
my $GiB      = 1024 ** 3;
my %INFER    = map { $_ => 1 } qw(/api/generate /api/chat /v1/chat/completions /v1/completions /api/embed /api/embeddings /v1/embeddings);
my %READ_GET = map { $_ => 1 } qw(/ /api/version /api/tags /api/ps /v1/models);
$| = 1;
$SIG{CHLD} = sub { 1 while waitpid(-1, WNOHANG) > 0 };
$SIG{PIPE} = 'IGNORE';
die "GATE_MODELS vide\n" unless %ALLOWED;

my $srv = IO::Socket::INET->new(LocalAddr => $LISTEN, Listen => 32, ReuseAddr => 1, Proto => 'tcp') or die "écoute $LISTEN : $!\n";
print "passerelle d'inférence : $LISTEN -> $UP ; modèles : " . join(',', sort keys %ALLOWED) . " ; RAM Windows min $WIN_MIN Gio\n";

sub ts { my @t = gmtime; sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0] }
my ($CLIENT, $REQ) = ('?', '?');
sub logline { print ts() . " $CLIENT $REQ $_[0]\n" }
sub n { my ($v) = @_; return 0 unless defined $v; return ref($v) eq 'LocalAiJson::Num' ? $v->num : (ref $v ? 0 : 0 + ($v =~ /\A-?[0-9.]+\z/ ? $v : 0)) }
sub reply {
    my ($c, $code, $text, $body, $ctype) = @_;
    $ctype //= 'application/json';
    print $c "HTTP/1.1 $code $text\r\nContent-Type: $ctype\r\nContent-Length: " . length($body) . "\r\nConnection: close\r\n\r\n$body";
}
sub refuse {
    my ($c, $code, $text, $msg, $path) = @_;
    my $b = ($path // '') =~ m{\A/v1/} ? encode_json({ error => { message => "local-ai : $msg", type => 'local_ai_gate', code => $code } })
                                       : encode_json({ error => "local-ai : $msg" });
    utf8::encode($b) if utf8::is_utf8($b);
    reply($c, $code, $text, $b); logline("$code $msg");
}
sub upstream_raw {
    my ($method, $path, $body) = @_;
    my $u = IO::Socket::INET->new(PeerAddr => $UP, Proto => 'tcp', Timeout => 5) or return undef;
    $body //= '';
    print $u "$method $path HTTP/1.0\r\nHost: ollama\r\nContent-Type: application/json\r\nContent-Length: " . length($body) . "\r\n\r\n$body";
    local $/; my $r = <$u>; close $u;
    return undef unless defined $r;
    $r =~ s/\A.*?\r\n\r\n//s; return $r;
}
sub jget { my $r = upstream_raw('GET', $_[0]); return undef unless defined $r; my $v = eval { decode_json($r) }; return $v }
sub meminfo {
    my %m; open my $f, '<', '/proc/meminfo' or return {};
    while (<$f>) { $m{$1} = $2 / (1024 * 1024) if /^(\w+):\s+(\d+)/ } close $f; return \%m;
}
sub host_ram {
    # Mesure Windows publiée par la sentinelle hôte (scripts/monitor/sentinel.ps1) ; undef si absente ou périmée.
    open my $f, '<', "$STATE/host-ram.json" or return undef; local $/; my $t = <$f>; close $f;
    $t =~ s/\A\xEF\xBB\xBF//;
    my $h = eval { decode_json($t) } or return undef;
    my $age = time - n($h->{ts_unix});
    return undef if $age > $STALE || $age < -$STALE;
    return { free => n($h->{win_free_gib}), total => n($h->{win_total_gib}), age => $age };
}
sub emergency { -e "$STATE/emergency.json" }
sub admission {
    my ($model) = @_;
    my $ps = jget('/api/ps') or return (0, 'Ollama injoignable');
    my @loaded = map { [$_->{name} // '', n($_->{size}) / $GiB] } @{ $ps->{models} || [] };
    return (1, 'modèle déjà chargé') if grep { $_->[0] eq $model } @loaded;
    my $tags = jget('/api/tags') or return (0, 'Ollama injoignable');
    my ($t) = grep { ($_->{name} // '') eq $model } @{ $tags->{models} || [] };
    return (0, "modèle $model absent d'Ollama") unless $t;
    my $size = n($t->{size}) / $GiB; my $freed = 0; $freed += $_->[1] for @loaded;
    my $m = meminfo();
    my $vm = ($m->{MemAvailable} // 0) + $freed;
    return (0, sprintf('RAM WSL2 insuffisante : %.1f Gio disponibles pour %s (%.1f Gio + 1 Gio de marge)', $vm, $model, $size)) if $vm < $size + 1;
    my $growth = $GROWTH * $size - $freed; $growth = 0 if $growth < 0;
    $growth = $m->{MemFree} // 0 if $growth > ($m->{MemFree} // 0);
    my $h = host_ram();
    if ($h) {
        my $proj = $h->{free} - $growth;
        return (0, sprintf('RAM Windows insuffisante : %.1f Gio libres, %.1f Gio projetés après chargement de %s (%.1f Gio) < %s Gio minimum — fermer des applications ou choisir un modèle plus petit', $h->{free}, $proj, $model, $size, $WIN_MIN)) if $proj < $WIN_MIN;
        return (1, sprintf('admis : Windows %.1f -> %.1f Gio projetés', $h->{free}, $proj));
    }
    return (0, sprintf('seuils RAM non garantis (mesure Windows absente ou périmée : sentinelle arrêtée) pour %s (%.1f Gio > %s Gio)', $model, $size, $UNVER)) if $size > $UNVER;
    return (1, sprintf('admis sans mesure Windows (%.1f Gio <= %s Gio)', $size, $UNVER));
}
sub read_body {
    my ($c, $h) = @_;
    if (($h->{'transfer-encoding'} // '') =~ /chunked/i) {
        my $b = '';
        while (defined(my $l = <$c>)) {
            $l =~ s/\r?\n\z//; my ($sz) = $l =~ /\A([0-9a-fA-F]+)/; return undef unless defined $sz; $sz = hex $sz;
            if (!$sz) { while (defined(my $tl = <$c>)) { last if $tl =~ /\A\r?\n\z/ } return $b }
            return undef if length($b) + $sz > $MAX_BODY;
            my $chunk = ''; while (length($chunk) < $sz) { my $r = read($c, $chunk, $sz - length($chunk), length($chunk)); return undef unless $r }
            $b .= $chunk; <$c>;
        }
        return undef;
    }
    my $len = $h->{'content-length'} // 0;
    return undef if $len !~ /\A\d+\z/ || $len > $MAX_BODY;
    my $b = ''; while (length($b) < $len) { my $r = read($c, $b, $len - length($b), length($b)); last unless $r }
    return length($b) == $len ? $b : undef;
}
sub is_unload {
    my ($j) = @_;
    my $ka = $j->{keep_alive}; return 0 unless defined $ka;
    my $zero = ref($ka) eq 'LocalAiJson::Num' ? $ka->num == 0 : (!ref($ka) && $ka =~ /\A0+[a-z]*\z/);
    my $p = $j->{prompt}; my $msgs = $j->{messages};
    return $zero && (!defined $p || $p eq '') && (!$msgs || (ref $msgs eq 'ARRAY' && !@$msgs));
}
sub unload { my ($model) = @_; upstream_raw('POST', '/api/generate', encode_json({ model => $model, keep_alive => LocalAiJson::jnum(0) })) }
sub client_gone { my ($c) = @_; my $s = IO::Select->new($c); return 0 unless $s->can_read(0); my $b; my $r = sysread($c, $b, 1); return !$r }

sub handle {
    my ($c) = @_;
    $CLIENT = $c->peerhost // '?';
    local $SIG{ALRM} = sub { exit 0 }; alarm 60;
    my $line = <$c> // exit 0; $line =~ s/\r?\n\z//;
    my ($method, $path) = split / /, $line; $method //= ''; $path //= ''; $path =~ s/\?.*//;
    my %h; while (my $hl = <$c>) { $hl =~ s/\r?\n\z//; last if $hl eq ''; my ($k, $v) = split /:\s*/, $hl, 2; $h{lc $k} = $v if defined $v }
    $REQ = "$method $path";
    my $is_continue = (($h{'x-local-ai-client'} // '') eq 'continue');
    if (($method eq 'GET' || $method eq 'HEAD') && ($READ_GET{$path} || $path =~ m{\A/v1/models/[^/]+\z})) {
        my $r = upstream_raw($method, $path); alarm 0;
        return refuse($c, 502, 'Bad Gateway', 'Ollama injoignable', $path) unless defined $r;
        reply($c, 200, 'OK', $r, $path eq '/' ? 'text/plain' : 'application/json'); return;
    }
    my $infer = $INFER{$path};
    return refuse($c, 403, 'Forbidden', "opération non autorisée par la passerelle ($method $path)", $path) unless $method eq 'POST' && ($infer || $path eq '/api/show');
    my $body = read_body($c, \%h); alarm 0;
    return refuse($c, 413, 'Payload Too Large', 'corps absent, invalide ou > 32 Mio', $path) unless defined $body;
    my $j = eval { decode_json($body) };
    return refuse($c, 400, 'Bad Request', 'JSON invalide : ' . (($@ // '') =~ s/\n//r), $path) unless ref $j eq 'HASH';
    my $model = $j->{model} // ($path eq '/api/show' ? $j->{name} : undef);
    return refuse($c, 403, 'Forbidden', 'modèle absent ou non textuel', $path) unless defined $model && !ref $model;
    return refuse($c, 403, 'Forbidden', "modèle hors registre local : $model", $path) unless $ALLOWED{$model};
    $REQ .= " [$model]";
    if (!$infer) { my $r = upstream_raw('POST', $path, $body); return defined $r ? reply($c, 200, 'OK', $r) : refuse($c, 502, 'Bad Gateway', 'Ollama injoignable', $path) }
    if (is_unload($j)) { my $r = upstream_raw('POST', $path, $body); logline('déchargement'); return reply($c, 200, 'OK', $r // '{}') }
    return refuse($c, 400, 'Bad Request', "arrêt d'urgence actif (local-ai.ps1 emergency-stop clear)", $path) if emergency();

    # --- exclusion mutuelle : une seule inférence à la fois, tous clients confondus
    open my $lk, '>>', $LOCK or return refuse($c, 500, 'Internal Server Error', 'verrou indisponible', $path);
    my $t0 = time;
    until (flock($lk, LOCK_EX | LOCK_NB)) {
        return refuse($c, 409, 'Conflict', 'inférence en cours : autocomplétion suspendue (aucune concurrence)', $path) if $is_continue;
        return refuse($c, 503, 'Service Unavailable', "file d'attente dépassée ($QUEUE s)", $path) if time - $t0 > $QUEUE;
        if (client_gone($c)) { logline('client parti pendant l\'attente'); return }
        select(undef, undef, undef, 0.5);
    }
    logline('attente ' . (time - $t0) . ' s') if time - $t0 > 1;
    return refuse($c, 400, 'Bad Request', "arrêt d'urgence actif", $path) if emergency();
    # --- RAM avant
    # Réévaluation pendant GATE_ADMIT_WAIT_S (cache de pages en cours de restitution), puis refus NON réessayable (400) :
    # un 503 serait réessayé indéfiniment par OpenCode (session bloquée sans message) — constaté en 14.B.1.
    my ($ok, $why) = admission($model); my $ta = time;
    while (!$ok && time - $ta < $ADMIT_WAIT) {
        if (client_gone($c)) { logline('client parti pendant l\'admission'); return }
        select(undef, undef, undef, 2); ($ok, $why) = admission($model);
    }
    return refuse($c, 400, 'Bad Request', "$why (refus après " . (time - $ta) . ' s)', $path) unless $ok;
    logline($why);
    # --- relais + RAM pendant
    my $u = IO::Socket::INET->new(PeerAddr => $UP, Proto => 'tcp', Timeout => 10) or return refuse($c, 502, 'Bad Gateway', 'Ollama injoignable', $path);
    print $u "POST $path HTTP/1.0\r\nHost: ollama\r\nContent-Type: application/json\r\nContent-Length: " . length($body) . "\r\n\r\n$body";
    my $sel = IO::Select->new($u, $c); my ($sent, $bad, $last, $start) = (0, 0, time, time);
    while (1) {
        for my $fh ($sel->can_read(1)) {
            my $buf; my $r = sysread($fh, $buf, 65536);
            if ($fh == $u) {
                if (!$r) { close $u; logline(sprintf('terminé en %d s', time - $start)); return }
                my $off = 0; while ($off < length $buf) { my $w = syswrite($c, $buf, length($buf) - $off, $off); if (!$w) { close $u; logline('client parti : inférence annulée'); return } $off += $w }
                $sent += length $buf;
            } elsif (!$r) { close $u; logline('client parti : inférence annulée'); return }
        }
        next if time == $last; $last = time;
        my $h = host_ram(); my $m = meminfo();
        my $low = ($h && $h->{free} < $WIN_MIN) || (($m->{MemAvailable} // 99) < $VM_MIN);
        $bad = $low ? $bad + 1 : 0;
        if ($bad >= $ABORT_S) {
            close $u; unload($model);
            my $msg = sprintf('inférence interrompue : RAM sous le seuil pendant %d s (Windows %s Gio libres, WSL2 %.1f Gio disponibles) — modèle %s déchargé',
                $bad, ($h ? sprintf('%.1f', $h->{free}) : '?'), $m->{MemAvailable} // 0, $model);
            if ($sent) { logline("ABANDON $msg") } else { refuse($c, 400, 'Bad Request', $msg, $path) }
            return;
        }
    }
}

while (1) {
    my $c = $srv->accept or next;
    my $pid = fork;
    if (!defined $pid) { reply($c, 503, 'Service Unavailable', '{"error":"passerelle saturée"}'); close $c; next }
    if ($pid) { close $c; next }
    close $srv; $c->autoflush(1);
    eval { handle($c) }; if ($@) { logline("erreur interne : $@") }
    close $c; exit 0;
}
