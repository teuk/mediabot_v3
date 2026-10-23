package Mediabot::Diagnostics::Channel;
use strict;
use warnings;
use utf8;
use Encode qw(decode FB_CROAK LEAVE_SRC);
use POSIX qw(strftime);
use Mediabot::IRC::TextBudget qw(_utf8_text_bytes);
use Mediabot::Diagnostics::Activity;

# Configuration observations only: never substitute this inventory for the
# feature's own authorization, caching, provider or delivery policy.
my @GROUPS = (
    ['links',qw(UrlTitle Youtube YoutubeSearch AppleMusic AppleMusicFallback Reddit)],
    ['conversation',qw(Hailo HailoLearn HailoRespond HailoChatter Spark SparkAction)],
    ['ai',qw(Claude Gemini MetaAI)],
    ['community',qw(VDM RandomQuote Games AchievementAnnounce Radio)],
    ['output',qw(AntiFlood NoColors)],
);
my @FLAGS=map {@$_[1..$#$_]} @GROUPS;

sub new {my ($class,%args)=@_;die "channel diagnostic bot required\n" unless $args{bot};return bless {bot=>$args{bot}},$class}
sub channel_text {
    my ($channel)=@_;
    return unless defined($channel) && !ref($channel);
    my $text=utf8::is_utf8($channel) ? $channel
        : eval {decode('UTF-8',$channel,FB_CROAK | LEAVE_SRC)};
    return unless defined($text) && $text =~ /\A#[^\x00-\x20\x7f-\x9f,:]+\z/
        && _utf8_text_bytes($text)<=200;
    return $text;
}
sub valid_channel {return defined(channel_text($_[0])) ? 1:0}

sub _rows {
    my ($dbh,$sql,@bind)=@_;
    my $sth=$dbh->prepare($sql) or die "database prepare failed\n";
    my @rows;
    my $ok=eval {
        $sth->execute(@bind) or die "database execute failed\n";
        while (my $row=$sth->fetchrow_hashref) {
            push @rows,{%$row};die "database result bound exceeded\n" if @rows>32;
        }
        die "database fetch failed\n" if $sth->err;
        1;
    };
    my $error=$@;eval {$sth->finish};die $error unless $ok;
    return \@rows;
}
sub _boolean {
    my ($value)=@_;
    return 'unknown' unless defined($value) && !ref($value) && "$value" =~ /\A[01]\z/;
    return $value ? 'yes':'no';
}
sub collect {
    my ($self,$channel)=@_;
    $channel=channel_text($channel);
    die "invalid channel\n" unless defined $channel;
    my $bot=$self->{bot};
    my $report={version=>2,channel=>"$channel",observed_at=>time(),database=>'unknown',
        transport_connected=>'unknown',runtime_active=>'unknown',runtime_connected=>'unknown',
        channel_joined=>'unknown',flags=>{map {$_=>'unknown'} @FLAGS},notes=>[]};
    my $dbh=eval {$bot->{db} ? $bot->{db}->ensure_connected : $bot->{dbh}};
    if (!$dbh) {$report->{database}='unavailable'}
    else {
        my $ok=eval {
            my $channels=_rows($dbh,'SELECT id_channel, name FROM CHANNEL WHERE name = ? LIMIT 1',$channel);
            if (@$channels) {
                my $row=$channels->[0];
                die "invalid channel row\n" unless valid_channel($row->{name})
                    && defined($row->{id_channel}) && "$row->{id_channel}" =~ /\A[1-9][0-9]*\z/;
                $report->{channel}=channel_text($row->{name});
                my $marks=join(',',map {'?'} @FLAGS);
                my $rows=_rows($dbh,"SELECT cl.chanset, CASE WHEN cs.id_channel_set IS NULL THEN 0 ELSE 1 END AS enabled
                    FROM CHANSET_LIST cl LEFT JOIN CHANNEL_SET cs
                    ON cs.id_chanset_list=cl.id_chanset_list AND cs.id_channel=?
                    WHERE cl.chanset IN ($marks)",$row->{id_channel},@FLAGS);
                my %flags=map {$_=>'missing'} @FLAGS;my %seen;
                for my $flag (@$rows) {
                    my $name=$flag->{chanset};
                    die "invalid flag row\n" unless defined($name) && exists($flags{$name}) && !$seen{$name}++
                        && defined($flag->{enabled}) && "$flag->{enabled}" =~ /\A[01]\z/;
                    $flags{$name}=$flag->{enabled} ? 'on':'off';
                }
                $report->{flags}=\%flags;$report->{database}='fresh';
            } else {$report->{database}='channel_not_found'}
            1;
        };
        $report->{database}='error' unless $ok;
    }
    my $connected;
    my $transport_ok=eval {$connected=$bot->{irc}->is_connected;1};
    $report->{transport_connected}=$connected ? 'yes':'no' if $transport_ok;
    my $runtime=eval {$bot->{wit_runtime_state}->snapshot($report->{channel})};
    if (ref($runtime) eq 'HASH') {
        $report->{runtime_active}=_boolean($runtime->{runtime_active});
        $report->{runtime_connected}=_boolean($runtime->{irc_connected});
        $report->{channel_joined}=_boolean($runtime->{channel_joined});
    }
    my $flags=$report->{flags};
    if ($flags->{AppleMusicFallback} eq 'on' && $flags->{AppleMusic} ne 'on') {
        push @{$report->{notes}},'AppleMusicFallback is configured on, but its AppleMusic preview prerequisite is '.$flags->{AppleMusic}.'.';
    }
    if ($report->{transport_connected} ne 'unknown' && $report->{runtime_connected} ne 'unknown'
        && $report->{transport_connected} ne $report->{runtime_connected}) {
        push @{$report->{notes}},'Transport and runtime connection observations disagree.';
    }
    push @{$report->{notes}},'Reddit and Youtube use their own flags; UrlTitle covers generic links, Spotify, Instagram, Facebook and X.';
    push @{$report->{notes}},'on/off describe persisted flags; runtime caches may lag. Missing is not an effective default.';
    $report->{activity}=Mediabot::Diagnostics::Activity->new(bot=>$bot)->collect($report->{channel},$report->{observed_at});
    push @{$report->{notes}},'RSS counters are reservations; task ticks are callback starts. No provider, delivery or last-error probe was performed.';
    return $report;
}
sub lines {
    my ($self,$report)=@_;
    my $stamp=strftime('%Y-%m-%d %H:%M:%S UTC',gmtime($report->{observed_at}));
    my @lines=(
        "Channel diagnosis $report->{channel} (read-only)",
        "Database: $report->{database}; observed $stamp",
        "IRC: transport=$report->{transport_connected}; runtime_active=$report->{runtime_active}; runtime_connected=$report->{runtime_connected}; joined=$report->{channel_joined}",
    );
    for my $group (@GROUPS) {
        push @lines,($group->[0] eq 'ai' ? 'AI':ucfirst($group->[0])).': '.join(' ',map {$_.'='.$report->{flags}{$_}} @$group[1..$#$group]);
    }
    push @lines,@{Mediabot::Diagnostics::Activity->new(bot=>$self->{bot})->lines($report->{activity})};
    push @lines,map {'Note: '.$_} @{$report->{notes}};
    return \@lines;
}
1;
