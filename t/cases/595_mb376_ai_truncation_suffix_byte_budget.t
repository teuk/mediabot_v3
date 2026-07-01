# t/cases/595_mb376_ai_truncation_suffix_byte_budget.t
# =============================================================================
# mb376 — Le suffixe de troncature fait partie du budget d'OCTETS IRC.
#
# mb374 a rendu _chatgpt_wrap byte-safe, mais les deux blocs de troncature
# continuaient à calculer la place du suffixe via length()/substr() en
# CARACTÈRES. Le suffixe ChatGPT contient de l'UTF-8 : la dernière ligne pouvait
# dépasser WRAP_BYTES, être re-découpée en aval et faire mentir MAX_PRIVMSG.
# mb376 centralise l'ajout du suffixe dans _fit_truncation_suffix().
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";

    # Dépendances non nécessaires au helper testé, mais importées à la
    # compilation du module. Les vrais modules sont présents sur le serveur.
    $INC{'JSON/MaybeXS.pm'} = 1;
    package JSON::MaybeXS;
    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::decode_json"} = sub { die 'decode_json stub not used' };
        *{"${caller}::encode_json"} = sub { die 'encode_json stub not used' };
    }

    $INC{'URI/Escape.pm'} = 1;
    package URI::Escape;
    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::uri_escape_utf8"} = sub { $_[0] };
    }

    package main;
}

use Encode qw(encode);
use File::Spec;

# Minimal faithful runtime dependency for the helper under test.
BEGIN {
    package Mediabot::Helpers;
    sub _split_text_for_irc {
        my ($text, $max_bytes) = @_;
        return () unless defined($text) && $text ne '';
        my $wire = sub {
            return utf8::is_utf8($_[0])
                ? length(Encode::encode('UTF-8', $_[0]))
                : length($_[0]);
        };
        return ($text) if $wire->($text) <= $max_bytes;

        my ($prefix, $used) = ('', 0);
        for my $ch (split //, $text) {
            my $cost = $wire->($ch);
            last if $used + $cost > $max_bytes;
            $prefix .= $ch;
            $used += $cost;
        }
        return ($prefix);
    }
}

require Mediabot::External::Claude;

sub _wire_bytes_595 {
    my ($s) = @_;
    return utf8::is_utf8($s) ? length(encode('UTF-8', $s)) : length($s);
}

sub _old_append_595 {
    my ($chunk, $suffix, $budget) = @_;
    my $allow = $budget - length($suffix);       # ancien bug: caractères
    if (length($chunk) > $allow) {
        $chunk = substr($chunk, 0, $allow);      # ancien bug: caractères
        $chunk =~ s/\s+\S*$//;
        $chunk =~ s/\s+$//;
    }
    return $chunk . $suffix;
}

sub _slurp_595 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $budget = 400;
    my $suffix = ' [¯\\_(ツ)_/¯ guess you can’t have everything…]';
    my $chunk  = ('é' x 180);                    # 360 octets, 180 caractères

    # Témoin concret : l'ancien code ne tronquait pas le chunk et dépassait.
    my $old = _old_append_595($chunk, $suffix, $budget);
    $assert->ok(_wire_bytes_595($old) > $budget,
        'témoin: ancien ajout char-based dépasse le budget avec suffixe UTF-8');

    my $new = Mediabot::External::Claude::_fit_truncation_suffix(
        $chunk, $suffix, $budget,
    );
    $assert->ok(_wire_bytes_595($new) <= $budget,
        'nouveau helper: ligne ChatGPT complète <= budget en octets');
    $assert->like($new, qr/\Q$suffix\E\z/, 'suffixe ChatGPT conservé intégralement');

    # Emoji : le préfixe reste un scalaire UTF-8 valide et ne perd pas le suffixe.
    my $emoji_suffix = ' [truncated]';
    my $emoji = '😀' x 120;
    my $emoji_out = Mediabot::External::Claude::_fit_truncation_suffix(
        $emoji, $emoji_suffix, 200,
    );
    $assert->ok(_wire_bytes_595($emoji_out) <= 200, 'emoji: résultat <= 200 octets');
    $assert->like($emoji_out, qr/\Q$emoji_suffix\E\z/, 'emoji: suffixe conservé');
    (my $emoji_prefix = $emoji_out) =~ s/\Q$emoji_suffix\E\z//;
    $assert->unlike($emoji_prefix, qr/�/, 'emoji: aucun caractère de remplacement');

    # Claude ASCII suit le même helper et reste strictement borné.
    my $claude = Mediabot::External::Claude::_fit_truncation_suffix(
        ('word ' x 100), ' [truncated]', 120,
    );
    $assert->ok(_wire_bytes_595($claude) <= 120, 'suffixe Claude: résultat <= budget');
    $assert->like($claude, qr/ \[truncated\]\z/, 'suffixe Claude conservé');

    # Cas défensifs.
    $assert->is(
        Mediabot::External::Claude::_fit_truncation_suffix('abc', '!', 20),
        'abc!',
        'texte court: suffixe ajouté sans modification',
    );
    my $tiny = Mediabot::External::Claude::_fit_truncation_suffix('abcdef', 'XYZ', 5);
    $assert->ok(_wire_bytes_595($tiny) <= 5, 'petit budget défensif respecté');

    # Scan de source : les deux chemins utilisent le helper, plus l'ancien calcul.
    my $src = _slurp_595(File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm'));
    $assert->like($src, qr/sub _irc_wire_bytes/, 'helper de coût wire défini');
    $assert->like($src, qr/sub _irc_prefix_for_budget/, 'helper de préfixe byte-safe défini');
    $assert->like($src, qr/sub _fit_truncation_suffix/, 'helper de suffixe byte-safe défini');
    my @helper_hits = $src =~ /_fit_truncation_suffix\(/g;
    $assert->ok(scalar(@helper_hits) >= 2, 'helper utilisé par OpenAI + Claude');
    $assert->unlike($src, qr/my \$allow = \$\w*wrap_bytes - length\(\$suff\)/,
        'plus de calcul de budget du suffixe en caractères');
    $assert->unlike($src, qr/substr\(\$chunk\[\$last\], 0, \$allow\)/,
        'plus de troncature finale char-based');
    $assert->like($src, qr/mb376-B1/, 'tag mb376-B1 présent');
};
