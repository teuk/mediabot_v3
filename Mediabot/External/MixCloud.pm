package Mediabot::External::MixCloud;

use strict;
use warnings;
use utf8;
use URI ();
use URI::Escape qw(uri_unescape);
use HTML::Entities qw(decode_entities);
use Scalar::Util qw(refaddr);
use HTTP::Tiny ();
use Mediabot::JSON qw(decode_json_payload);
use Mediabot::AsyncWorker ();
use Mediabot::IRC::Text qw(decode_irc_text);
use Mediabot::IRC::TextBudget qw(_irc_wire_bytes _irc_prefix_for_budget);
use Mediabot::IRC::DeliveryContext qw(capture_delivery_context delivery_context_current);

sub badge { return "\x0300,02[🎛️ MixCloud]\x0f" }

# Own the public host even when its path is unsupported: -MixCloud must not
# fall through to a generic title request. Never match a nested URL or suffix.
sub is_mixcloud_url {
    my ($url) = @_;
    return 0 unless defined($url) && !ref($url) && length($url) <= 2048;
    my $u = eval { URI->new($url) };
    return 0 unless $u && ($u->scheme // '') =~ /\Ahttps?\z/i;
    my $host = eval { lc($u->host // '') } // '';
    return $host =~ /\A(?:www\.|m\.)?mixcloud\.com\.?\z/ ? 1 : 0;
}

sub url_info {
    my ($url) = @_;
    return unless is_mixcloud_url($url) && $url !~ /[\x00-\x20\x7f\\]/;
    my $u = eval { URI->new($url) };
    return unless $u && !defined($u->userinfo);
    my $port = eval { $u->port };
    return unless defined($port) && $port =~ /\A[0-9]{1,5}\z/
        && $port == (lc($u->scheme) eq 'https' ? 443 : 80);
    my $path = $u->path;
    return unless $path =~ m{\A/((?:[a-z0-9_-]|%[0-9a-f]{2}){1,100})/((?:[a-z0-9_-]|%[0-9a-f]{2}){1,400})/?\z}i;
    my ($owner, $show) = ($1, $2);
    for my $segment ($owner, $show) {
        my $decoded = uri_unescape($segment);
        return if $decoded =~ /[\x00-\x20\x7f\\\/?#]/ || $decoded eq '.' || $decoded eq '..';
    }
    return if $owner =~ /\A(?:genres|discover|search|live|upload|settings|oauth|dashboard|login|signup)\z/i;
    my $key = "/$owner/$show/";
    return { key => $key, url => 'https://www.mixcloud.com'.$key,
        api => 'https://api.mixcloud.com'.$key };
}

# Fresh, per-channel opt-in; a missing catalogue row or failed read is off.
sub enabled {
    my ($bot, $channel) = @_;
    return 0 unless defined($channel) && !ref($channel)
        && $channel =~ /\A#[^\x00-\x20\x7f,:]{1,254}\z/;
    my $on = eval {
        my $db = $bot->{db} ? $bot->{db}->ensure_connected : $bot->{dbh};
        return 0 unless $db;
        my $sth = $db->prepare(q{SELECT CS.id_channel_set FROM CHANNEL_SET CS
            JOIN CHANNEL C ON C.id_channel=CS.id_channel
            JOIN CHANSET_LIST CL ON CL.id_chanset_list=CS.id_chanset_list
            WHERE C.name=? AND CL.chanset=?}) or return 0;
        my $ok = $sth->execute($channel, 'MixCloud');
        my $row = $ok ? $sth->fetchrow_arrayref : undef;
        my $error = $sth->err;
        $sth->finish;
        return $ok && !$error && $row ? 1 : 0;
    };
    return $on ? 1 : 0;
}

sub register_chanset {
    my ($bot) = @_;
    my $db = $bot->{dbh} or return;
    return eval {
        my $sth = $db->prepare(q{INSERT INTO CHANSET_LIST(chanset)
            SELECT ? WHERE NOT EXISTS(SELECT 1 FROM CHANSET_LIST WHERE chanset=?)}) or return;
        my $ok = $sth->execute('MixCloud', 'MixCloud');
        $sth->finish;
        return $ok ? 1 : undef;
    };
}
sub epoch { return $_[0]{_mixcloud_epoch}{lc($_[1])} // 0 }
sub note_policy_change { return ++$_[0]{_mixcloud_epoch}{lc($_[1])} }

sub _plain {
    my ($value, $max) = @_;
    return unless defined($value) && !ref($value);
    $value = substr(decode_irc_text($value), 0, $max // 512);
    $value = decode_entities($value);
    $value =~ s{</?[a-z][^>]*>}{}ig;
    $value =~ s/\x03[0-9]{0,2}(?:,[0-9]{1,2})?//g;
    $value =~ s/\x04[0-9a-f]{6}(?:,[0-9a-f]{6})?//ig;
    $value =~ s/[\x00-\x1f\x7f-\x9f\x{200e}\x{200f}\x{202a}-\x{202e}\x{2066}-\x{2069}\x{feff}]/ /g;
    $value =~ s/\s+/ /g;
    $value =~ s/^\s+|\s+$//g;
    return length($value) ? $value : undef;
}

sub _result {
    my ($raw) = @_;
    return {state=>'unavailable'} unless ref($raw) eq 'HASH'
        && defined($raw->{state}) && !ref($raw->{state}) && $raw->{state} eq 'ok';
    my $title = _plain($raw->{title});
    return {state=>'unavailable'} unless defined $title;
    my $out = {state=>'ok', title=>$title};
    my $author = _plain($raw->{author}, 80);
    $author = _irc_prefix_for_budget($author, 80) if defined $author;
    $out->{author} = $author if defined $author;
    $out->{seconds} = 0+$raw->{seconds} if defined($raw->{seconds}) && !ref($raw->{seconds})
        && "$raw->{seconds}" =~ /\A[0-9]{1,8}\z/ && $raw->{seconds} > 0 && $raw->{seconds} <= 31536000;
    return $out;
}

sub parse_show {
    my ($payload, $info) = @_;
    return unless ref($info) eq 'HASH' && defined($payload) && !ref($payload)
        && length($payload) <= 256*1024;
    my $data = eval { decode_json_payload($payload) };
    return unless ref($data) eq 'HASH' && !exists($data->{error});
    return unless defined($data->{key}) && !ref($data->{key}) && $data->{key} eq $info->{key};
    if (exists $data->{url}) {
        my $link = url_info($data->{url});
        return unless $link && $link->{key} eq $info->{key};
    }
    my $user = ref($data->{user}) eq 'HASH' ? $data->{user} : {};
    my $out = _result({state=>'ok', title=>$data->{name}, author=>$user->{name}, seconds=>$data->{audio_length}});
    return $out->{state} eq 'ok' ? $out : undef;
}

sub fetch {
    my ($url) = @_;
    my $info = url_info($url);
    return {state=>'unavailable'} unless $info;
    # A fixed public API destination, one bounded request, no cookies or tokens.
    my $http = HTTP::Tiny->new(timeout=>8, max_size=>256*1024,
        max_redirect=>0, verify_SSL=>1, agent=>'Mediabot MixCloud preview');
    my $r = eval { $http->get($info->{api}, {headers=>{Accept=>'application/json'}}) };
    return {state=>'unavailable'} unless ref($r) eq 'HASH' && $r->{success};
    return parse_show($r->{content}, $info) // {state=>'unavailable'};
}

sub render {
    my ($nick, $raw) = @_;
    my $r = _result($raw);
    $nick = _irc_prefix_for_budget(_plain($nick, 80) // '', 80);
    my $prefix = "($nick) ".badge().' ';
    my $title = $r->{state} eq 'ok' ? $r->{title} : 'aperçu indisponible';
    my $suffix = defined($r->{author}) ? ' — '.$r->{author} : '';
    if (my $s = $r->{seconds}) {
        my ($h, $m, $sec) = (int($s/3600), int(($s%3600)/60), $s%60);
        $suffix .= ' · '.($h ? sprintf('%dh%02dm%02ds', $h, $m, $sec) : sprintf('%dm%02ds', $m, $sec));
    }
    my $budget = 400 - _irc_wire_bytes($prefix.$suffix) - 3;
    my $text = _irc_prefix_for_budget($title, $budget);
    $text = _irc_prefix_for_budget($title, $budget-3).'…' if _irc_wire_bytes($title) > $budget;
    return $prefix."\x02".$text."\x02".$suffix."\x0f";
}

sub handle {
    my ($bot, $message, $nick, $channel, $url) = @_;
    my $info = url_info($url);
    return 0 unless $info && enabled($bot, $channel);
    my $binding = capture_delivery_context($bot, $channel);
    my $epoch = epoch($bot, $channel);
    my $current = sub { delivery_context_current($bot, $binding)
        && epoch($bot, $channel) == $epoch && enabled($bot, $channel) };
    my $loop = eval { $bot->getLoop };
    $loop ||= $bot->{loop};
    return 0 unless $loop && eval { $loop->can('add') && $loop->can('remove') && $loop->can('watch_process') };
    my $state = $bot->{_mixcloud_preview} //= {cache=>{}, pending=>{}, recent=>{}, starts=>[]};
    my $now = time;
    delete $state->{cache}{$_} for grep {$state->{cache}{$_}{until} <= $now} keys %{$state->{cache}};
    delete $state->{recent}{$_} for grep {$state->{recent}{$_} <= $now-300} keys %{$state->{recent}};
    my $request = lc($channel)."\0".$info->{key};
    return 1 if exists $state->{recent}{$request};
    return 0 if keys(%{$state->{recent}}) >= 512;
    my $send = sub {
        my ($value) = @_;
        return unless $current->();
        require Mediabot::Helpers;
        Mediabot::Helpers::botPrivmsg($bot, $channel, render($nick, $value), {no_defer=>1});
    };
    if (my $cache = $state->{cache}{$info->{key}}) {
        $state->{recent}{$request} = $now;
        $send->($cache->{value});
        return 1;
    }
    if (my $pending = $state->{pending}{$info->{key}}) {
        return 0 if @{$pending->{send}} >= 16;
        push @{$pending->{send}}, $send;
        $state->{recent}{$request} = $now;
        return 1;
    }
    @{$state->{starts}} = grep {$_ > $now-60} @{$state->{starts}};
    return 0 if keys(%{$state->{pending}}) >= 4 || @{$state->{starts}} >= 12;
    push @{$state->{starts}}, $now;
    $state->{recent}{$request} = $now;
    my $attempt = {send=>[$send]};
    $state->{pending}{$info->{key}} = $attempt;
    my $done = 0;
    my $complete = sub {
        my ($result) = @_;
        return if $done++;
        return unless $state->{pending}{$info->{key}}
            && refaddr($state->{pending}{$info->{key}}) == refaddr($attempt);
        delete $state->{pending}{$info->{key}};
        my $value = _result(ref($result) eq 'HASH' && $result->{ok} ? $result->{value} : undef);
        $state->{cache}{$info->{key}} = {until=>time+($value->{state} eq 'ok' ? 300 : 30), value=>$value};
        while (keys(%{$state->{cache}}) > 128) {
            my ($old) = sort {$state->{cache}{$a}{until} <=> $state->{cache}{$b}{until}} keys %{$state->{cache}};
            delete $state->{cache}{$old};
        }
        for my $recipient (@{$attempt->{send}}) { eval { $recipient->($value) } }
        $attempt->{send} = [];
    };
    my $worker = eval { Mediabot::AsyncWorker->start(loop=>$loop, label=>'MixCloud preview', timeout=>12, max_output=>8192,
        child=>sub {
            eval {$bot->{dbh}{InactiveDestroy}=1 if $bot->{dbh}};
            eval {$bot->{db}{dbh}{InactiveDestroy}=1 if $bot->{db} && $bot->{db}{dbh}};
            return fetch($info->{url});
        }, on_done=>$complete) };
    $complete->({ok=>0}) unless $worker || $done;
    return 1;
}

1;
