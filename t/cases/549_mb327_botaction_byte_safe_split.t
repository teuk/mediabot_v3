# t/cases/549_mb327_botaction_byte_safe_split.t
# =============================================================================
# mb327 — Découpage octet-safe des ACTIONs (/me).
#
# botAction() envoyait tout le message en un seul do_PRIVMSG enveloppé
# "\1ACTION ...\1", sans découpage. Un /me accentué/emoji dépassait ~512 octets :
# le serveur tronquait la ligne ET perdait le \1 final, corrompant le CTCP
# ACTION. mb327 réutilise le helper partagé _split_text_for_irc (mb325) en
# réservant l'overhead du wrapper, et ré-emballe chaque chunk en ACTION distinct.
#
# Ce test :
#   1. vérifie par scan de source que botAction passe par le helper et emballe
#      chaque chunk ;
#   2. reproduit le comportement avec le helper réel et prouve que chaque ligne
#      ACTION émise reste dans le budget d'octets, sans couper de multi-octets.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;
use Encode qw(encode);

sub _slurp_549 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_549 {
    my ($src, $name) = @_;
    return undef unless $src =~ /(sub\s+\Q$name\E\s*\{)/;
    my $start = $-[0];
    my $i     = index($src, '{', $start);
    return undef if $i < 0;
    my $depth = 0;
    for (my $p = $i; $p < length($src); $p++) {
        my $c = substr($src, $p, 1);
        $depth++ if $c eq '{';
        $depth-- if $c eq '}';
        return substr($src, $start, $p - $start + 1) if $depth == 0;
    }
    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_549(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));

    # --- 1. Scan de source de botAction ----------------------------------
    my $action = _extract_sub_549($src, 'botAction');
    $assert->ok(defined $action && $action ne '', 'botAction source extrait');

    $assert->like(
        $action,
        qr/_split_text_for_irc\(\$sMsg\s*,\s*400\s*-\s*\$action_overhead\)/,
        'botAction découpe via le helper partagé (budget - overhead ACTION)'
    );
    $assert->like(
        $action,
        qr/text\s*=>\s*"\\1ACTION \$payload\\1"/,
        'botAction ré-emballe chaque chunk en ACTION distinct'
    );
    $assert->like(
        $action,
        qr/for my \$chunk \(\@chunks\)/,
        'botAction itère sur les chunks'
    );

    # --- 2. Contrat fonctionnel via le helper réel -----------------------
    my $sub_text = _extract_sub_549($src, '_split_text_for_irc');
    my $split;
    {
        no strict; no warnings;
        $split = eval "package T549; use Encode qw(encode); $sub_text; \\&T549::_split_text_for_irc";
    }
    $assert->ok(ref($split) eq 'CODE', '_split_text_for_irc compilé en isolation');

    my $overhead = length("\1ACTION \1");   # 9

    my $wrap_max = sub {
        my ($msg) = @_;
        my @chunks = $split->($msg, 400 - $overhead);
        @chunks = ($msg) unless @chunks;
        my $max = 0;
        for my $c (@chunks) {
            my $payload = utf8::is_utf8($c) ? encode('UTF-8', $c) : $c;
            my $line    = "\1ACTION " . $payload . "\1";
            $max = length($line) if length($line) > $max;
        }
        return (scalar(@chunks), $max);
    };

    my $accents = "\x{e9}" x 400;   # 800 octets
    utf8::upgrade($accents);
    my ($n1, $m1) = $wrap_max->($accents);
    $assert->ok($m1 <= 400, "ACTION accentuée : chaque ligne emballée <= 400 octets (max=$m1)");
    $assert->ok($n1 >= 2,   'ACTION accentuée de 800 octets découpée');

    my ($n2, $m2) = $wrap_max->("\x{1F600}" x 200);   # emojis
    $assert->ok($m2 <= 400, "ACTION emojis : chaque ligne emballée <= 400 octets (max=$m2)");

    my ($n3, $m3) = $wrap_max->('petit /me');
    $assert->is($n3, 1, 'ACTION courte : un seul ACTION (comportement inchangé)');
};
