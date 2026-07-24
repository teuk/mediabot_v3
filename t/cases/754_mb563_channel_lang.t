# t/cases/754_mb563_channel_lang.t
# =============================================================================
# mb563 — langue par canal via chansets :
#   [1] Helpers::channel_lang : +LangFR -> 'fr', +LangES -> 'es', FR gagne si
#       les deux, aucun flag -> main.LANG global, pas de canal (PM) -> global,
#       base non migrée (chanset inconnu -> default 0) -> global ;
#   [2] le 8ball consomme channel_lang (plus de lecture directe main.LANG) ;
#   [3] migration data-only présente et idempotente (WHERE NOT EXISTS) pour
#       les DEUX chansets, aucun ALTER/CREATE TABLE.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::Helpers;

sub _slurp_754 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{
    package Conf754;
    sub new { my ($class, %kv) = @_; bless { %kv }, $class }
    sub get { my ($self, $k) = @_; return $self->{$k} }
}

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # [1] Précédence — chanset_enabled pilotée localement
    # ------------------------------------------------------------------
    {
        my %flags;   # "chan chanset" => 0|1
        no warnings 'redefine';
        local *Mediabot::Helpers::chanset_enabled = sub {
            my ($self, $channel, $name, %opts) = @_;
            return exists $flags{"$channel $name"}
                ? $flags{"$channel $name"}
                : (exists $opts{default} ? $opts{default} : 0);
        };

        my $bot = { conf => Conf754->new('main.LANG' => 'en') };

        %flags = ("#fr LangFR" => 1);
        $assert->is(Mediabot::Helpers::channel_lang($bot, '#fr'), 'fr',
            '+LangFR -> fr');

        %flags = ("#es LangES" => 1);
        $assert->is(Mediabot::Helpers::channel_lang($bot, '#es'), 'es',
            '+LangES -> es');

        %flags = ("#both LangFR" => 1, "#both LangES" => 1);
        $assert->is(Mediabot::Helpers::channel_lang($bot, '#both'), 'fr',
            'les deux flags -> FR gagne');

        %flags = ();
        $assert->is(Mediabot::Helpers::channel_lang($bot, '#plain'), 'en',
            'aucun flag -> main.LANG global');

        $assert->is(Mediabot::Helpers::channel_lang($bot, undef), 'en',
            'PM (pas de canal) -> global');

        my $bot_fr = { conf => Conf754->new('main.LANG' => 'fr') };
        %flags = ();
        $assert->is(Mediabot::Helpers::channel_lang($bot_fr, '#plain'), 'fr',
            'global fr respecte sans flag');

        my $bot_noconf = { conf => Conf754->new() };
        $assert->is(Mediabot::Helpers::channel_lang($bot_noconf, '#x'), 'en',
            'main.LANG absent -> en');
    }

    # Base non migrée : chanset inconnu -> chanset_enabled réel rend default(0)
    # -> global. On le prouve sur la vraie chanset_enabled avec un self sans
    # DB fonctionnelle (getIdChansetList échoue -> default).
    {
        my $bot = { conf => Conf754->new('main.LANG' => 'en'), logger => undef };
        my $lang = eval { Mediabot::Helpers::channel_lang($bot, '#chan') };
        $assert->is($lang // 'CRASH', 'en',
            'base non migrée/indisponible -> comportement global historique');
    }

    # ------------------------------------------------------------------
    # [2] Le 8ball consomme le helper
    # ------------------------------------------------------------------
    {
        my $src = _slurp_754(File::Spec->catfile('Mediabot', 'UserCommands.pm'));
        my ($ball) = $src =~ /(sub mb8ball_ctx \{.*?\n\})/s;
        $assert->ok(defined $ball, 'source de mb8ball_ctx isolee');
        $assert->like($ball, qr/Mediabot::Helpers::channel_lang\(\$self, \$channel\)/,
            '8ball: langue via channel_lang');
        $assert->unlike($ball, qr/conf\}->get\('main\.LANG'\)/,
            '8ball: plus de lecture directe de main.LANG');
    }

    # ------------------------------------------------------------------
    # [3] Migration data-only idempotente
    # ------------------------------------------------------------------
    {
        my $mig = _slurp_754(File::Spec->catfile('install', 'migrations',
            '20260724_lang_chansets.sql'));
        for my $cs ('LangFR', 'LangES') {
            $assert->like($mig,
                qr/INSERT INTO CHANSET_LIST \(chanset\)\nSELECT '\Q$cs\E'\nWHERE NOT EXISTS/,
                "migration: $cs idempotent");
        }
        $assert->unlike($mig, qr/ALTER TABLE|CREATE TABLE/i,
            'migration: data-only, aucun changement de schema');

        my $schema = _slurp_754(File::Spec->catfile('install', 'mediabot.sql'));
        for my $cs ('LangFR', 'LangES') {
            $assert->like($schema, qr/\(\d+,\s*'\Q$cs\E'\)/,
                "installation fraîche: $cs présent dans mediabot.sql");
        }
    }
};
