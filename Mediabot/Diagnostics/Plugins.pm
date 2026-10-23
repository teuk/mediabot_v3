package Mediabot::Diagnostics::Plugins;
use strict;
use warnings;
use Mediabot::Plugin::ChannelPolicyV3;
use Mediabot::Plugin::DiagnosticsV3;

sub _number {defined($_[0]) && !ref($_[0]) && "$_[0]" =~ /\A[0-9]{1,10}\z/ && $_[0]<=9999999999}
sub _same_channel {
    my ($left,$right)=@_;
    # Web authorization is tied to a database channel identity. Never merge
    # distinct stored names through RFC1459 punctuation aliases here.
    return defined($left) && !ref($left) && lc("$left") eq $right;
}
sub collect {
    my ($class,$manager,$channel)=@_;
    Mediabot::Plugin::ChannelPolicyV3::_channel_key($channel,1);
    my $key=lc "$channel";
    my @entries=$manager->list;
    my @v3=sort {$a->{name} cmp $b->{name}} grep {
        ref($_) eq 'HASH' && ref($_->{metadata}) eq 'HASH'
            && defined($_->{metadata}{api}) && !ref($_->{metadata}{api}) && "$_->{metadata}{api}" eq '3'
    } @entries;
    my $total=@v3;splice @v3,64 if @v3>64;
    my @packages;my $unavailable=0;
    for my $entry (@v3) {
        my $name=$entry->{name};
        unless (defined($name) && !ref($name) && $name =~ /\A[a-z0-9][a-z0-9_.-]{0,63}\z/) {++$unavailable;next}
        my $row=eval {
            my $policy=$manager->_v3_policy_object($entry) or die "channel policy unavailable\n";
            my $selected=$policy->observation_for($channel);
            my $why=Mediabot::Plugin::DiagnosticsV3->explain_channel(entry=>$entry,channel=>$channel,
                policy=>$selected,policies=>$selected->{configured} ? [$selected]:[]);
            my $permissions=$manager->v3_permissions_report($name);
            die "invalid diagnostic\n" unless ref($why) eq 'HASH' && ref($permissions->{missing}) eq 'ARRAY';
            # Existing operator reports lazily create ledgers. Observation only
            # reads already owned instances, and never discovers/loads packages.
            my $ledger=ref($manager->{v3_failure_ledgers}) eq 'HASH' ? $manager->{v3_failure_ledgers}{$name} : undef;
            my $history=$ledger ? $ledger->report : {recent=>[],active_streaks=>[]};
            my @recent=grep {_same_channel($_->{channel},$key)} @{$history->{recent}};
            my @active=grep {_same_channel($_->{channel},$key)} @{$history->{active_streaks}};
            die "invalid failure record\n" if grep {!_number($_->{occurred_at}) || ($_->{kind}//'') !~ /\A(?:command|event|http_callback|job)\z/} @recent;
            @recent=sort {$b->{occurred_at}<=>$a->{occurred_at} || $b->{sequence}<=>$a->{sequence}} @recent;
            my $retained=@recent;
            my $quarantine=ref($manager->{v3_quarantines}) eq 'HASH' ? $manager->{v3_quarantines}{$name} : undef;
            my $quarantines=$quarantine ? $quarantine->report : {entries=>[]};
            my $isolated=grep {_same_channel($_->{channel},$key)} @{$quarantines->{entries}};
            my $missing=@{$permissions->{missing}};
            splice @recent,3 if @recent>3;
            {name=>"$name",state=>'observed',lifecycle=>"$why->{lifecycle}",configured=>$why->{configured}?1:0,
                policy=>"$why->{policy_mode}",decision=>"$why->{decision}",reason=>"$why->{reason}",
                missing_capabilities=>$missing,quarantined_resources=>$isolated,
                retained_failures=>$retained,active_streaks=>scalar(@active),
                last_failure_at=>@recent ? 0+$recent[0]{occurred_at}:undef,
                recent=>[map {{kind=>"$_->{kind}",occurred_at=>0+$_->{occurred_at}}} @recent]};
        };
        if (!$row) {++$unavailable;$row={name=>"$name",state=>'unavailable'}}
        push @packages,$row;
    }
    return {state=>$unavailable ? 'partial':'observed',scope=>'loaded_v3_channel',
        loaded_v3=>$total,legacy_loaded=>scalar(@entries)-$total,omitted=>$total-scalar(@v3),
        unavailable=>$unavailable,packages=>\@packages};
}
sub lines {
    my ($class,$report)=@_;
    return ['Plugins: state=unknown; loaded API v3 observation unavailable'] unless ref($report) eq 'HASH';
    my @rows=@{$report->{packages} || []};my $total=@rows;splice @rows,5 if @rows>5;
    my @lines=("Plugins: state=$report->{state}; loaded_v3=$report->{loaded_v3}; shown=".scalar(@rows)
        ."; omitted=".($report->{omitted}+$total-@rows)."; unavailable=$report->{unavailable}; legacy_policy=unknown");
    for my $p (@rows) {
        push @lines,$p->{state} eq 'unavailable' ? "Plugin $p->{name}: unavailable"
            : "Plugin $p->{name}: $p->{lifecycle}; policy=$p->{policy}; decision=$p->{decision}; missing_caps=$p->{missing_capabilities}; quarantined=$p->{quarantined_resources}; retained_failures=$p->{retained_failures}; last_failure_epoch="
                .(defined($p->{last_failure_at}) ? $p->{last_failure_at}:'none_in_retained_history');
    }
    return \@lines;
}
1;
