#!/usr/bin/perl
# Tests de LocalAiJson (14.B.1). Exécution : docker run --rm --network none -v <config/gate>:/g:ro -v <tests/gate>:/t:ro --entrypoint perl <image ollama> -I/g /t/json.t.pl
use strict; use warnings;
use LocalAiJson qw(decode_json encode_json jnum);
my ($ok, $ko) = (0, 0);
sub t { my ($name, $cond) = @_; if ($cond) { $ok++ } else { $ko++; print "ÉCHEC : $name\n" } }
sub dies { my ($s) = @_; my $r = eval { decode_json($s); 1 }; return !$r }

my $v = decode_json('{"model":"qwen3.5:4b-q4_K_M","stream":true,"options":{"num_ctx":8192,"temperature":0.0},"messages":[{"role":"user","content":"a\"b\\\\c' . join('', map { chr(92) . "u$_" } qw(00e9 d83d de00)) . '"}],"x":null}');
t('modèle', $v->{model} eq 'qwen3.5:4b-q4_K_M');
t('booléen', ref $v->{stream} eq 'SCALAR' && ${$v->{stream}});
t('nombre', ref $v->{options}{num_ctx} eq 'LocalAiJson::Num' && $v->{options}{num_ctx}->num == 8192);
t('échappements et unicode', $v->{messages}[0]{content} eq "a\"b\\c\x{e9}\x{1F600}");
t('null', exists $v->{x} && !defined $v->{x});
{ my $raw = '{"c":"' . chr(0xC3) . chr(0xA9) . '"}'; utf8::decode($raw); t('UTF-8 brut décodé', decode_json($raw)->{c} eq "\x{e9}"); }
t('chaîne numérique reste chaîne', encode_json(decode_json('{"p":"42"}')) eq '{"p":"42"}');
t('aller-retour nombres', encode_json(decode_json('{"a":1.50,"b":-3e+2}')) eq '{"a":1.50,"b":-3e+2}');
t('jnum', encode_json({ keep_alive => jnum(120) }) eq '{"keep_alive":120}');
# Refus attendus
t('clé dupliquée', dies('{"model":"a","model":"b"}'));
t('clé dupliquée imbriquée', dies('{"o":{"k":1,"k":2}}'));
t('virgule finale', dies('{"a":1,}'));
t('données en trop', dies('{"a":1} {"b":2}'));
t('caractère de contrôle brut', dies("{\"a\":\"x\ny\"}"));
t('guillemet simple', dies("{'a':1}"));
t('nombre invalide', dies('{"a":01}'));
t('demi-paire isolée', dies('{"a":"\ud83d"}'));
t('profondeur', dies(('[' x 70) . (']' x 70)));
t('vide', dies(''));
t('commentaire', dies('{"a":1 /* x */}'));
t('modèle dans une chaîne ignoré', decode_json('{"prompt":"\"model\":\"evil\"","model":"ok"}')->{model} eq 'ok');
print "json : $ok PASS, $ko FAIL\n";
exit($ko ? 1 : 0);
