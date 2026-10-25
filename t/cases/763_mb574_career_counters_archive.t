# t/cases/763_mb574_career_counters_archive.t
# =============================================================================
# mb574 (refondu par mb576) — les compteurs CARRIERE voient vif + archive via
# des requetes PAR TABLE fusionnees en Perl (Helpers::channel_log_gather).
# Le UNION ALL derive de la premiere mouture est banni : MariaDB pousse les
# WHERE dans les branches mais pas les ORDER BY/LIMIT, et meme les COUNT
# materialisaient les lignes filtrees avant d'agreger.
#   [1] stats / top / streak / leaderboard utilisent channel_log_gather ;
#   [2] plus aucune reference a l'ancien helper channel_log_from ;
#   [3] la garde d'interpolation tient : aucun qq{} contenant la sequence
#       REGEXP « $) » (variable GID Perl) dans tout le fichier.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_763 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

sub _sub_src_763 {
    my ($src, $name) = @_;
    my ($body) = $src =~ /(sub \Q$name\E \{.*?\n\})/s;
    return $body;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_763(File::Spec->catfile('Mediabot', 'UserCommands.pm'))
              . "\n" . _slurp_763(File::Spec->catfile('Mediabot', 'SocialHistory.pm'))
              . "\n" . _slurp_763(File::Spec->catfile('Mediabot', 'Stats', 'Activity.pm'))
              . "\n" . _slurp_763(File::Spec->catfile('Mediabot', 'Stats', 'History.pm'));

    # MB952: exercise real imports in fresh interpreters. Both domain-first
    # orders and the historical facade-first order must preserve bot methods
    # and call-time transport hooks, without eagerly importing the facade.
    require IPC::Open3;
    require Symbol;
    for my $order (
        [qw(Stats::Activity Stats::History UserCommands)],
        [qw(Stats::History Stats::Activity UserCommands)],
        [qw(UserCommands Stats::History Stats::Activity)],
    ) {
        my $code = "require Mediabot::$order->[0];\n";
        $code .= q{die 'domain eagerly loaded commands' if $INC{'Mediabot/UserCommands.pm'};}
            if $order->[0] ne 'UserCommands';
        $code .= join('', map {"require Mediabot::$_;\n"} @$order[1..$#$order]);
        $code .= q{
            require Scalar::Util;
            require Mediabot::Mediabot;
            require Mediabot::Context;
            my %owners = (
                Activity => [qw(mbStats_ctx mbTop_ctx mbActive_ctx mbWhen_ctx
                    mbCompare_ctx mbHeatmap_ctx mbMonthStats_ctx)],
                History => [qw(mbWordCount_ctx mbStreak_ctx mbLast_ctx)],
            );
            for my $owner (keys %owners) {
                for my $name (@{$owners{$owner}}) {
                    my $native = "Mediabot::Stats::$owner"->can($name);
                    my $legacy = Mediabot::UserCommands->can($name);
                    my $method = Mediabot->can($name);
                    die "missing command: $name" unless $native && $legacy && $method
                        && Scalar::Util::refaddr($native) == Scalar::Util::refaddr($legacy)
                        && Scalar::Util::refaddr($native) == Scalar::Util::refaddr($method);
                }
            }
            my @notices;
            {
                no warnings 'redefine';
                local *Mediabot::UserCommands::botNotice = sub {push @notices, [@_]};
                my $ctx = Mediabot::Context->new(bot=>{}, nick=>'alice', channel=>'#test', args=>[]);
                Mediabot::UserCommands::mbWhen_ctx($ctx);
                Mediabot::UserCommands::mbLast_ctx($ctx);
            }
            die 'legacy notice hook lost' unless @notices == 2
                && $notices[0][1] eq 'alice' && $notices[0][2] eq 'Syntax: when <nick>'
                && $notices[1][1] eq 'alice' && $notices[1][2] =~ /^Syntax: last /;
            print 'loaded';
        };
        my $err = Symbol::gensym();
        my $pid = IPC::Open3::open3(undef, my $out, $err, $^X, '-I.', '-It/lib', '-e', $code);
        my $stdout = do { local $/; <$out> } // '';
        my $stderr = do { local $/; <$err> } // '';
        waitpid($pid, 0);
        $assert->ok($? == 0 && $stdout eq 'loaded' && $stderr eq '',
            'mb952: statistics load order, bot methods and late hooks: ' . join('/', @$order)
                . ($stderr ne '' ? " ($stderr)" : ''));
    }

    # [1] chaque compteur carriere passe par le gather par table
    for my $sub_name (qw(mbStats_ctx mbTop_ctx mbStreak_ctx mbLeaderboard_ctx)) {
        my $body = _sub_src_763($src, $sub_name);
        $assert->ok(defined $body, "$sub_name isolee");
        $assert->like($body, qr/Mediabot::Helpers::channel_log_gather/,
            "$sub_name: requetes par table via channel_log_gather");
        $assert->like($body, qr/__CLSRC__/,
            "$sub_name: template avec token __CLSRC__");
    }

    # les fusions sensibles : rank de stats et podium du leaderboard se font
    # sur des GROUP BY complets par table (pas de HAVING/LIMIT par branche)
    my $stats = _sub_src_763($src, 'mbStats_ctx');
    $assert->like($stats, qr/%rank_counts/,
        'stats: fusion des comptes par nick avant le seuil de rank');
    my @having = grep { $_ !~ /^\s*#/ && /HAVING/i } split /\n/, $stats;
    $assert->is(join('|', @having), '',
        'stats: aucun HAVING par branche (le seuil est applique en Perl)');
    my $lb = _sub_src_763($src, 'mbLeaderboard_ctx');
    $assert->like($lb, qr/%lb_counts/,
        'leaderboard: fusion par nick avant le podium');

    # [2] l'ancien helper n'existe plus nulle part
    $assert->ok($src !~ /channel_log_from/,
        'Commandes historiques: plus aucune reference a channel_log_from');
    my $helpers = _slurp_763(File::Spec->catfile('Mediabot', 'Helpers.pm'));
    $assert->ok($helpers !~ /sub channel_log_from/,
        'Helpers: sub channel_log_from supprimee');

    # [3] garde interpolation
    my @danger;
    while ($src =~ /qq\{([^}]*)\}/gs) {
        push @danger, substr($1, 0, 40) if $1 =~ /\[\[:space:\]\]\|\$\)/;
    }
    $assert->is(join('|', @danger), '', 'aucun qq{} avec la sequence $)');
};
