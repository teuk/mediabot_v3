# t/cases/773_mb589_plugin_auth_bridge.t
# =============================================================================
# mb589 — arc plugins v2, increment 4 : le pont d'autorisation.
#   [1] contrat : level 0 (public) et descriptions USER_LEVEL valides ;
#       entier >0 = message de migration ; description mal formee refusee.
#   [2] montage d'une commande 'Master' (le refus mb587 a saute).
#   [3] dispatch : non authentifie -> refus + notice + methode NON appelee ;
#       authentifie niveau suffisant -> appelee (semantique maison : le
#       niveau numerique de l'utilisateur doit etre <= niveau requis) ;
#       authentifie insuffisant -> refus ; pas de message ctx -> refus
#       silencieux (pas de notice a personne) ; level 0 -> aucun check.
#   [4] la verification se joue a CHAQUE dispatch (jamais figee au montage).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

{
    package T773::Guard;
    our $CALLS = 0;
    sub manifest {
        return { api => 2, name => 'guard', version => '1.0',
                 commands => {
                     open773  => { help => 'Public.', level => 0 },
                     vault773 => { help => 'Master only.', level => 'Master' },
                 } };
    }
    sub register { bless {}, shift }
    sub command_open773  { $T773::Guard::CALLS++; 'open' }
    sub command_vault773 { $T773::Guard::CALLS++; 'vault' }
    $INC{'T773/Guard.pm'} = __FILE__;
}
{
    package User773;
    sub new { my ($c,%a)=@_; bless {%a}, $c }
    sub level            { $_[0]{level} }
    sub is_authenticated { $_[0]{auth} ? 1 : 0 }
}
{
    package Ctx773;
    sub new { my ($c,%a)=@_; bless {%a}, $c }
    sub message { $_[0]{message} }
    sub nick    { $_[0]{nick} }
}
{
    package Bot773;
    sub new {
        require Mediabot::CommandRegistry;
        bless { registry => Mediabot::CommandRegistry->new,
                logger => Log773->new, notices => [] }, shift;
    }
    sub registry { $_[0]{registry} }
    sub events { undef }
    # semantique maison : user_level <= required_level ; table locale.
    sub checkUserLevel {
        my ($self, $ulevel, $required) = @_;
        my %tbl = ( owner => 0, master => 1, administrator => 2, user => 3 );
        my $req = $tbl{ lc $required };
        return 0 unless defined $ulevel && defined $req;
        return $ulevel <= $req ? 1 : 0;
    }
    # le pont identifie via get_user_from_message : la fixture repond depuis
    # le message lui-meme.
    sub get_user_from_message { return $_[1]{user} }
}
{
    package Log773;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, $_[2]; 1 }
}

