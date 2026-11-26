#!/usr/bin/perl
# Sonde d'admission À BLANC (14.B.2) : docker exec local-ai-ollama-gate-1 perl /etc/local-ai/admit.pl <modèle> [<modèle>…]
# Interroge la passerelle locale (POST /local-ai/admission) : aucune inférence, aucun verrou. Une ligne JSON par modèle.
use strict; use warnings; use IO::Socket::INET;
for my $m (@ARGV) {
    die "modèle invalide\n" unless $m =~ /\A[A-Za-z0-9._:-]+\z/;
    my $b = qq({"model":"$m"});
    my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1:11434', Timeout => 10) or die "passerelle injoignable : $!\n";
    print $s "POST /local-ai/admission HTTP/1.0\r\nContent-Type: application/json\r\nContent-Length: " . length($b) . "\r\n\r\n$b";
    local $/; my $r = <$s>; close $s;
    my ($body) = ($r // '') =~ /\r\n\r\n(.*)\z/s;
    print(($body // '{"error":"réponse vide"}') . "\n");
}
