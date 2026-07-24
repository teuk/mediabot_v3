# t/cases/755_mb564_ban_action.t
# =============================================================================
# mb564 — actions ban/unban (MODE +b/-b) pour le bridge de scripts :
#   [1] validation : mask complet nick!user@host obligatoire (jokers *?
#       admis par segment), 90 octets max, charset strict, aucun target,
#       contexte canal canonicalisé (STATUSMSG @#chan -> #chan) ;
#   [2] gates : apply + ALLOW_IRC + ALLOW_BAN (défaut non), erreurs
#       distinctes ; unban partage le même gate ;
#   [3] anti-self fail-closed pour BAN : segment nick LITTÉRAL égal au
#       nick du bot -> refus ; identité indisponible -> refus ; segment avec
#       joker -> passe. UNBAN reste disponible comme chemin de réparation ;
#   [4] envoi : MODE +b pour ban, MODE -b pour unban, sur le canal validé ;
#   [5] gatekeeper v2 : ban=yes -> action ban (nick!*@*) AVANT le kick,
#       défaut -> kick seul (zéro régression), log truthful ban+kick ;
#   [6] plumbing : ALLOW_BAN collecté (5 clés), normalisé, passé aux
#       runners, documenté (partyline + sample.conf + README).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::ScriptActionRunner;

