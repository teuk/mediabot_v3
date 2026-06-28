# t/cases/563_mb344_botaction_crlf_strip.t
# =============================================================================
# mb344 — botAction neutralise les sauts de ligne (parité botPrivmsg/botNotice).
#
# botPrivmsg (mb325) et botNotice retirent `[\r\n]+` avant l'envoi IRC. botAction
# ne le faisait PAS : un ACTION contenant un CR/LF terminait la ligne IRC
# prématurément et le reste devenait une commande IRC injectée
# (\1ACTION x\r\nPRIVMSG #autre :... \1). _split_text_for_irc ne retire pas les
# \r\n. mb344 ajoute le strip à botAction, alignant les 3 émetteurs.
#
# Ce test :
#   1. reproduit le pipeline d'envoi botAction (strip + split + wrap via le vrai
#      _split_text_for_irc) et prouve qu'aucune ligne émise ne contient \r ou \n ;
#   2. scan de source : les 3 émetteurs strippent bien [\r\n]+.
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

sub _slurp_563 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_563(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));

    # Vrai helper de découpage.
    my ($sub_text) = $src =~ /(sub _split_text_for_irc \{.*?\n\})/s;
    my $split;
    {
        no strict; no warnings;
        $split = eval "package T563; use Encode qw(encode); $sub_text \\&T563::_split_text_for_irc";
    }
    $assert->ok(ref($split) eq 'CODE', '_split_text_for_irc compilé');

    # Reproduction du pipeline d'envoi botAction (mb344 + mb327).
    my $emit = sub {
        my ($msg) = @_;
        $msg =~ s/[\r\n]+/ /g;                        # mb344-B1
        my $overhead = length("\1ACTION \1");
        my @chunks = $split->($msg, 400 - $overhead); # mb327-B1
        @chunks = ($msg) unless @chunks;
        my @lines;
        for my $c (@chunks) {
            next unless defined($c) && $c ne '';
            my $payload = utf8::is_utf8($c) ? encode('UTF-8', $c) : $c;
            push @lines, "\1ACTION $payload\1";
        }
        return @lines;
    };

    # Tentative d'injection : CRLF suivi d'une commande IRC.
    my @lines = $emit->("slaps bob\r\nPRIVMSG #evil :owned\r\nQUIT");
    my $any_nl = grep { /[\r\n]/ } @lines;
    $assert->is($any_nl, 0, 'aucune ligne ACTION émise ne contient \\r ou \\n (injection neutralisée)');

    # Le contenu reste présent (juste aplati en une ligne), pas perdu.
    my $joined = join('', @lines);
    $assert->like($joined, qr/slaps bob/, 'le texte légitime est conservé');
    $assert->like($joined, qr/\x01ACTION .*\x01/, 'wrapper ACTION intact');

    # ACTION normale inchangée (pas de CRLF -> un seul ACTION).
    my @normal = $emit->('slaps bob around with a large trout');
    $assert->is(scalar(@normal), 1, 'ACTION normale : un seul ACTION');

    # --- Scan de source : parité des 3 émetteurs ------------------------
    for my $name (qw(botPrivmsg botNotice botAction)) {
        my ($body) = $src =~ /(sub \Q$name\E \{.*?\n\}\n)/s;
        $body //= '';
        $assert->like($body, qr/\$\w+ =~ s\/\[\\r\\n\]\+\/ \/g/,
                      "$name retire [\\r\\n]+ avant l'envoi");
    }
    $assert->like($src, qr/mb344-B1/, 'tag mb344-B1 présent');
};
