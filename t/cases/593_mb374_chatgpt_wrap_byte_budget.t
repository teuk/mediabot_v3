# t/cases/593_mb374_chatgpt_wrap_byte_budget.t
# =============================================================================
# mb374 — Le wrap des réponses IA budgétise en OCTETS, pas en caractères.
#
# _chatgpt_wrap() (utilisé par !ai / !tellme) comptait des CARACTÈRES via
# length()/substr(). Sur du texte accentué (français) ou des emojis, un chunk
# « de 400 » faisait en réalité jusqu'à ~800-1200 octets une fois encodé UTF-8 :
#   - botPrivmsg devait le re-découper en aval ;
#   - le plafond MAX_PRIVMSG ne correspondait plus au nombre réel de lignes.
# mb374 fait déléguer _chatgpt_wrap au découpeur byte-safe partagé
# (_split_text_for_irc, mb325), déjà utilisé par botPrivmsg.
#
# Validation : (a) byte-boundedness (repro de la logique), (b) scan de source.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Encode qw(encode);
use File::Spec;

sub _wire_bytes { return length(encode('UTF-8', $_[0])); }

# Repro fidèle du découpeur byte-safe (_split_text_for_irc, cœur).
sub _byte_split {
    my ($text, $max) = @_;
    return () unless defined($text) && $text ne '';
    return ($text) if _wire_bytes($text) <= $max;
    my @chunks; my $buf = $text;
    while (_wire_bytes($buf) > $max) {
        my ($b, $n) = (0, 0);
        for my $c (split //, $buf) {
            my $cb = ord($c) < 0x80 ? 1 : ord($c) < 0x800 ? 2 : ord($c) < 0x10000 ? 3 : 4;
            last if $b + $cb > $max;
            $b += $cb; $n++;
        }
        $n = 1 if $n < 1;
        my $prefix = substr($buf, 0, $n);
        if ($prefix =~ /^(.*\s)\S+\z/s) {
            my $ws = $1;
            $prefix = $ws if length($ws) >= int($n / 2) && length($ws) >= 1;
        }
        my $cut = length($prefix); $cut = $n if $cut < 1;
        push @chunks, substr($buf, 0, $cut);
        $buf = substr($buf, $cut); $buf =~ s/^\s+//;
    }
    push @chunks, $buf if length($buf);
    return @chunks;
}

# Ancien wrap char-based (référence du bug).
sub _old_char_wrap {
    my ($txt, $wb) = @_;
    my @out;
    while (length $txt) {
        if (length($txt) <= $wb) { push @out, $txt; last; }
        my $sl = substr($txt, 0, $wb);
        my $br = rindex($sl, ' '); $br = $wb if $br == -1;
        push @out, substr($txt, 0, $br, ''); $txt =~ s/^\s+//;
    }
    return @out;
}

sub _slurp_593 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    # --- 1. Byte-boundedness sur de l'accentué ---------------------------
    my $accent = "\x{e9}" x 300;   # 300 'é' = 600 octets UTF-8
    my @new = _byte_split($accent, 400);
    my $over_new = grep { _wire_bytes($_) > 400 } @new;
    $assert->is($over_new, 0, 'nouveau: aucun chunk ne dépasse 400 octets sur le fil');

    # témoin: l'ancien wrap char-based dépassait le budget en octets.
    my @old = _old_char_wrap($accent, 400);
    my $over_old = grep { _wire_bytes($_) > 400 } @old;
    $assert->ok($over_old > 0, 'témoin: ancien wrap char produisait des chunks > 400 octets');

    # ASCII : comportement inchangé (chars == octets).
    my $ascii = "word " x 200;    # ~1000 octets
    my @a = _byte_split($ascii, 400);
    $assert->ok((grep { _wire_bytes($_) > 400 } @a) == 0, 'ASCII: chunks <= 400 octets');
    $assert->ok(@a >= 2, 'ASCII long: découpé en plusieurs chunks');

    # texte court : un seul chunk (fast path).
    my @s = _byte_split("hello", 400);
    $assert->is(scalar(@s), 1, 'texte court -> 1 chunk');
    $assert->is($s[0], 'hello', 'texte court inchangé');

    # emoji (4 octets) : jamais coupé au milieu.
    my $emoji = ("\x{1F600}") x 150;   # 150 * 4 = 600 octets
    my @e = _byte_split($emoji, 400);
    $assert->ok((grep { _wire_bytes($_) > 400 } @e) == 0, 'emoji: chunks <= 400 octets');
    my $joined = join('', @e);
    $assert->is($joined, $emoji, 'emoji: aucun caractère perdu ni coupé');

    # --- 2. Scan de source ------------------------------------------------
    my $src = _slurp_593(File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm'));
    my ($wrap) = $src =~ /(sub _chatgpt_wrap \{.*?\n\}\n)/s; $wrap //= '';
    $assert->ok($wrap ne '', 'sub _chatgpt_wrap présente');
    $assert->like($wrap, qr/Mediabot::Helpers::_split_text_for_irc\(/,
                  '_chatgpt_wrap délègue au découpeur byte-safe partagé');
    # plus de boucle char-based (rindex/substr manuel).
    (my $wrap_code = $wrap) =~ s/^\s*#.*$//mg;
    $assert->unlike($wrap_code, qr/rindex\(\$slice/, 'plus de découpage char-based manuel');
    $assert->like($src, qr/mb374-R1/, 'tag mb374-R1 présent');

    # les 3 chemins IA appellent toujours _chatgpt_wrap (interface préservée).
    my $calls = () = $src =~ /_chatgpt_wrap\(/g;
    $assert->ok($calls >= 3, 'les chemins IA utilisent toujours _chatgpt_wrap');
};
