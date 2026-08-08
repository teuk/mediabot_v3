# t/cases/805_mb622_horoscope_alias_async.t
# =============================================================================
# mb622 — horoscope/horo : meme chemin asynchrone.
#
# Depuis mb620, la commande peut faire HTTP + traduction Claude. Toute forme
# publique doit donc passer par CommandAsync ; l'alias court ne doit jamais
# reintroduire un appel synchrone sur la boucle IRC.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

return sub {
    my ($assert) = @_;

    my $path = 'Mediabot/Mediabot.pm';
    open my $fh, '<:raw', $path or die "$path: $!";
    local $/;
    my $src = <$fh>;
    close $fh;

    my ($dispatch) = $src =~ /(horoscope\s*=>.*?horo\s*=>.*?# alias court[^\n]*)/s;
    $dispatch //= '';

    my $long = () = $dispatch =~ /horoscope\s*=>\s*sub\s*\{\s*Mediabot::CommandAsync::run_ctx_async\(\$ctx->bot,\s*\$ctx,\s*'horoscope'/g;
    my $short = () = $dispatch =~ /horo\s*=>\s*sub\s*\{\s*Mediabot::CommandAsync::run_ctx_async\(\$ctx->bot,\s*\$ctx,\s*'horoscope'/g;

    $assert->is($long, 1,
        'mb622-805: horoscope passe une fois par CommandAsync avec label canonique');
    $assert->is($short, 1,
        'mb622-805: horo passe une fois par le meme CommandAsync/label');
    $assert->unlike($dispatch, qr/horo\s*=>\s*sub\s*\{\s*mbHoroscope_ctx\(/,
        'mb622-805: aucun alias horo synchrone ne subsiste');

    $assert->like($src,
        qr/^horoscope\|horoscope \[nick\\\|signe\]\|public\|/m,
        'mb622-805: aide horoscope annonce nick ou signe');
    $assert->like($src,
        qr/^horo\|horo \[nick\\\|signe\]\|public\|Alias for horoscope\./m,
        'mb622-805: aide horo annonce le meme contrat');

    open my $hh, '<:raw', 'Mediabot/External/Horoscope.pm' or die $!;
    local $/;
    my $hsrc = <$hh>;
    close $hh;
    $assert->unlike($hsrc, qr/module n'utilise pas .use utf8./,
        'mb622-805: commentaire Horoscope ne contredit plus use utf8');
};
