package Mediabot::Partyline::TaskConsole;
use strict;
use warnings;
use utf8;
use Encode qw(decode FB_CROAK);
use Mediabot::AsyncWorker ();
use Mediabot::Partyline::ShellContext ();
use Mediabot::Partyline::ShellWatch ();

sub _error {die bless {public=>$_[0]},__PACKAGE__.'::Usage'}
my @COMMANDS=qw(help pwd cd ls ps jobs show cat kill stop start restart history complete
    channels use context channel topic who plugins chansets diagnose status clear
    watch next prev refresh exit);
sub _text {
    my ($s,$limit)=@_;return '' unless defined($s) && !ref($s);
    $s=eval {decode('UTF-8',$s,FB_CROAK)} unless utf8::is_utf8($s);
    return '[invalid text]' unless defined $s;
    $s =~ s/[\x00-\x1f\x7f-\x9f]/ /g;
    $s =~ s/\s+/ /g;
    return substr($s,0,$limit//100);
}
sub _write {my ($out,@lines)=@_;$out->write(join('',map {$_ . "\r\n"} @lines))}
sub _prompt {
    my ($out,$state)=@_;
    my $context=defined($state->{channel}) ? '['._text($state->{channel},200).']' : '';
    $out->write('mediabot'.$context.':'.$state->{cwd}.'> ');
}
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
    my ($out,$command)=@_;
    my %help=(
        use=>'use #channel | use - : select a registered channel or global context',
        context=>'context : selected cached channel identity; task control always remains GLOBAL',
        channel=>'channel : cached channel ID, description, timezone and observed join state',
        topic=>'topic : cached registered topic; no IRC request or topic change',
        who=>'who [page] : cached nicks of the selected channel, twenty per page',
        channels=>'channels [page] : registered channel cache; use #channel selects one',
        plugins=>'plugins [page] : loaded API v3 observations for the selected channel',
        chansets=>'chansets [page] : persisted diagnostic flag catalogue; not effective runtime defaults',
        diagnose=>'diagnose [page] : existing read-only channel diagnostic (includes database reads)',
        status=>'status : process uptime, IRC connection and globally tracked tasks',
        ps=>'ps [all|workers|schedulers|slow|running|stopped|failed] [page] : global task listing',
        kill=>'kill <id> : cancel an owned worker or disable future scheduler ticks; global scope',
        history=>'history | history clear | !! | !number : private history; clear never reuses numbers',
        complete=>'complete [prefix] : commands, resource directories, IDs and registered channels',
        watch=>'watch [5..60 seconds] <cached read command> : refresh for at most five minutes; any input stops; watch off also stops',
        next=>'next / prev / refresh : rerun the last listing with its filters and context; these are live observations',
        prev=>'prev : previous page of the last filtered listing in the same context/directory',
        refresh=>'refresh : rerun the current page with the last listing filters and context',
    );
    if (defined $command) {
        _error("No detailed help for this command. Use help.\n") unless exists $help{$command};
        _write($out,$help{$command});return;
    }
    _write($out,
        'Mediabot internal shell — resources belonging to this bot.',
        '  pwd | cd /workers | cd /schedulers | cd .. | ls [path]',
        '  ps [all|workers|schedulers|slow|running|stopped|failed] [page]',
        '  show <id> / cat <id>    details; IDs are w12 or s4, never OS PIDs',
        '  kill <id> / stop <id>   cancel worker or disable scheduler',
        '  start <s-id> | restart <s-id>   scheduler control',
        '  channels [page]; use #channel; use -; context; status',
        '  channel; topic; who; plugins; chansets; diagnose [page]',
        '  ps | grep [-i] "text" | head 5   also tail N, sort [-r]',
        '  history [clear]; !!; !number; complete [prefix]; help [command]; clear; exit',
        '  next; prev; refresh   reuse the last listing filters in this context',
        '  watch [5..60] ps slow   bounded live refresh; any input stops it',
        'Background broadcasts and .console logs are muted until exit; no replay.',
        'Channel context never narrows ps/kill/start/restart: task control is GLOBAL.',
        'Coverage: Scheduler and shared AsyncWorker. Times are elapsed/callback durations, not CPU.',
        'Synchronous Perl code blocking the event loop cannot be interrupted from this shell.');
}
sub _listing {
    my ($out,$heading,$lines,$filters,$page,$next,$state)=@_;
    my @lines=map {_text($_,1000)} @$lines;
    for my $filter (@$filters) {
        my ($name,@args)=@$filter;
        if ($name eq 'grep') {
            my $ignore=@args==2;my $needle=$args[-1];
            @lines=grep {index($ignore?lc($_):$_,$ignore?lc($needle):$needle)>=0} @lines;
        } elsif ($name eq 'head') {splice @lines,$args[0] if @lines>$args[0]}
        elsif ($name eq 'tail') {splice @lines,0,@lines-$args[0] if @lines>$args[0]}
        else {@lines=sort @lines;@lines=reverse @lines if @args}
    }
    my $count=@lines;my $pages=int(($count+19)/20)||1;
    _error("Page outside listing ($pages page(s)).\n") if $page>$pages;
    my @visible=splice @lines,($page-1)*20,20;
    _write($out,$heading,@visible?@visible:('(no matching entries)'),
        "$count ".($next=~/\Aps /?'task(s)':'entry/entries').", page $page/$pages."
        .($page<$pages?" Next: $next ".($page+1).(@$filters?' (repeat filters)':''):''));
    $state->{listing}={command=>$next,filters=>[map {[@$_]} @$filters],page=>$page,pages=>$pages,
        channel=>$state->{channel}//'',channel_id=>$state->{channel_id}//'',cwd=>$state->{cwd}}
        if $state;
}
sub _context_command {
    my ($p,$out,$state,$cmd,$args,$filters)=@_;
    my $bot=$p->{bot};my $owner='Mediabot::Partyline::ShellContext';
    if ($cmd eq 'use') {
        _error("Usage: use #channel or use -.\n") unless @$args==1;
        if ($args->[0] eq '-') {delete @$state{qw(channel channel_id)}}
        else {my $row=$owner->select($bot,$args->[0]);@$state{qw(channel channel_id)}=@$row{qw(name channel_id)}}
        _write($out,defined($state->{channel})?"Channel context: $state->{channel} (id $state->{channel_id}).":'Global context.');return;
    }
    if ($cmd eq 'context') {
        _error("Usage: context\n") if @$args;
        my $row=defined($state->{channel})?$owner->current($bot,$state):undef;
        _write($out,$row?"Channel context: $row->{name} (id $row->{channel_id}).":'Global context.',
            'Task inspection and control are GLOBAL; channel commands use the selected identity.');return;
    }
    if ($cmd eq 'status') {
        _error("Usage: status\n") if @$args;
        my @workers=Mediabot::AsyncWorker->active_workers(_loop($p));
        my @tasks=$bot->{scheduler}?$bot->{scheduler}->all_info:();
        my $enabled=grep {$_->{started}} @tasks;
        my $connected=$bot->{irc}?($bot->{irc}->is_connected?'yes':'no'):'unknown';
        my $up=defined($bot->{_start_time}) && !ref($bot->{_start_time})
            && $bot->{_start_time}=~/\A[0-9]+\z/ ? time-$bot->{_start_time}:undef;
        _write($out,'Runtime observation (GLOBAL)',
            'Uptime: '.(defined($up)?$up.'s':'unknown')." | IRC connected: $connected",
            'Workers: '.scalar(@workers).' | Schedulers: '.scalar(@tasks)." ($enabled enabled)",
            'Context: '._text($state->{channel}//'global',200));return;
    }
    if ($cmd eq 'channel' || $cmd eq 'topic') {
        _error("Usage: $cmd\n") if @$args;my $row=$owner->details($bot,$state);
        my @lines=('Channel: '.$row->{name}.' (id '.$row->{channel_id}.')');
        push @lines,'Timezone: '.($row->{timezone}//'unknown').' | Joined: '.$row->{joined},
            'Description: '.($row->{description}//'') if $cmd eq 'channel';
        push @lines,'Cached topic: '.($row->{topic}//'(unavailable)');
        _write($out,map {_text($_,1000)} @lines);return;
    }
    _error("Usage: $cmd [page]\n") if @$args>1 || (@$args && $args->[0]!~/\A[1-9][0-9]{0,4}\z/);
    my $page=$args->[0]//1;my (@lines,$title);
    if ($cmd eq 'channels') {
        @lines=map {$_->{name}.'  id='.$_->{channel_id}} $owner->channels($bot);
        $title='Registered channels (cache; select with use #channel)';
    } elsif ($cmd eq 'who') {
        @lines=$owner->nicks($bot,$state);$title='Cached nicks for '.$state->{channel};
    } elsif ($cmd eq 'plugins') {
        my $report=$owner->plugins($bot,$state);
        for my $row (@{$report->{packages}}) {
            push @lines,$row->{name}.': '.($row->{state} eq 'observed'
                ? join(' ',map {$_.'='.($row->{$_}//'unknown')} qw(lifecycle policy decision missing_capabilities quarantined_resources retained_failures))
                : 'unavailable');
        }
        $title="Loaded API v3 for $state->{channel}; state=$report->{state}; omitted=$report->{omitted}; legacy policy unknown";
    } else {
        my ($diagnostic,$report)=$owner->diagnosis($bot,$state);
        if ($cmd eq 'chansets') {
            @lines=map {$_.'='.$report->{flags}{$_}} sort keys %{$report->{flags}};
            $title="Diagnostic flag catalogue for $state->{channel}; database=$report->{database}; persisted observations";
        } else {@lines=@{$diagnostic->lines($report)};$title='Channel diagnostic (read-only)'}
    }
    _listing($out,_text($title,400),\@lines,$filters,$page,$cmd,$state);
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
        _error("Usage: ps [all|workers|schedulers|slow|running|stopped|failed] [page]\n") if @$args>2;
        my @a=@$args;
        $kind=shift @a if @a && $a[0]!~/\A[0-9]+\z/;
        $kind='workers' if $kind eq 'async';$kind='schedulers' if $kind eq 'sched';
        _error("Unknown task filter. Use help ps.\n") unless $kind=~/\A(?:all|workers|schedulers|slow|running|stopped|failed)\z/;
        $page=shift @a if @a;
        _error("Invalid page.\n") if @a || $page!~/\A[1-9][0-9]{0,4}\z/;
    }
    my @rows=_rows($p);
    @rows=grep {$kind eq 'all' || ($kind eq 'workers' && $_->{type} eq 'worker')
        || ($kind eq 'schedulers' && $_->{type} eq 'scheduler')
        || ($kind eq 'slow' && ($_->{elapsed_s}//$_->{last_duration_s}//0)>=1)
        || ($kind eq 'running' && $_->{state}=~/\A(?:running|enabled|stopping)\z/)
        || ($kind eq 'stopped' && $_->{state} eq 'stopped')
        || ($kind eq 'failed' && ($_->{callback_exceptions}//0)>0)} @rows;
    @rows=sort {(($a->{type} eq 'worker'?0:1)<=>($b->{type} eq 'worker'?0:1)) || (($b->{elapsed_s}//$b->{last_duration_s}//0)<=>($a->{elapsed_s}//$a->{last_duration_s}//0)) || $a->{id} cmp $b->{id}} @rows;
    my @lines=map {sprintf('%-7s %-9s %-9s %8.3fs  %s',$_->{id},$_->{type},$_->{state},
        $_->{elapsed_s}//$_->{last_duration_s}//0,$_->{name})} @rows;
    _listing($out,'ID      TYPE      STATE      AGE / LAST  NAME (GLOBAL)',\@lines,$filters,$page,"ps $kind",$state);
}
sub _capture_query {
    my ($p,$state,$parts)=@_;
    my $buffer=bless {text=>''},__PACKAGE__.'::Frame';
    _execute($p,$buffer,$state,$parts);
    return $buffer->{text};
}
sub _execute {
    my ($p,$out,$state,$parts)=@_;my ($cmd,@a)=@{$parts->[0]};my @filters=@$parts[1..$#$parts];
    for my $f (@filters) {
        my ($name,@args)=@$f;
        _error("Filters: grep [-i] <literal>, head/tail <1..50>, sort [-r].\n") unless
            ($name eq 'grep' && (@args==1 || (@args==2 && $args[0] eq '-i')))
            || ($name=~/\A(?:head|tail)\z/ && @args==1 && $args[0]=~/\A[1-9][0-9]?\z/ && $args[0]<=50)
            || ($name eq 'sort' && (!@args || (@args==1 && $args[0] eq '-r')));
    }
    _error("Filters apply only to read listings.\n") if @filters && $cmd!~/\A(?:ps|jobs|ls|channels|who|plugins|chansets|diagnose|watch)\z/;
    if ($cmd=~/\A(?:next|prev|refresh)\z/) {
        _error("Usage: $cmd\n") if @a;
        my $last=$state->{listing};
        _error("No listing yet. Run ps, channels or who first.\n") unless $last;
        _error("Listing context changed. Run the original command again.\n")
            unless $last->{channel} eq ($state->{channel}//'')
                && $last->{channel_id} eq ($state->{channel_id}//'') && $last->{cwd} eq $state->{cwd};
        my $page=$last->{page}+($cmd eq 'next'?1:$cmd eq 'prev'?-1:0);
        _error("First page reached.\n") if $page<1;
        _error("Last page reached. Use refresh to update the listing.\n") if $page>$last->{pages};
        my @base=_tokens($last->{command});
        push @{$base[0]},$page;
        push @base,map {[@$_]} @{$last->{filters}};
        _execute($p,$out,$state,\@base);return;
    }
    if ($cmd eq 'watch') {
        if (@a==1 && $a[0] eq 'off' && !@filters) {
            Mediabot::Partyline::ShellWatch->stop($p,$state->{session_id}) if defined $state->{session_id};
            _write($out,'Watch output stopped.');return;
        }
        my $interval=@a && $a[0]=~/\A[0-9]+\z/ ? shift(@a):5;
        _error("Usage: watch [5..60] <ps|jobs|ls|status|channels|channel|topic|who>; watch off\n")
            unless @a && $interval=~/\A[0-9]{1,2}\z/ && $interval>=5 && $interval<=60
                && $a[0]=~/\A(?:ps|jobs|ls|status|channels|channel|topic|who)\z/;
        my $read=[[@a],map {[@$_]} @filters];
        my $frame=_capture_query($p,$state,$read); # validate/render before registering anything
        my $id=$state->{session_id};
        Mediabot::Partyline::ShellWatch->start($p,$id,$out,interval=>$interval,
            render=>sub {my ($party,$context)=@_;return _capture_query($party,$context,$read)});
        _write($out,"Watch every ${interval}s (maximum five minutes). Any input stops refresh.");
        $out->write($frame);return;
    }
    if ($cmd =~ /\A(?:ps|jobs|ls)\z/) {_read($p,$out,$state,$cmd,\@a,\@filters);return}
    if ($cmd =~ /\A(?:channels|use|context|channel|topic|who|plugins|chansets|diagnose|status)\z/) {
        _context_command($p,$out,$state,$cmd,\@a,\@filters);return;
    }
    if ($cmd eq 'help' || $cmd eq '?') {_error("Usage: help [command]\n") if @a>1;_help($out,$a[0]);return}
    if ($cmd eq 'clear') {_error("Usage: clear\n") if @a;$out->write("\e[2J\e[H");return}
    if ($cmd eq 'pwd') {_error("Usage: pwd\n") if @a;_write($out,$state->{cwd});return}
    if ($cmd eq 'cd') {
        _error("Usage: cd [directory]\n") if @a>1;
        my $path=(@a && $a[0] eq '-') ? ($state->{previous_cwd}//'/') : _path($state->{cwd},$a[0]);
        _error("Directories: /, /workers, /schedulers.\n") unless $path=~m{\A/(?:workers|schedulers)?\z};
        ($state->{previous_cwd},$state->{cwd})=($state->{cwd},$path);return;
    }
    if ($cmd eq 'history') {
        _error("Usage: history [clear]\n") if @a>1 || (@a && $a[0] ne 'clear');
        if (@a) {$state->{history}=[];_write($out,'Shell history cleared.');return}
        _write($out,map {sprintf('%4d  %s',$_->{n},$_->{line})} @{$state->{history}});return;
    }
    if ($cmd eq 'complete') {
        _error("Usage: complete [prefix]\n") if @a>1;my $prefix=$a[0]//'';
        my @names=(@COMMANDS,'/workers','/schedulers',map {$_->{id}} _rows($p));
        push @names,map {$_->{name}} Mediabot::Partyline::ShellContext->channels($p->{bot})
            if ref($p->{bot}{channels}) eq 'HASH';
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
    my ($p,$out,$id,$raw)=@_;
    my $session=$p->{users}{$id} or return 0;
    return 0 unless $session->{authenticated};
    my $entry=$raw =~ /\A\.command(?:\s|\z)/i;
    return 0 if !$entry && (!$session->{command_mode} || $raw=~/\A\./);
    if (($entry && $raw=~/\A\.command\s+off\s*\z/i)
        || ($session->{command_mode} && $raw=~/\A\s*exit\s*\z/)) {
        delete $session->{command_mode};
        _write($out,'Chat mode. Type .command to return to the internal shell.');
        return 1;
    }
    unless (defined($session->{level}) && !ref($session->{level}) && "$session->{level}"=~/\A[01]\z/) {
        delete $session->{command_mode};
        _write($out,'Access denied: command mode requires Master or Owner.');
        return 1;
    }
    my $state=$session->{command_shell}||={cwd=>'/',history=>[],serial=>0};
    $state->{session_id}=$id;
    $state->{actor}=_text($session->{login},32);
    my $ok=eval {
        _error("Command is too long.\n") if length($raw)>1024;
        my $line=utf8::is_utf8($raw)?$raw:decode('UTF-8',$raw,FB_CROAK);
        _error("Control characters are not allowed.\n") if $line =~ /[\x00-\x1f\x7f-\x9f]/;
        $line =~ s/^\s+|\s+$//g;
        if ($entry) {
            $line =~ s/\A\.command\s*//i;
            if (length($line) && lc($line) ne 'on') {
                _error("Usage: .command [#channel|on|off]\n") if $line =~ /\s/;
                my $row=Mediabot::Partyline::ShellContext->select($p->{bot},$line);
                @$state{qw(channel channel_id)}=@$row{qw(name channel_id)};
            }
            $session->{command_mode}=1;
            _help($out);
        } elsif (length $line) {
            if ($line =~ /\A!(?:!|([1-9][0-9]{0,15}))\z/) {
                my $number=$1;
                my ($h)=defined($number)?grep {$_->{n}==$number} @{$state->{history}}:$state->{history}[-1];
                _error("History entry not available.\n") unless $h;
                # A channel command is never replayed into another channel.
                _error("History context changed; type the command again.\n")
                    unless ($h->{channel}//'') eq ($state->{channel}//'')
                        && ($h->{channel_id}//'') eq ($state->{channel_id}//'');
                $line=$h->{line};_write($out,$line);
            }
            my @parts=_tokens($line);
            unless ($parts[0][0] eq 'history') {
                push @{$state->{history}},{n=>++$state->{serial},line=>$line,
                    channel=>$state->{channel},channel_id=>$state->{channel_id}};
                shift @{$state->{history}} while @{$state->{history}}>20;
            }
            _execute($p,$out,$state,\@parts);
        }
        1;
    };
    unless ($ok) {
        my $err=$@;
        my $public=ref($err) eq __PACKAGE__.'::Usage'
            || ref($err) eq 'Mediabot::Partyline::ShellContext::Usage'
            || ref($err) eq 'Mediabot::Partyline::ShellWatch::Usage'
            ? _text($err->{public},160) : 'Operation failed. Inspect ps/show or use help.';
        _write($out,$public);
    }
    _prompt($out,$state) if $p->{users}{$id} && $p->{users}{$id}==$session && $session->{command_mode};
    return 1;
}
{
    package Mediabot::Partyline::TaskConsole::Frame;
    sub write {
        my ($self,$text)=@_;
        die bless {public=>'Watch frame exceeds 16 KiB.'},'Mediabot::Partyline::TaskConsole::Usage'
            if length(Encode::encode('UTF-8',$self->{text}.$text))>16384;
        $self->{text}.=$text;return 1;
    }
}
1;
