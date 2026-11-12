package MB1242VersionCommand;
use strict;
use warnings;
use JSON::PP ();
use Mediabot::Version::Format ();

sub check {
    my ($ok, $mode) = @_;
    $mode ||= 'facade';
    if ($mode eq 'component') { require Mediabot::Version::Command }
    else { require Mediabot::Helpers }
    my $encode = sub { JSON::PP->new->canonical->encode($_[0]) };
    my $eq = sub { $ok->($encode->($_[0]) eq $encode->($_[1]), "MB1242 $mode $_[2]") };
    for my $row (
        ['3.7','unused','3.7','3.8','update available: 3.8 (local: 3.7)'],
        ['3.8','unused','3.8','3.7','local build newer than repository: 3.8 (repository: 3.7)'],
        ['3.8','unused','3.8','3.8',undef],
        ['3.8','unused','3.8','banana','repository version format unknown: banana'],
        ['3.8','unused','3.8','Undefined',undef],
        ['Undefined','3.7','3.7','3.8','update available: 3.8 (local: 3.7)'],
        ['Undefined','Undefined','3.7','3.8','update available: 3.8 (local: 3.7)'],
        ['Undefined','Undefined','Undefined',undef,undef],
    ) {
        my ($cache,$disk,$worker,$remote,$tail)=@$row;
        for my $inline (0,1) {
            my (@events,$done,$reads,$seen_audit);
            my $bot={main_prog_version=>$cache,conf=>bless({name=>'TestBot'},'MB1242VersionCommand::Conf')};
            my $ctx=bless {bot=>$bot,events=>\@events,message=>bless({},'MB1242VersionCommand::Message')},'MB1242VersionCommand::Context';
            my %deps=(
                normalize=>sub { Mediabot::Version::Format::_usable_local_version(@_) },
                compare=>sub { Mediabot::Version::Format::_compare_mediabot_versions(@_) },
                cached=>sub { $ok->($_[0]==$bot,'cache gets original bot');$cache },
                local=>sub { $reads++;$ok->($_[0]==$bot,'local reader gets original bot');$disk },
                audit=>sub { $seen_audit=[@_];push @events,'audit' },
                remote=>sub { $ok->($_[0]==$bot,'remote gets original bot');push @events,'remote';$done=$_[1];$done->($worker,$remote) if $inline;0 },
            );
            my $ret=_invoke($mode,$ctx,\%deps);
            my $local=$cache eq 'Undefined' ? ($disk eq 'Undefined'?'unknown':$disk) : $cache;
            my @expected=("reply:TestBot version: $local",'audit','remote');
            if (!$inline) { $eq->(\@events,\@expected,'local reply and audit precede deferred completion') }
            $done->($worker,$remote) unless $inline;
            if ($local eq 'unknown' && $worker ne 'Undefined') {
                $local=$worker;push @expected,"reply:TestBot version: $local";
            }
            push @expected,"reply:TestBot $tail" if defined $tail;
            $eq->(\@events,\@expected,'exact immediate/inline/deferred response order');
            $ok->($ret==1,'historical return ignores remote submission result');
            $ok->(($reads||0)==($cache eq 'Undefined'?1:0),'disk is consulted only on cache miss');
            $ok->($seen_audit->[0]==$bot && $seen_audit->[1]==$ctx->{message}
                && !defined($seen_audit->[2]) && $seen_audit->[3] eq 'version'
                && !defined($seen_audit->[4]) && @$seen_audit==5,'exact audit arguments');
            $ok->($bot->{main_prog_version} eq ($local eq 'unknown'?$cache:$local),'only usable identity updates cache');
        }
    }
    for my $stage (qw(reply audit remote compare)) {
        my @events;my $error=bless {},'MB1242VersionCommand::Error';
        my $ctx=bless {bot=>{conf=>bless({},'MB1242VersionCommand::Conf'),main_prog_version=>'3.7'},events=>\@events,
            ($stage eq 'reply' ? (error=>$error):())},'MB1242VersionCommand::Context';
        my %deps=(normalize=>sub {$_[0]},cached=>sub {'3.7'},local=>sub {die 'unexpected disk'},
            audit=>sub {push @events,'audit';die $error if $stage eq 'audit'},
            remote=>sub {push @events,'remote';die $error if $stage eq 'remote';$_[1]->('3.7','3.8')},
            compare=>sub {die $error});
        eval {_invoke($mode,$ctx,\%deps)};my $caught=$@;
        $ok->(ref($caught) && $caught==$error,"$stage exception identity propagates");
        my @expected=$stage eq 'reply'?():('reply:Mediabot version: 3.7','audit',($stage eq 'audit'?():('remote')));
        $eq->(\@events,\@expected,"$stage failure prevents subsequent stages");
    }
    # Late Helpers overrides must be resolved when invoked, including after
    # submission and from the audit callback itself.
    if ($mode eq 'facade') {
        no warnings 'redefine';
        my (@events,$done);
        my $ctx=bless {bot=>{conf=>bless({},'MB1242VersionCommand::Conf'),main_prog_version=>'3.7'},events=>\@events},'MB1242VersionCommand::Context';
        local *Mediabot::Helpers::_cached_local_version=sub {'3.7'};
        local *Mediabot::Helpers::getVersion_async=sub {die 'stale remote hook'};
        local *Mediabot::Helpers::logBot=sub {
            *Mediabot::Helpers::getVersion_async=sub {$done=$_[1];1};
        };
        Mediabot::Helpers::versionCheck($ctx);
        {
            local *Mediabot::Helpers::_compare_mediabot_versions=sub {-1};
            $done->('3.7','3.6');
        }
        $eq->(\@events,['reply:Mediabot version: 3.7','reply:Mediabot update available: 3.6 (local: 3.7)'],
            'audit-installed remote and completion-time comparator overrides remain live');
    }
}

sub _invoke {
    my ($mode,$ctx,$d)=@_;
    return Mediabot::Version::Command::run($ctx,$d) if $mode eq 'component';
    no warnings 'redefine';
    local *Mediabot::Helpers::_usable_local_version=$d->{normalize};
    local *Mediabot::Helpers::_cached_local_version=$d->{cached};
    local *Mediabot::Helpers::getLocalVersion=$d->{local};
    local *Mediabot::Helpers::_compare_mediabot_versions=$d->{compare};
    local *Mediabot::Helpers::logBot=$d->{audit};
    local *Mediabot::Helpers::getVersion_async=$d->{remote};
    return Mediabot::Helpers::versionCheck($ctx);
}
package MB1242VersionCommand::Conf;
sub get {$_[0]->{name}}
package MB1242VersionCommand::Context;
sub bot {$_[0]->{bot}}
sub message {$_[0]->{message}}
sub reply {die $_[0]->{error} if $_[0]->{error};push @{$_[0]->{events}},'reply:'.$_[1];1}
1;