return sub {
    my ($assert) = @_;

    require Mediabot::PluginManager;

    # le pont passe par Helpers::get_user_from_message et Helpers::botNotice :
    # on les detourne vers la fixture, en local, pour observer les notices.
    require Mediabot::Helpers;
    my @notices;
    no warnings 'redefine';
    local *Mediabot::Helpers::get_user_from_message =
        sub { my ($bot, $msg) = @_; return $bot->get_user_from_message($msg) };
    local *Mediabot::Helpers::botNotice =
        sub { my (undef, $nick, $text) = @_; push @notices, "$nick: $text"; 1 };

    my $bot = Bot773->new;
    my $pm  = Mediabot::PluginManager->new(bot => $bot);

    # [1] contrat
    my $mk = sub { { api => 2, name => 'guard', version => '1.0',
        commands => { c773 => { help => 'h', level => $_[0] } } } };
    { no warnings 'once'; *T773::Guard::command_c773 = sub { 1 }; }
    $assert->ok(!defined $pm->_validate_manifest('T773::Guard', 'guard', $mk->(0)),
        'mb589-773: level 0 valide');
    $assert->ok(!defined $pm->_validate_manifest('T773::Guard', 'guard', $mk->('Master')),
        'mb589-773: description USER_LEVEL valide');
    $assert->like($pm->_validate_manifest('T773::Guard', 'guard', $mk->(5)) // '',
        qr/since mb589 declare 0 \(public\) or a USER_LEVEL description/,
        'mb589-773: entier >0 = message de migration');
    $assert->like($pm->_validate_manifest('T773::Guard', 'guard', $mk->('No!pe')) // '',
        qr/not a valid USER_LEVEL description/,
        'mb589-773: description mal formee refusee');

    # [2] montage de la commande a niveau
    my $entry = $pm->load_perl_module('T773::Guard', name => 'guard');
    $assert->ok($entry, 'mb589-773: plugin avec commande Master charge');
    $assert->is($bot->registry->has_command('vault773', 'public'), 1,
        'mb589-773: la commande a niveau est MONTEE (le refus mb587 a saute)');
    $assert->is($bot->registry->command_for('vault773', 'public')->{level}, 'Master',
        'mb589-773: le level du manifest est porte par l entry registry');

    my $vault = $bot->registry->handler_for('vault773', 'public');
    my $open  = $bot->registry->handler_for('open773',  'public');
    my $msg_for = sub { { user => $_[0] } };

    # [3] refus : non authentifie
    $T773::Guard::CALLS = 0; @notices = ();
    my $out = $vault->(Ctx773->new(nick => 'SlaY',
        message => $msg_for->(User773->new(level => 0, auth => 0))));
    $assert->ok(!defined $out, 'mb589-773: non authentifie — refus');
    $assert->is($T773::Guard::CALLS, 0, 'mb589-773: methode non appelee');
    $assert->like($notices[0] // '', qr/SlaY: Access denied: 'vault773' requires Master level\./,
        'mb589-773: notice de refus au nick');

    # authentifie niveau suffisant (Owner=0 <= Master=1)
    @notices = ();
    $out = $vault->(Ctx773->new(nick => 'teuk',
        message => $msg_for->(User773->new(level => 0, auth => 1))));
    $assert->is($out, 'vault', 'mb589-773: Owner passe une commande Master');
    $assert->is($T773::Guard::CALLS, 1, 'mb589-773: methode appelee');
    $assert->is(scalar @notices, 0, 'mb589-773: aucune notice quand autorise');

    # authentifie insuffisant (User=3 > Master=1)
    $out = $vault->(Ctx773->new(nick => 'rando',
        message => $msg_for->(User773->new(level => 3, auth => 1))));
    $assert->ok(!defined $out, 'mb589-773: niveau insuffisant — refus');
    $assert->is($T773::Guard::CALLS, 1, 'mb589-773: methode non re-appelee');
    $assert->like($notices[-1] // '', qr/rando: Access denied/,
        'mb589-773: refus notifie');

    # pas de message dans le ctx : refus SILENCIEUX
    @notices = ();
    $out = $vault->(Ctx773->new(nick => 'ghost', message => undef));
    $assert->ok(!defined $out, 'mb589-773: sans message — refus fail-closed');
    $assert->is(scalar @notices, 0, 'mb589-773: refus silencieux sans contexte');

    # level 0 : aucun check, meme non authentifie
    $out = $open->(Ctx773->new(nick => 'anyone',
        message => $msg_for->(User773->new(level => 9, auth => 0))));
    $assert->is($out, 'open', 'mb589-773: level 0 reste public');

    # [4] structurel : verification au dispatch, dans le wrapper
    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/PluginManager.pm' or die $!; local $/; <$fh> };
    $assert->like($src, qr/verifie a CHAQUE\n.*# dispatch, jamais fige au montage/,
        'mb589-773: autorisation par dispatch documentee');
    $assert->like($src, qr/_plugin_command_authorized\(\$self->\{bot\}, \$ctx, \$spec->\{level\}\)/,
        'mb589-773: le wrapper appelle le pont avec le level du manifest');
};