sub _slurp_755 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{
    package IRC755;
    sub new { my ($class, %h) = @_; bless { sent => [], %h }, $class }
    sub can { 1 }
    sub is_nick_me {
        my ($self, $nick) = @_;
        die "boom" if $self->{explode};
        return lc($nick) eq lc($self->{me} // 'mediabot') ? 1 : 0;
    }
    sub send_message { my ($self, @args) = @_; push @{ $self->{sent} }, [ @args ]; 1 }
}

use JSON::PP ();

sub _runner_755 {
    my (%h) = @_;
    my $irc = delete $h{irc};
    return Mediabot::ScriptActionRunner->new(bot => { irc => $irc });
}

sub _apply_755 {
    my ($runner, $actions, %opts) = @_;
    my $script_result = { ok => 1, response => {
        protocol => 'mediabot-script-v1',
        ok       => JSON::PP::true,
        actions  => $actions,
    } };
    my $res = $runner->apply_actions($script_result,
        { channel => ($opts{channel} // '#lab') },
        apply     => 1,
        allow_irc => (exists $opts{allow_irc} ? $opts{allow_irc} : 1),
        allow_ban => (exists $opts{allow_ban} ? $opts{allow_ban} : 1),
    );
    return { errors => $res->{apply_errors} || [], applied => $res->{applied} || [] };
}

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # [1] Validation
    # ------------------------------------------------------------------
    {
        my $runner = _runner_755(irc => IRC755->new);

        my ($ok, $err, $act) = $runner->validate_action(
            { type => 'ban', mask => 'Intruder!*@*' }, { channel => '#lab' });
        $assert->ok($ok && $act->{type} eq 'ban' && $act->{mask} eq 'Intruder!*@*'
            && $act->{target} eq '#lab',
            'ban valide: mask complet, canal du contexte');

        ($ok, $err) = $runner->validate_action(
            { type => 'ban', mask => 'Intruder' }, { channel => '#lab' });
        $assert->ok(!$ok && $err =~ /nick!user\@host/, 'mask sans !@ refuse');

        ($ok, $err) = $runner->validate_action(
            { type => 'ban', mask => 'a!b@c', target => '#ailleurs' }, { channel => '#lab' });
        $assert->ok(!$ok && $err =~ /takes no target/, 'target explicite refuse');

        ($ok, $err) = $runner->validate_action(
            { type => 'ban', mask => 'bad mask!u@h' }, { channel => '#lab' });
        $assert->ok(!$ok, 'espace dans le mask refuse');

        ($ok, $err) = $runner->validate_action(
            { type => 'ban', mask => ('x' x 80) . '!u@h.tld' }, { channel => '#lab' });
        $assert->ok(!$ok, 'mask > 90 octets ou segment > 32 refuse');

        ($ok, $err, $act) = $runner->validate_action(
            { type => 'unban', mask => '*!*@spam.example' }, { channel => '@#lab' });
        $assert->ok($ok && $act->{target} eq '#lab',
            'unban: STATUSMSG @#chan canonicalise en #chan');
    }

    # ------------------------------------------------------------------
    # [2] Gates + [3] anti-self + [4] envoi
    # ------------------------------------------------------------------
    {
        my $irc = IRC755->new(me => 'mediabot');
        my $runner = _runner_755(irc => $irc);
        my $ban = { type => 'ban', mask => 'Intruder!*@*' };

        my $res = _apply_755($runner, [ $ban ], allow_irc => 0);
        $assert->ok($res->{errors}[0]{error} =~ /require allow_irc/,
            'gate: allow_irc ferme -> erreur dediee');

        $res = _apply_755($runner, [ $ban ], allow_ban => 0);
        $assert->ok($res->{errors}[0]{error} =~ /require allow_ban/,
            'gate: allow_ban ferme -> erreur dediee');

        $res = _apply_755($runner, [ { type => 'ban', mask => 'MediaBot!*@*' } ]);
        $assert->ok($res->{errors}[0]{error} =~ /refusing to ban the bot itself/,
            'anti-self: nick litteral du bot refuse (insensible casse)');

        $irc->{sent} = [];
        $res = _apply_755($runner, [ { type => 'unban', mask => 'MediaBot!*@*' } ]);
        $assert->ok(!@{ $res->{errors} || [] } && @{ $irc->{sent} } == 1
            && $irc->{sent}[0][3] eq '-b',
            'unban du mask littéral du bot reste autorisé comme réparation');

        my $noid = _runner_755(irc => IRC755->new(explode => 1));
        $res = _apply_755($noid, [ $ban ]);
        $assert->ok($res->{errors}[0]{error} =~ /cannot verify bot identity/,
            'anti-self: identite indisponible -> fail-closed');

        $res = _apply_755($runner, [ { type => 'ban', mask => 'Media*!*@*' } ]);
        $assert->ok(!@{ $res->{errors} || [] },
            'joker dans le segment nick: indecidable -> passe (gate explicite)');

        $irc->{sent} = [];
        $res = _apply_755($runner, [ $ban, { type => 'unban', mask => '*!*@spam.tld' } ]);
        $assert->ok(!@{ $res->{errors} || [] } && @{ $irc->{sent} } == 2,
            'ban + unban appliques');
        $assert->is(join('|', @{ $irc->{sent}[0] }), 'MODE||#lab|+b|Intruder!*@*',
            'wire: MODE +b mask sur le canal');
        $assert->is(join('|', @{ $irc->{sent}[1] }), 'MODE||#lab|-b|*!*@spam.tld',
            'wire: MODE -b mask');
    }

    # ------------------------------------------------------------------
    # [5] gatekeeper v2 + [6] plumbing (gardes statiques)
    # ------------------------------------------------------------------
    {
        my $gk = _slurp_755(File::Spec->catfile('plugins', 'scripts', 'examples', 'gatekeeper.pl'));
        $assert->like($gk, qr/lc\("\$config->\{ban\}"\) eq 'yes'/,
            'gatekeeper v2: opt-in ban=yes strict');
        $assert->like($gk, qr/type => 'ban', mask => "\$nick!\*\\\@\*" .* if \$want_ban;/,
            'gatekeeper v2: ban conditionnel, mask nick!*@*');
        my $ban_pos = index($gk, "type => 'ban'");
        my $kick_pos = index($gk, "type => 'kick'");
        $assert->ok($ban_pos > -1 && $kick_pos > $ban_pos,
            'gatekeeper v2: le ban est emis AVANT le kick');
        $assert->like($gk, qr/'gatekeeper: ' \. \(\$want_ban \? 'ban\+kick' : 'kick'\)/,
            'gatekeeper v2: log truthful ban+kick / kick');

        my $plugin = _slurp_755(File::Spec->catfile('Mediabot', 'Plugin', 'ScriptDryRun.pm'));
        $assert->like($plugin, qr/'plugins\.ScriptDryRun\.ALLOW_BAN'/,
            'plumbing: ALLOW_BAN collecte');
        $assert->like($plugin, qr/\{allow_ban\}\s+= _truthy\(\$self->\{allow_ban_raw\}\)/,
            'plumbing: normalisation truthy');
        $assert->like($plugin, qr/\$fp\{allow_ban\}\s+= \$self->\{allow_ban\}/,
            'hot reload: ALLOW_BAN présent dans le fingerprint');
        my $sites = () = $plugin =~ /allow_ban\s*=> \$self->allow_ban,/g;
        $assert->ok($sites == 6, 'plumbing: allow_ban passe aux 6 sites runner');

        my $sample = _slurp_755('mediabot.sample.conf');
        $assert->like($sample, qr/^#ALLOW_BAN=no$/m, 'sample.conf: gate documente');

        my $partyline = _slurp_755(File::Spec->catfile('Mediabot', 'Partyline.pm'));
        $assert->like($partyline, qr/plugins\.ScriptDryRun\.ALLOW_BAN/,
            'partyline: cle documentee');
        $assert->like($partyline, qr/ban gate: ban\/unban actions/,
            'partyline: gate explique');
    }
};
