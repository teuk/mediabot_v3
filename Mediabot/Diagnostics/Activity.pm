package Mediabot::Diagnostics::Activity;
use strict;
use warnings;
use POSIX qw(strftime);

my @TASKS = qw(rss_poll_dispatch randomquote_dispatch);
my %REASONS = map {$_ => 1} qw(unsafe_path unreadable missing_lock missing_state
    not_regular changed busy too_large invalid_json invalid_schema);
sub new {my ($class,%args)=@_;return bless {bot=>$args{bot}},$class}
sub _number {
    my ($v,$max)=@_;
    return defined($v) && !ref($v) && "$v" =~ /\A[0-9]{1,10}\z/ && $v <= $max;
}
sub _observation {
    my ($component,$channel,$kind)=@_;
    return {runtime=>'absent',state=>'unknown',reason=>'runtime_absent'} unless $component;
    my $raw=eval {$component->diagnostic_status($channel)};
    my $bad={runtime=>'present',state=>'unavailable',reason=>'read_failed'};
    return $bad unless ref($raw) eq 'HASH' && defined($raw->{state}) && !ref($raw->{state});
    my $state=$raw->{state};
    if ($state =~ /\A(?:busy|invalid|unavailable)\z/) {
        my $reason=$raw->{reason};
        return {runtime=>'present',state=>$state,
            reason=>defined($reason) && !ref($reason) && $REASONS{$reason} ? "$reason" : 'read_failed'};
    }
    return $bad unless $state eq 'fresh' || $state eq 'absent';
    return $bad unless defined($raw->{source}) && !ref($raw->{source}) && $raw->{source} =~ /\A(?:channel|default)\z/;
    my $out={runtime=>'present',state=>$state,source=>"$raw->{source}"};
    if (exists $raw->{file_modified_at}) {
        return $bad unless _number($raw->{file_modified_at},9999999999);
        $out->{file_modified_at}=0+$raw->{file_modified_at};
    }
    my %fields=$kind eq 'rss' ? (gap=>10080,daily=>24,used=>300,wait=>9999999999)
        : (interval=>604800,custom=>1,scheduled=>1);
    for my $key (keys %fields) {
        return $bad unless _number($raw->{$key},$fields{$key});
        $out->{$key}=0+$raw->{$key};
    }
    if ($kind eq 'randomquote') {
        return $bad if $out->{interval}<900;
        if ($out->{scheduled}) {
            for my $key (qw(next_at wait pending)) {
                return $bad unless _number($raw->{$key},$key eq 'pending' ? 1 : 9999999999);
                $out->{$key}=0+$raw->{$key};
            }
        }
    }
    return $out;
}
sub _task {
    my ($scheduler,$name,$now)=@_;
    return {state=>'unknown',reason=>'scheduler_absent'} unless $scheduler;
    my $raw;my $ok=eval {$raw=$scheduler->task_info($name);1};
    return {state=>'unavailable',reason=>'read_failed'} unless $ok;
    return {state=>'absent'} unless defined $raw;
    my $bad={state=>'unavailable',reason=>'invalid_observation'};
    return $bad unless ref($raw) eq 'HASH' && defined($raw->{name}) && !ref($raw->{name}) && $raw->{name} eq $name
        && defined($raw->{mode}) && !ref($raw->{mode}) && $raw->{mode} =~ /\A(?:periodic|calendar)\z/;
    my $out={state=>'present',mode=>"$raw->{mode}"};
    for my $key (qw(started interval ticks last_tick next_run)) {
        return $bad unless _number($raw->{$key},$key eq 'started' ? 1 : 9999999999);
        $out->{$key}=0+$raw->{$key};
    }
    return $bad unless $out->{interval}>0;
    $out->{overdue_seconds}=$out->{started} && $out->{next_run} && $out->{next_run}<$now
        ? $now-$out->{next_run} : 0;
    return $out;
}
sub collect {
    my ($self,$channel,$now)=@_;my $bot=$self->{bot};
    return {
        rss=>_observation($bot->{rss_runtime},$channel,'rss'),
        randomquote=>_observation($bot->{randomquote_runtime},$channel,'randomquote'),
        tasks=>{map {$_=>_task($bot->{scheduler},$_,$now)} @TASKS},
    };
}
sub _when {return defined($_[0]) ? strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($_[0])) : 'unknown'}
sub lines {
    my ($self,$report)=@_;my @lines;
    for my $kind (qw(rss randomquote)) {
        my $o=$report->{$kind};my $label=$kind eq 'rss' ? 'RSS' : 'RandomQuote';
        my $text="$label: runtime=$o->{runtime}; state=$o->{state}";
        if (exists $o->{source}) {
            $text.="; source=$o->{source}";
            if ($kind eq 'rss') {
                $text.="; gap=$o->{gap}min; daily=$o->{daily}; reserved_24h=$o->{used}; wait=$o->{wait}s";
            } else {
                $text.="; interval=$o->{interval}s; custom=$o->{custom}";
                $text.=$o->{scheduled} ? '; next_attempt='._when($o->{next_at})."; wait=$o->{wait}s; pending_ticket=$o->{pending}"
                    : '; next_attempt=unscheduled';
            }
            $text.='; file_mtime='._when($o->{file_modified_at});
        } else {$text.="; reason=$o->{reason}" if exists $o->{reason}}
        push @lines,$text;
    }
    for my $name (@TASKS) {
        my $o=$report->{tasks}{$name};my $text="Task(instance) $name: state=$o->{state}";
        if ($o->{state} eq 'present') {
            $text.='; started='.($o->{started} ? 'yes' : 'no')."; interval=$o->{interval}s; ticks=$o->{ticks}";
            $text.='; last_tick='.($o->{last_tick} ? _when($o->{last_tick}) : 'never');
            $text.='; next_wakeup='.($o->{started} && $o->{next_run} ? _when($o->{next_run}) : 'none');
            $text.="; overdue=$o->{overdue_seconds}s";
        } else {$text.="; reason=$o->{reason}" if exists $o->{reason}}
        push @lines,$text;
    }
    return \@lines;
}
1;
