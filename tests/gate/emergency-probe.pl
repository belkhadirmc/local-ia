#!/usr/bin/perl
# Sonde d'arrêt d'urgence (14.B.1) : POST d'inférence vers la passerelle locale ; affiche le code HTTP reçu (aucune inférence si refus).
use strict; use warnings; use IO::Socket::INET;
my $b = '{"model":"qwen3.5:4b-q4_K_M","prompt":"x","stream":false}';
my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1:11434', Timeout => 5) or die "connexion : $!\n";
print $s "POST /api/generate HTTP/1.0\r\nContent-Type: application/json\r\nContent-Length: " . length($b) . "\r\n\r\n$b";
local $/; my $r = <$s>; my ($code) = $r =~ m{\AHTTP/1\.[01] (\d+)}; my ($body) = $r =~ /\r\n\r\n(.*)\z/s;
print "code=$code corps=" . substr($body // '', 0, 120) . "\n";
