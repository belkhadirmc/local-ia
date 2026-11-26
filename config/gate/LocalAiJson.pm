package LocalAiJson;
# Analyseur JSON strict (RFC 8259) en Perl de base — 14.B.1. L'image Ollama n'embarque pas JSON::PP (R20).
# decode_json($texte) -> structure Perl ; meurt sur toute entrée invalide (syntaxe, contrôle, clé dupliquée, profondeur > 64,
# données en trop). Les clés dupliquées sont REFUSÉES : aucune ambiguïté possible sur « model » ou « keep_alive ».
# encode_json($valeur) : chaînes, nombres (objets jnum), booléens (\1 / \0), null (undef), tableaux, hachages.
# Texte décodé (utf8::decode) avant decode_json, réencodé (utf8::encode) après encode_json.
use strict; use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(decode_json encode_json jnum);
our $TRUE = 1; our $FALSE = 0;
my $MAX_DEPTH = 64;

sub decode_json {
    my ($s) = @_;
    die "JSON : entrée vide\n" unless defined $s && length $s;
    pos($s) = 0;
    my $v = _value(\$s, 0);
    $s =~ /\G[ \t\r\n]*/gc;
    die "JSON : données après la valeur (position " . pos($s) . ")\n" if pos($s) != length $s;
    return $v;
}
sub _ws { ${$_[0]} =~ /\G[ \t\r\n]*/gc }
sub _value {
    my ($r, $d) = @_;
    die "JSON : profondeur maximale dépassée\n" if $d > $MAX_DEPTH;
    _ws($r);
    if ($$r =~ /\G\{/gc) { return _object($r, $d + 1) }
    if ($$r =~ /\G\[/gc) { return _array($r, $d + 1) }
    if ($$r =~ /\G"/gc)  { return _string($r) }
    if ($$r =~ /\G(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/gc) { return jnum($1) }
    if ($$r =~ /\Gtrue/gc)  { return \1 }
    if ($$r =~ /\Gfalse/gc) { return \0 }
    if ($$r =~ /\Gnull/gc)  { return undef }
    die "JSON : valeur invalide (position " . (pos($$r) // 0) . ")\n";
}
sub _object {
    my ($r, $d) = @_;
    my %o; _ws($r);
    return \%o if $$r =~ /\G\}/gc;
    while (1) {
        _ws($r);
        $$r =~ /\G"/gc or die "JSON : clé attendue (position " . pos($$r) . ")\n";
        my $k = _string($r);
        die "JSON : clé dupliquée « $k »\n" if exists $o{$k};
        _ws($r); $$r =~ /\G:/gc or die "JSON : « : » attendu\n";
        $o{$k} = _value($r, $d);
        _ws($r);
        next if $$r =~ /\G,/gc;
        return \%o if $$r =~ /\G\}/gc;
        die "JSON : « , » ou « } » attendu (position " . pos($$r) . ")\n";
    }
}
sub _array {
    my ($r, $d) = @_;
    my @a; _ws($r);
    return \@a if $$r =~ /\G\]/gc;
    while (1) {
        push @a, _value($r, $d);
        _ws($r);
        next if $$r =~ /\G,/gc;
        return \@a if $$r =~ /\G\]/gc;
        die "JSON : « , » ou « ] » attendu (position " . pos($$r) . ")\n";
    }
}
my %ESC = ('"' => '"', '\\' => '\\', '/' => '/', b => "\b", f => "\f", n => "\n", r => "\r", t => "\t");
sub _string {
    my ($r) = @_;
    my $out = '';
    while (1) {
        if ($$r =~ /\G([^"\\\x00-\x1f]+)/gc) { $out .= $1; next }
        if ($$r =~ /\G"/gc) { return $out }
        if ($$r =~ /\G\\u([0-9a-fA-F]{4})/gc) {
            my $c = hex $1;
            if ($c >= 0xD800 && $c <= 0xDBFF) {
                $$r =~ /\G\\u([dD][c-fC-F][0-9a-fA-F]{2})/gc or die "JSON : demi-paire de substitution isolée\n";
                $c = 0x10000 + (($c - 0xD800) << 10) + (hex($1) - 0xDC00);
            } elsif ($c >= 0xDC00 && $c <= 0xDFFF) { die "JSON : demi-paire de substitution isolée\n" }
            $out .= chr $c; next;
        }
        if ($$r =~ /\G\\(["\\\/bfnrt])/gc) { $out .= $ESC{$1}; next }
        die "JSON : chaîne invalide (position " . pos($$r) . ")\n";
    }
}
sub encode_json {
    my ($v) = @_;
    return 'null' unless defined $v;
    my $t = ref $v;
    if ($t eq 'HASH')   { return '{' . join(',', map { _str($_) . ':' . encode_json($v->{$_}) } sort keys %$v) . '}' }
    if ($t eq 'ARRAY')  { return '[' . join(',', map { encode_json($_) } @$v) . ']' }
    if ($t eq 'SCALAR') { return $$v ? 'true' : 'false' }
    if ($t eq 'LocalAiJson::Num') { return $$v }
    return _str($v);   # tout scalaire non marqué est une chaîne : "42" reste "42"
}
# Nombre JSON : texte d'origine conservé (aucune perte de précision ni confusion chaîne/nombre) ; ->num donne la valeur Perl.
sub jnum { my ($t) = @_; die "JSON : nombre invalide\n" unless $t =~ /\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z/; my $x = "$t"; return bless \$x, 'LocalAiJson::Num' }
sub LocalAiJson::Num::num { 0 + ${$_[0]} }
sub _str {
    my ($s) = @_;
    $s =~ s/(["\\])/\\$1/g; $s =~ s/\n/\\n/g; $s =~ s/\r/\\r/g; $s =~ s/\t/\\t/g;
    $s =~ s/([\x00-\x1f])/sprintf('\\u%04x', ord $1)/ge;
    return qq("$s");
}
1;
