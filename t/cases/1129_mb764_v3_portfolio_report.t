# MB764 — one bounded report reconciles installed and live API v3 posture.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

{
    package T1129::Logger;
    sub new { bless {}, shift }
    sub log { 1 }
}

{
    package T1129::Bot;
    sub new {
        require Mediabot::CommandRegistry;
        return bless {
            registry => Mediabot::CommandRegistry->new,
            logger   => T1129::Logger->new,
        }, shift;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
    sub getUserChannelLevel { 0 }
}

return sub {
    my ($assert) = @_;
    require Mediabot::PluginManager;

    my $bot = T1129::Bot->new;
    for my $name (qw(factoid factoids learn forget whatis)) {
        $bot->{registry}->register_command(
            name => $name, source => 'public', handler => sub { 1 },
            category => 'core', metadata => {
                builtin => 1, dispatch => 'registry', syntax => $name,
                migration_fallback => 1,
            });
    }

    my $manager = Mediabot::PluginManager->new(
        bot => $bot, plugin_dir => 'plugins');
    my $initial = $manager->v3_portfolio_report;
    $assert->is($initial->{summary}{discovered}, 7,
        'portfolio discovers the seven installed API v3 packages');
    $assert->is($initial->{summary}{loaded}, 0,
        'discovery does not load a package');
    $assert->is($initial->{summary}{entries}, 7,
        'portfolio returns one bounded row per installed package');
    $assert->is($initial->{summary}{maximum_entries}, 64,
        'portfolio publishes its fixed output bound');
    $assert->is($initial->{summary}{truncated}, 0,
        'reviewed package set fits inside the output bound');

    my ($cold_factoids) = grep {
        $_->{name} eq 'factoids-v3'
    } @{ $initial->{packages} };
    $assert->is($cold_factoids->{lifecycle}, 'unloaded',
        'installed factoid package begins unloaded');
    $assert->is($cold_factoids->{status}, 'inactive',
        'unloaded package has an explicit inactive status');
    $assert->is($cold_factoids->{reason}, 'not_loaded',
        'unloaded package reason is operator-readable');

    $manager->load_package_v3('factoids-v3', grants => [
        qw(data.factoids.read data.factoids.write irc.reply irc.notice)
    ]);
    $manager->set_v3_channel_policy(
        'factoids-v3', '#test', mode => 'on');
    $manager->enable('factoids-v3');

    my $active = $manager->v3_portfolio_report;
    $assert->is($active->{summary}{loaded}, 1,
        'portfolio counts the one loaded v3 package');
    $assert->is($active->{summary}{enabled}, 1,
        'portfolio counts the enabled package');
    $assert->is($active->{summary}{active}, 1,
        'portfolio counts a package with active channel policy');
    $assert->is($active->{summary}{active_channels}, 1,
        'portfolio counts the exact promoted channel');
    $assert->is($active->{summary}{ready}, 1,
        'complete grants and one active channel are ready');
    $assert->is($active->{summary}{limited}, 0,
        'complete promotion has no limited package');

    my ($live_factoids) = grep {
        $_->{name} eq 'factoids-v3'
    } @{ $active->{packages} };
    $assert->is($live_factoids->{installed}, 1,
        'live row records that the package remains installed');
    $assert->is($live_factoids->{lifecycle}, 'enabled',
        'live row exposes lifecycle without the plugin object');
    $assert->is($live_factoids->{status}, 'ready',
        'live row reuses deterministic doctor readiness');
    $assert->is($live_factoids->{policies}{on}, 1,
        'live row exposes the on-policy count');
    $assert->is($live_factoids->{policies}{observe}, 0,
        'live row distinguishes observe from on');
    $assert->ok(!exists($live_factoids->{package_dir}),
        'portfolio exposes no package path');
    $assert->ok(!exists($live_factoids->{config}),
        'portfolio exposes no channel configuration values');

    my $detached = $active->{packages};
    $detached->[0]{name} = 'tampered';
    my $fresh = $manager->v3_portfolio_report;
    $assert->ok(!grep($_->{name} eq 'tampered', @{ $fresh->{packages} }),
        'portfolio rows are detached snapshots');
    # MB1216: standalone diagnostic assembly, no manager or bot dependency.
    {
        require Mediabot::Plugin::DiagnosticsV3;
        my @installed=map {{name=>sprintf('package-%02d',$_),version=>'1',package_dir=>'private'}} 0..65;
        my %entries=(
            'package-00'=>{name=>'package-00',metadata=>{api=>2}},
            'package-01'=>{name=>'package-01',metadata=>{api=>3},enabled=>1},
            'removed'=>{name=>'removed',metadata=>{api=>3},enabled=>0},
        );
        my $details={version=>'2',lifecycle=>'enabled',status=>'ready',reason=>'active',
            policies=>{total=>2,active=>1,on=>1,off=>1,observe=>0},config=>{secret=>'hidden'}};
        my @calls;
        my %providers=(
            discover=>sub {push @calls,'discover';@installed},
            list=>sub {push @calls,'list';values %entries},
            entry=>sub {push @calls,"entry:$_[0]";$entries{$_[0]}},
            report=>sub {push @calls,"report:$_[0]";$details},
        );
        my $report=Mediabot::Plugin::DiagnosticsV3->portfolio(%providers);
        $assert->is($report->{summary}{entries},67,'mb1216: installed and loaded-only names are combined');
        $assert->is(scalar @{$report->{packages}},64,'mb1216: rows retain the 64-entry cap');
        $assert->is($report->{summary}{truncated},3,'mb1216: truncation is counted exactly');
        $assert->is($report->{summary}{loaded},2,'mb1216: summary includes loaded rows beyond truncation');
        $assert->is($report->{summary}{enabled},1,'mb1216: enabled count follows live entry state');
        $assert->is($report->{summary}{active_channels},2,'mb1216: active-channel counts cover full portfolio');
        $assert->is($report->{summary}{limited},1,'mb1216: legacy name collision remains limited');
        $assert->is($report->{packages}[0]{reason},'name_collision','mb1216: sorted collision row retains reason');
        $assert->is($report->{packages}[2]{reason},'not_loaded','mb1216: installed-only row stays unloaded');
        $assert->ok($calls[0] eq 'discover' && $calls[1] eq 'list' && $calls[2] eq 'entry:package-00'
            && $calls[3] eq 'entry:package-01' && $calls[4] eq 'report:package-01','mb1216: discovery, lookup and report order preserved');
        $assert->ok(!exists($report->{packages}[1]{config}) && !exists($report->{packages}[1]{package_dir}),
            'mb1216: raw provider configuration and paths are excluded');
        $report->{packages}[1]{policies}{on}=999;
        $assert->is($details->{policies}{on},1,'mb1216: result mutation cannot alter provider policy snapshot');
        my $loaded_only=Mediabot::Plugin::DiagnosticsV3->portfolio(%providers,discover=>sub {()});
        my ($removed)=grep {$_->{name} eq 'removed'} @{$loaded_only->{packages}};
        $assert->ok($removed && !$removed->{installed},'mb1216: loaded package survives disappearance from discovery');
        for my $stage (qw(discover list entry report)) {
            my $error=bless {},'T1129::ProviderError';
            my $ok=eval {Mediabot::Plugin::DiagnosticsV3->portfolio(%providers,$stage=>sub {die $error});1};
            $assert->ok(!$ok && ref($@) && $@==$error,"mb1216: $stage exception retains its identity");
        }
    }

};
