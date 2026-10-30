package Mediabot::Partyline::TaskConsole;
use strict;
use warnings;
use utf8;
use Encode qw(decode FB_CROAK);
use Mediabot::AsyncWorker ();

sub _error {die bless {public=>$_[0]},__PACKAGE__.'::Usage'}
my @COMMANDS=qw(help pwd cd ls ps jobs show cat kill stop start restart history complete exit);
sub _text {
    my ($s,$limit)=@_;return '' unless defined($s) && !ref($s);
    $s=eval {decode('UTF-8',$s,FB_CROAK)} unless utf8::is_utf8($s);
    return '[invalid text]' unless defined $s;
    $s =~ s/[\x00-\x1f\x7f-\x9f]/ /g;
    $s =~ s/\s+/ /g;
    return substr($s,0,$limit//100);
}
sub _write {my ($out,@lines)=@_;$out->write(join('',map {$_ . "\r\n"} @lines))}
sub _prompt {my ($out,$state)=@_;$out->write('mediabot:'.$state->{cwd}.'> ')}
sub _loop {
    my ($p)=@_;my $bot=$p->{bot};
    return eval {$bot->getLoop} || $bot->{loop} || $p->{loop};
}
sub _rows {
    my ($p)=@_;my $loop=_loop($p);my @rows;
    for my $w (Mediabot::AsyncWorker->active_workers($loop)) {
        push @rows,{%$w,type=>'worker',name=>_text($w->{label},80)};
    }
    my $s=$p->{bot}{scheduler};
    if ($s) {
        for my $t ($s->all_info) {
            next unless defined($t->{task_id}) && $t->{task_id}=~/\A[1-9][0-9]*\z/;
            push @rows,{%$t,id=>'s'.$t->{task_id},type=>'scheduler',scheduler_name=>$t->{name},
                name=>_text($t->{name},64),state=>$t->{started}?'enabled':'stopped'};
        }
    }
    return @rows;
}
sub _tokens {
    my ($line)=@_;my (@tokens,$word,$quoted,$escape,$started);
    $word='';
    for my $c (split //,$line) {
        if ($escape) {$word.=$c;$escape=0;$started=1;next}
        if ($c eq '\\' && (!defined($quoted) || $quoted ne "'")) {$escape=1;$started=1;next}
        if (defined $quoted) {if ($c eq $quoted) {undef $quoted}else {$word.=$c}next}
        if ($c eq "'" || $c eq '"') {$quoted=$c;$started=1;next}
        if ($c =~ /\s/ || $c eq '|') {
            push @tokens, ['word',$word] if $started;
            ($word,$started)=('',0);push @tokens,['pipe','|'] if $c eq '|';next;
        }
        $word.=$c;$started=1;
    }
    _error("Quote or escape is not closed.\n") if defined($quoted) || $escape;
    push @tokens,['word',$word] if $started;
    _error("Too many arguments.\n") if @tokens>32;
    my @parts=([]);
    for (@tokens) {if ($_->[0] eq 'pipe') {push @parts,[]}else {push @{$parts[-1]},$_->[1]}}
    _error("Use one command and at most two filters.\n") if @parts>3 || grep {!@$_} @parts;
    return @parts;
}
sub _path {
    my ($cwd,$path)=@_;$path='/' unless defined $path;
    my @p;for (split '/',($path=~m{^/}?'':$cwd.'/').$path) {
        next if $_ eq '' || $_ eq '.';if ($_ eq '..') {pop @p}else {push @p,$_}
    }
    return '/'.join('/',@p);
}
sub _id {
    my ($arg)=@_;return '' unless defined $arg;
    if ($arg =~ m{\A/(workers|schedulers)/(.+)\z}) {
        my ($kind,$id)=($1,$2);
        return '' unless substr($id,0,1) eq ($kind eq 'workers'?'w':'s');
        $arg=$id;
    }
    return $arg =~ /\A[ws][1-9][0-9]{0,15}\z/?$arg:'';
}
sub _help {
    my ($out)=@_;_write($out,
        'Mediabot internal shell — resources belonging to this bot.',
        '  pwd | cd /workers | cd /schedulers | cd .. | ls [path]',
        '  ps [all|workers|schedulers|slow] [page]   (slow: >= 1 second)',
        '  show <id> / cat <id>    details; IDs are w12 or s4, never OS PIDs',
        '  kill <id> / stop <id>   cancel worker or disable scheduler',
        '  start <s-id> | restart <s-id>   scheduler control',
        '  ps | grep [-i] "text" | head 5   literal filters, quotes supported',
        '  history | !! | !number | complete [prefix] | help | exit',
        'Coverage: Scheduler and shared AsyncWorker. Times are elapsed/callback durations, not CPU.',
        'Synchronous Perl code blocking the event loop cannot be interrupted from this shell.');
}
sub _read {
    my ($p,$out,$state,$cmd,$args,$filters)=@_;
    my ($kind,$page)=('all',1);
    if ($cmd eq 'ls') {
        _error("Usage: ls [path]\n") if @$args>1;
        my $path=_path($state->{cwd},$args->[0]//$state->{cwd});
        if ($path eq '/') {_error("Filters require a task listing.\n") if @$filters;_write($out,'workers/    schedulers/','Use ps to list all tasks.');return}
        _error("No such resource directory.\n") unless $path =~ m{\A/(workers|schedulers)\z};$kind=$1;
    } else {
        _error("Usage: ps [all|workers|schedulers|slow] [page]\n") if @$args>2;
        my @a=@$args;
        $kind=shift @a if @a && $a[0]!~/\A[0-9]+\z/;
        $kind='workers' if $kind eq 'async';$kind='schedulers' if $kind eq 'sched';
        _error("Unknown task filter. Use all, workers, schedulers or slow.\n") unless $kind=~/\A(?:all|workers|schedulers|slow)\z/;
        $page=shift @a if @a;
        _error("Invalid page.\n") if @a || $page!~/\A[1-9][0-9]{0,4}\z/;
    }
    my @rows=_rows($p);
    @rows=grep {$kind eq 'all' || ($kind eq 'workers' && $_->{type} eq 'worker')
        || ($kind eq 'schedulers' && $_->{type} eq 'scheduler')
        || ($kind eq 'slow' && ($_->{elapsed_s}//$_->{last_duration_s}//0)>=1)} @rows;
    @rows=sort {(($a->{type} eq 'worker'?0:1)<=>($b->{type} eq 'worker'?0:1)) || (($b->{elapsed_s}//$b->{last_duration_s}//0)<=>($a->{elapsed_s}//$a->{last_duration_s}//0)) || $a->{id} cmp $b->{id}} @rows;
    my @lines=map {sprintf('%-7s %-9s %-9s %8.3fs  %s',$_->{id},$_->{type},$_->{state},
        $_->{elapsed_s}//$_->{last_duration_s}//0,$_->{name})} @rows;
    for my $f (@$filters) {
        my ($name,@a)=@$f;
        if ($name eq 'grep') {
            my $ignore=@a && $a[0] eq '-i'?shift(@a):'';
            my $needle=$a[0];@lines=grep {index($ignore?lc($_):$_,$ignore?lc($needle):$needle)>=0} @lines;
        } else {splice @lines,$a[0] if @lines>$a[0]}
    }
    my $count=@lines;my $pages=int(($count+19)/20)||1;
    _error("Page outside listing ($pages page(s)).\n") if $page>$pages;
    my @visible=splice @lines,($page-1)*20,20;
    _write($out,'ID      TYPE      STATE      AGE / LAST  NAME',@visible?@visible:('(no matching tasks)'),
        "$count task(s), page $page/$pages. show <id> for details; exit to chat."
        .($page<$pages?" Next: ps $kind ".($page+1):''));
}
sub _execute {
    my ($p,$out,$state,$parts)=@_;my ($cmd,@a)=@{$parts->[0]};my @filters=@$parts[1..$#$parts];
    for my $f (@filters) {
        my ($name,@args)=@$f;
        _error("Filters: grep [-i] <literal> or head <1..50>.\n") unless
            ($name eq 'grep' && (@args==1 || (@args==2 && $args[0] eq '-i')))
            || ($name eq 'head' && @args==1 && $args[0]=~/\A[1-9][0-9]?\z/ && $args[0]<=50);
    }
    _error("Filters apply only to ps, jobs and ls.\n") if @filters && $cmd!~/\A(?:ps|jobs|ls)\z/;
    if ($cmd =~ /\A(?:ps|jobs|ls)\z/) {_read($p,$out,$state,$cmd,\@a,\@filters);return}
    if ($cmd eq 'help' || $cmd eq '?') {_error("Usage: help\n") if @a;_help($out);return}
    if ($cmd eq 'pwd') {_error("Usage: pwd\n") if @a;_write($out,$state->{cwd});return}
    if ($cmd eq 'cd') {
        _error("Usage: cd [directory]\n") if @a>1;my $path=_path($state->{cwd},$a[0]);
        _error("Directories: /, /workers, /schedulers.\n") unless $path=~m{\A/(?:workers|schedulers)?\z};$state->{cwd}=$path;return;
    }
    if ($cmd eq 'history') {_error("Usage: history\n") if @a;_write($out,map {sprintf('%4d  %s',$_->{n},$_->{line})} @{$state->{history}});return}
    if ($cmd eq 'complete') {
        _error("Usage: complete [prefix]\n") if @a>1;my $prefix=$a[0]//'';
        my @names=(@COMMANDS,'/workers','/schedulers',map {$_->{id}} _rows($p));
        @names=grep {index($_,$prefix)==0} @names;splice @names,40 if @names>40;
        _write($out,@names?join('  ',@names):'(no completion)');return;
    }
    if ($cmd =~ /\A(?:show|cat|kill|stop|start|restart)\z/) {
        _error("Usage: $cmd <task-id> (for example w12 or s4).\n") unless @a==1 && _id($a[0]);
        my $id=_id($a[0]);my ($row)=grep {$_->{id} eq $id} _rows($p);
        _error("Task $id has finished or no longer exists. Run ps.\n") unless $row;
        if ($cmd eq 'show' || $cmd eq 'cat') {
            _write($out,"$id  $row->{type}  $row->{state}","Name: $row->{name}");
            if ($row->{type} eq 'worker') {_write($out,sprintf('PID: %d | elapsed: %.3fs | timeout: %.2fs | progress events: %d',@$row{qw(pid elapsed_s timeout progress_count)}))}
            else {_write($out,sprintf('Interval: %ds | ticks: %d | next run in: %ds',
                $row->{interval},$row->{ticks},$row->{next_run}?($row->{next_run}-time):0),
                sprintf('Callback last: %.3fs | max: %.3fs | total: %.3fs | failures: %d',@$row{qw(last_duration_s max_duration_s total_duration_s callback_exceptions)}))}
            return;
        }
        my $ok;
        if ($row->{type} eq 'worker') {
            _error("Workers support kill/stop; restart the originating operation to create a new one.\n") unless $cmd eq 'kill' || $cmd eq 'stop';
            $ok=Mediabot::AsyncWorker->cancel_worker(_loop($p),$id);
            _error("Could not request cancellation. Run ps.\n") unless $ok;
            _write($out,"Cancellation requested for $id. ps confirms completion; the worker owns TERM/KILL escalation.");
        } else {
            my $method=$cmd eq 'kill'?'stop':$cmd;
            $ok=$p->{bot}{scheduler}->$method($row->{scheduler_name});
            _error("Scheduler action failed. Inspect ps/show before retrying.\n") unless $ok;
            _write($out,"Scheduler $id: $method succeeded.",
                'Stopping a schedule disables future ticks; already-started workers remain separate tasks.')
                if $method eq 'stop';
            _write($out,"Scheduler $id: $method succeeded.") if $method ne 'stop';
        }
        eval {$p->{bot}{logger}->log(2,'Task console: '.$cmd.' '.$id.' by '.$state->{actor})}
            if $p->{bot}{logger};
        return;
    }
    _error("Unknown internal command. Type help, complete or exit.\n");
}
sub handle_line {
    my ($p,$out,$id,$raw)=@_;my $session=$p->{users}{$id} or return 0;
    return 0 unless $session->{authenticated};
    my $entry=$raw =~ /\A\.command(?:\s+(on|off))?\s*\z/i;
    my $switch=$entry?lc($1//'on'):'';
    return 0 if !$entry && (!$session->{command_mode} || $raw=~/\A\./);
    if (($entry && $switch eq 'off') || ($session->{command_mode} && $raw=~/\A\s*exit\s*\z/)) {
        delete $session->{command_mode};_write($out,'Chat mode. Type .command to return to the internal shell.');return 1;
    }
    unless (defined($session->{level}) && !ref($session->{level}) && "$session->{level}"=~/\A[01]\z/) {
        delete $session->{command_mode};_write($out,'Access denied: command mode requires Master or Owner.');return 1;
    }
    my $state=$session->{command_shell}||={cwd=>'/',history=>[],serial=>0};
    $state->{actor}=_text($session->{login},32);
    if ($entry) {$session->{command_mode}=1;_help($out);_prompt($out,$state);return 1}
    my $ok=eval {
        _error("Command is too long.\n") if length($raw)>1024;
        my $line=utf8::is_utf8($raw)?$raw:decode('UTF-8',$raw,FB_CROAK);
        _error("Control characters are not allowed.\n") if $line =~ /[\x00-\x1f\x7f-\x9f]/;
        $line =~ s/^\s+|\s+$//g;
        if (length $line) {
            if ($line =~ /\A!(?:!|([1-9][0-9]{0,15}))\z/) {
                my $number=$1;my ($h)=defined($number)?grep {$_->{n}==$number} @{$state->{history}}:$state->{history}[-1];
                _error("History entry not available.\n") unless $h;$line=$h->{line};_write($out,$line);
            }
            my @parts=_tokens($line);
            unless ($parts[0][0] eq 'history') {
                push @{$state->{history}},{n=>++$state->{serial},line=>$line};
                shift @{$state->{history}} while @{$state->{history}}>20;
            }
            _execute($p,$out,$state,\@parts);
        }
        1;
    };
    unless ($ok) {
        my $err=$@;
        # Parser/usage errors are fixed messages; backend exception text stays private.
        my $public=ref($err) eq __PACKAGE__.'::Usage'
            ? _text($err->{public},160) : 'Operation failed. Inspect ps/show or use help.';
        _write($out,$public);
    }
    _prompt($out,$state);return 1;
}
1;
