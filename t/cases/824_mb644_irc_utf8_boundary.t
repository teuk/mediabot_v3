# t/cases/824_mb644_irc_utf8_boundary.t
# =============================================================================
# mb644 — une seule frontiere UTF-8 entre le fil IRC et l'application.
#
# Incident terrain : Net::Async::IRC livre le texte PRIVMSG en OCTETS UTF-8
# (probe reel: utf8_flag=0, C3 A9 pour « e accent aigu »), tandis que
# DBD::MariaDB 1.24 rend/attend les colonnes texte comme chaines Perl Unicode.
# Passer les octets directement au driver transforme C3 A9 en C3 83 C2 A9,
# c'est-a-dire le mojibake classique. La correction decode donc les PRIVMSG
# valides UNE fois avant le code applicatif, sans toucher aux octets invalides.
# =============================================================================

use strict;
use warnings;
use utf8;
use Encode qw(encode);
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

return sub {
    my ($assert) = @_;

    require Mediabot::Helpers;

    my $decode = \&Mediabot::Helpers::decode_irc_text;

    # [1] La forme reelle observee sur le fil devient une chaine de caracteres.
    my $wire = encode('UTF-8', "UTF8PROBE: é è à ç œ — ’");
    my $wire_before = $wire;
    my $chars = $decode->($wire);
    $assert->ok(utf8::is_utf8($chars),
        'mb644-824: octets UTF-8 valides -> chaine Perl Unicode');
    $assert->is($chars, "UTF8PROBE: é è à ç œ — ’",
        'mb644-824: tous les caracteres sont conserves');
    $assert->is($wire, $wire_before,
        'mb644-824: le decodage ne consomme/modifie jamais la source');

    # [2] Une chaine deja decodee est idempotente.
    my $already = "piège de cristal — été";
    my $again = $decode->($already);
    $assert->ok(utf8::is_utf8($again),
        'mb644-824: chaine deja Unicode reste Unicode');
    $assert->is($again, $already,
        'mb644-824: chaine deja Unicode inchangee');

    # [3] ASCII suit le meme contrat interne (caracteres, contenu identique).
    my $ascii = 'm update';
    my $ascii_chars = $decode->($ascii);
    $assert->is($ascii_chars, 'm update',
        'mb644-824: ASCII inchange');
    $assert->ok(utf8::is_utf8($ascii_chars),
        'mb644-824: ASCII entrant appartient aussi au monde caracteres');

    # [4] Ne jamais inventer un charset pour une entree IRC legacy/invalide.
    my $invalid = "legacy:\xFF\xFE";
    my $invalid_before = $invalid;
    my $kept = $decode->($invalid);
    $assert->ok(!utf8::is_utf8($kept),
        'mb644-824: octets invalides restent des octets');
    $assert->is(unpack('H*', $kept), unpack('H*', $invalid_before),
        'mb644-824: octets invalides conserves exactement');
    $assert->is($invalid, $invalid_before,
        'mb644-824: entree invalide non modifiee en place');

    # [5] Contrat de branchement : la normalisation est la premiere operation
    # applicative sur $what, avant ignore/log/DB/dispatch.
    my $src = do {
        open my $fh, '<:raw', 'mediabot.pl' or die $!;
        local $/;
        <$fh>;
    };
    my ($body) = $src =~ /sub _on_message_PRIVMSG_body \{(.*?)^\}/ms;
    $assert->ok(defined $body,
        'mb644-824: corps PRIVMSG localise');
    my $extract = index($body, 'my ($who, $where, $what) = @{$hints}{qw<prefix_nick targets text>};');
    my $channel = index($body, 'my $is_channel = _irc_target_is_channel($where);');
    my $norm    = index($body, '$what = Mediabot::Helpers::decode_irc_text($what)');
    my $guard   = index($body, '$is_channel || !_private_message_is_sensitive($what)');
    my $ignore  = index($body, '$mediabot->isIgnored(');
    my $seen    = index($body, 'last_msg   => $what');
    my $live    = index($body, '[LIVE] $where: <$who> $what');
    my $split   = index($body, 'my ($sCommand,@tArgs) = split(/\\s+/,$line);');
    $assert->ok($extract >= 0 && $channel > $extract && $norm > $channel,
        'mb644-824: normalisation installee a la frontiere IRC');
    $assert->ok($guard > $norm,
        'mb644-824: commandes privees sensibles gardent leurs octets historiques');
    $assert->ok($ignore > $norm && $seen > $norm && $live > $norm && $split > $norm,
        'mb644-824: ignore, DB seen, logs et dispatch publics voient les caracteres');

    # [6] Le probe temporaire et les anciens decode Hailo destructifs ont disparu.
    $assert->ok(index($src, 'MB_UTF8_RUNTIME_PROBE_') < 0,
        'mb644-824: aucun probe runtime temporaire dans le depot');
    $assert->ok($src !~ /\$what\s*=\s*decode\s*\(\s*["']UTF-8["']/,
        'mb644-824: aucun second decode UTF-8 direct de $what dans mediabot.pl');

    my $med = do {
        open my $fh, '<:raw', 'Mediabot/Mediabot.pm' or die $!;
        local $/;
        <$fh>;
    };
    my ($nick_trigger) = $med =~ /sub mbHandleNickTriggered \{(.*?)^\}/ms;
    $assert->ok(defined($nick_trigger) &&
                $nick_trigger =~ /Mediabot::Helpers::decode_irc_text\(\$what\)/,
        'mb644-824: entree Hailo directe reutilise le helper idempotent');
    $assert->ok(!defined($nick_trigger) ||
                $nick_trigger !~ /decode\s*\(\s*["']UTF-8["']/,
        'mb644-824: Hailo ne double-decode plus une chaine deja Unicode');
};
