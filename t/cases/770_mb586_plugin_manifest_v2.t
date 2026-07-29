# t/cases/770_mb586_plugin_manifest_v2.t
# =============================================================================
# mb586 — arc plugins v2, increment 1 : le MANIFEST.
#   [1] _validate_manifest unitaire : cas valide complet ; api!=2 ; name
#       absent/slug invalide/usurpation ; version invalide ; commandes
#       (slug, help, level, collision registry, collision inter-plugins) ;
#       events invalides.
#   [2] compat v1 : un module sans manifest reste accepte (api=1).
#   [3] integration : Demo expose un manifest v2 valide ; load_perl_module
#       le valide AVANT register() (fail-closed) et le stocke dans l'entry.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

{
    package Registry770;
    sub new { bless { cmds => { $_[1] ? %{ $_[1] } : () } }, $_[0] }
    sub has_command { exists $_[0]{cmds}{ lc $_[1] } }
    # mb588: la validation interroge command_for pour distinguer une vraie
    # collision d'un replace de soi-meme (entry->{plugin}).
    sub command_for { exists $_[0]{cmds}{ lc $_[1] } ? { plugin => undef } : undef }
}
{
    package T770::Demo;
    sub command_hello { 1 }
}
{
    package Bot770;
    sub new { bless { registry => Registry770->new($_[1]) }, $_[0] }
    sub registry { $_[0]{registry} }
    sub events { undef }
    sub can { my ($s,$m)=@_; return $s->SUPER::can($m) }
}

return sub {
    my ($assert) = @_;

    require Mediabot::PluginManager;

    my $bot = Bot770->new({ existing => 1 });
    my $pm  = Mediabot::PluginManager->new(bot => $bot);

    my $base = sub { {
        api => 2, name => 'demo', version => '1.0',
        description => 'ok',
        commands => { hello => { help => 'Say hello.', level => 0 } },
        events => ['public_command_observed'],
        %{ $_[0] || {} },
    } };

    # [1] cas valide
    $assert->ok(!defined $pm->_validate_manifest('T770::Demo', 'demo', $base->()),
        'mb586-770: manifest valide complet accepte');

    my @bad = (
        [ 'api manquante',        { api => undef },        qr/api must be/ ],
        [ 'api v1',               { api => 1 },            qr/api must be/ ],
        [ 'name absent',          { name => undef },       qr/name is required/ ],
        [ 'name non slug',        { name => 'De mo!' },    qr/not a valid slug/ ],
        [ 'usurpation de nom',    { name => 'autre' },     qr/does not match registration/ ],
        [ 'version invalide',     { version => 'v1.x' },   qr/version is required/ ],
        [ 'description trop longue', { description => 'x' x 201 }, qr/short scalar/ ],
        [ 'commands non hash',    { commands => [] },      qr/commands must be a HASH/ ],
        [ 'commande non slug',    { commands => { 'Bad Cmd' => { help=>'h', level=>0 } } }, qr/not a valid command name/ ],
        [ 'help absente',         { commands => { ok => { level=>0 } } }, qr/short help string/ ],
        # mb589: le contrat level a evolue — entier>0 = message de migration
        [ 'level entier >0 (migration)', { commands => { ok => { help=>'h', level=>1201 } } }, qr/since mb589 declare 0 \(public\) or a USER_LEVEL description/ ],
        [ 'level description invalide',  { commands => { ok => { help=>'h', level=>'Bad!Level' } } }, qr/not a valid USER_LEVEL description/ ],
        [ 'collision registry',   { commands => { existing => { help=>'h', level=>0 } } }, qr/collides with an existing bot command/ ],
        [ 'events non array',     { events => 'x' },       qr/events must be an ARRAY/ ],
        [ 'event invalide',       { events => ['Bad Ev'] }, qr/simple event names/ ],
    );
    for my $case (@bad) {
        my ($label, $patch, $re) = @$case;
        my $why = $pm->_validate_manifest('T770::Demo', 'demo', $base->($patch));
        $assert->like($why // '', $re, "mb586-770: refuse — $label");
    }

    # collision inter-plugins : un plugin deja enregistre declare 'taken'
    $pm->register_plugin(name => 'first', module => 'X::First',
        manifest => { api=>2, name=>'first', version=>'1.0',
                      commands => { taken => { help=>'h', level=>0 } } });
    my $why = $pm->_validate_manifest('T770::Demo', 'demo',
        $base->({ commands => { taken => { help=>'h', level=>0 } } }));
    $assert->like($why // '', qr/collides with plugin 'first'/,
        'mb586-770: refuse — collision inter-plugins');

    # [2] compat v1 : register_plugin sans manifest -> api=1
    my $legacy = $pm->register_plugin(name => 'oldie', module => 'X::Old');
    $assert->is($legacy->{metadata}{api}, 1, 'mb586-770: plugin v1 legacy accepte (api=1)');
    $assert->ok(!defined $legacy->{manifest}, 'mb586-770: legacy sans manifest');

    # [3] integration Demo v2
    require Mediabot::Plugin::Demo;
    my $dm = Mediabot::Plugin::Demo->manifest;
    $assert->is($dm->{api}, 2, 'mb586-770: Demo declare api 2');
    $assert->ok(!defined $pm->_validate_manifest('Mediabot::Plugin::Demo', 'demo', $dm),
        'mb586-770: manifest de Demo valide');

    my $pm2 = Mediabot::PluginManager->new(bot => Bot770->new({}));
    my $entry = eval { $pm2->load_perl_module('Mediabot::Plugin::Demo', name => 'demo') };
    $assert->ok($entry, 'mb586-770: Demo v2 charge par load_perl_module')
        or $assert->ok(0, "load failed: $@");
    if ($entry) {
        $assert->is($entry->{metadata}{api}, 2, 'mb586-770: entry marquee api 2');
        $assert->is($entry->{manifest}{version}, '0.002',
            'mb586-770: manifest stocke dans l entry (version v2)');
        $assert->is($entry->{version}, '0.002',
            'mb586-770: version de l entry vient du manifest');
    }

    # fail-closed structurel : la validation precede register() dans le source
    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/PluginManager.pm' or die $!; local $/; <$fh> };
    my $i_val = index($src, 'manifest rejected for');
    my $i_reg = index($src, '$module->register($self->{bot}');
    $assert->ok($i_val > -1 && $i_reg > -1 && $i_val < $i_reg,
        'mb586-770: validation AVANT register() — refus sans effet de bord');
};
