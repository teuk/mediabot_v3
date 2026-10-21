package Mediabot::XAuth;
use strict;
use warnings;
use Mediabot::IRC::CaseMapping qw(fold_irc);
use Scalar::Util qw(refaddr weaken);
use Digest::SHA qw(sha256_hex);
use Encode qw(encode);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

# MB838: one connection-bound controller for startup, operator requests and
# periodic verification. Server WHOIS account replies are authoritative; X's
# localized NOTICE text never grants authentication or releases channel joins.
sub new {
    my ($class,%args)=@_;
    my $self=bless {bot=>$args{bot},now=>$args{now}||sub{clock_gettime(CLOCK_MONOTONIC)},state=>'disconnected'},$class;
    weaken($self->{bot}) if ref($self->{bot});
    return $self;
}
sub _fold { return fold_irc(defined($_[0]) && !ref($_[0]) ? $_[0] : ''); }
sub _x_mode {
    my ($modes)=@_;my ($plus,$x)=(1,0);
    for my $ch (split //,$modes) {if($ch eq '+'){$plus=1}elsif($ch eq '-'){$plus=0}elsif($ch eq 'x'){$x=$plus}}
    return $x;
}
sub _config {
    my ($s)=@_;my $bot=$s->{bot};my $get=sub{my $v=eval{$bot->{conf}->get($_[0])};return defined($v)&&!ref($v)?"$v":''};
    my $type=$get->('connection.CONN_NETWORK_TYPE');
    my $raw_modes=eval{$bot->{conf}->get('connection.CONN_USERMODE')};
    my $modes_valid=!defined($raw_modes) || (!ref($raw_modes) && ($raw_modes eq '' || $raw_modes=~/\A[+-][A-Za-z+-]{1,80}\z/));
    my $modes=$modes_valid&&defined($raw_modes)?"$raw_modes":'';
    my $service=$get->('undernet.UNET_CSERVICE_LOGIN');
    my $user=$get->('undernet.UNET_CSERVICE_USERNAME');
    my $pass=$get->('undernet.UNET_CSERVICE_PASSWORD');
    my $interval=$get->('undernet.UNET_CSERVICE_CHECK_INTERVAL');
    $interval=300 unless $interval=~/\A[0-9]{1,5}\z/;
    $interval=60 if $interval>0 && $interval<60;$interval=3600 if $interval>3600;
    my $under=$type eq '1';
    my $valid=$under && $modes_valid && $service=~/\A[A-Za-z\[\]\\`_^{|}][A-Za-z0-9\[\]\\`_^{|}-]{0,29}\@[A-Za-z0-9][A-Za-z0-9.-]{0,149}\z/
        && $user=~/\A[A-Za-z0-9_\[\]{}|^`.-]{1,64}\z/
        && length($pass) && $pass!~/[\x00-\x20\x7f]/
        && length(encode('UTF-8',"PRIVMSG $service :LOGIN $user $pass\r\n"))<=510;
    return {under=>$under,valid=>$valid?1:0,service=>$service,user=>$user,pass=>$pass,
        want_x=>_x_mode($modes),invalid_modes=>$modes_valid?0:1,modes=>$modes,interval=>0+$interval,
        signature=>sha256_hex(encode('UTF-8',join("\0",$type,$service,$user,$pass,$modes,$modes_valid,$interval)))};
}
sub defer_joins {my $c=$_[0]->_config;return $c->{under} && ($c->{valid} || $c->{want_x} || $c->{invalid_modes})}
sub connect_modes {
    my ($s)=@_;my $c=$s->_config;my $m=$c->{modes};
    $m=~s/x//g if $c->{under};
    return $m=~/[A-Za-z]/?$m:'';
}
sub _log {my ($s,$reason)=@_;eval{$s->{bot}{logger}->log(0,'XAUTH state='.$s->{state}.' reason='.$reason)};return}
sub _cancel_joins {
    my ($s)=@_;return unless $s->{gated};my $b=$s->{bot} or return;
    my $loop=eval{$b->getLoop};
    for my $key (qw(_join_timers _join_who_timers)) {
        for my $t (@{delete($b->{$key})||[]}) {eval{$t->stop};eval{$loop->remove($t)} if $loop}
    }
}
sub reset {
    my ($s)=@_;$s->_cancel_joins;
    delete @{$s}{qw(irc signature pending due next_check last_login last_verified authenticated cloak released gated nick)};
    $s->{state}='disconnected';return 1;
}
sub _context {
    my ($s,$irc)=@_;my $b=$s->{bot} or return;
    my $current=$b->{irc};return unless $current && (!$irc || refaddr($current)==refaddr($irc));
    return unless $s->{irc} && refaddr($current)==refaddr($s->{irc}) && eval{$current->is_connected};
    my $c=$s->_config;return unless $c->{signature} eq ($s->{signature}//'');
    return ($current,$c);
}
sub on_login {
    my ($s,$irc)=@_;$s->reset;my $b=$s->{bot} or return 0;
    return 0 unless $irc && $b->{irc} && refaddr($irc)==refaddr($b->{irc}) && eval{$irc->is_connected};
    my $c=$s->_config;
    $s->{irc}=$irc;weaken($s->{irc});$s->{signature}=$c->{signature};$s->{gated}=$s->defer_joins;
    $s->{nick}=_fold($irc->nick_folded);
    unless($c->{valid}){$s->{state}=$c->{under}?'not_configured':'disabled';$s->_log('configuration') if $c->{under};return 0}
    return $s->_probe($irc,$c);
}
sub _send {
    my ($s,$irc,@args)=@_;my $ok=eval{$irc->send_message(@args);1};
    unless($ok){$s->{state}='send_failed';delete $s->{pending};delete $s->{due};$s->_log('transport')}
    return $ok?1:0;
}
sub _later {
    my ($s,$c)=@_;delete $s->{pending};delete $s->{due};
    if($c->{interval}){$s->{next_check}=$s->{now}->()+$c->{interval}}else{delete $s->{next_check}}
}
sub _probe {
    my ($s,$irc,$c)=@_;return 0 unless $c->{valid};
    return 1 if $s->{pending} || defined($s->{due});
    my $nick=$irc->nick_folded;return 0 unless defined($nick)&&!ref($nick)&&$nick=~/\A[A-Za-z\[\]\\`_^{|}][A-Za-z0-9\[\]\\`_^{|}-]{0,63}\z/;
    $s->{state}='checking';$s->{nick}=_fold($nick);
    $s->{pending}={kind=>'whois',nick=>_fold($nick),deadline=>$s->{now}->()+20};
    $s->{next_check}=$s->{now}->()+($c->{interval}||300);
    return $s->_send($irc,'WHOIS',undef,$nick);
}
sub request {
    my ($s)=@_;my ($irc,$c)=$s->_context;
    return 0 unless $irc && $c->{valid};
    return $s->_probe($irc,$c);
}
sub tick {
    my ($s)=@_;my $b=$s->{bot} or return;my $irc=$b->{irc};
    unless($irc && eval{$irc->is_connected}){$s->reset;return}
    # A new login callback owns activation. Never send credentials while an
    # unregistered/replacement transport is only beginning to connect.
    return unless $s->{irc} && refaddr($irc)==refaddr($s->{irc});
    my $c=$s->_config;
    if($c->{signature} ne ($s->{signature}//'')){
        # Refresh proof on the same live transport without canceling already
        # released paced joins or resetting the per-connection LOGIN cooldown.
        delete @{$s}{qw(pending due authenticated last_verified)};
        $s->{signature}=$c->{signature};
        $s->{gated}=$s->defer_joins unless $s->{released};
        unless($c->{valid}){$s->{state}=$c->{under}?'not_configured':'disabled';$s->_log('configuration');return}
        return $s->_probe($irc,$c);
    }
    return unless $c->{valid};
    if(_fold($irc->nick_folded) ne ($s->{nick}//'')) {
        delete $s->{pending};delete $s->{due};$s->{state}='unknown';
        $s->{next_check}=$s->{now}->();$s->{nick}=_fold($irc->nick_folded);
    }
    my $now=$s->{now}->();
    if($s->{pending} && $now >= $s->{pending}{deadline}) {
        $s->{state}='unverified';$s->_later($c);$s->_log('reply_timeout');return;
    }
    if(defined($s->{due}) && $now >= $s->{due}) {delete $s->{due};return $s->_probe($irc,$c)}
    if(!$s->{pending} && !defined($s->{due}) && defined($s->{next_check}) && $now >= $s->{next_check}) {return $s->_probe($irc,$c)}
    return;
}
sub _ready {
    my ($s,$irc,$c)=@_;$s->{state}='authenticated';$s->_later($c);$s->_log('verified');
    return unless $s->{gated} && !$s->{released};
    $s->{released}=1;
    my $b=$s->{bot} or return;
    for my $ch (values %{$b->{channels}||{}}) {
        next unless (eval{$ch->get_description}//'') eq 'console';
        $b->joinChannel($ch->get_name,$ch->get_key);last;
    }
    $b->joinChannels;
}
sub numeric {
    my ($s,$irc,$code,$prefix,$args)=@_;my ($current,$c)=$s->_context($irc);return 0 unless $current && $c->{valid};
    my $p=$s->{pending} or return 0;
    return 0 if $s->{now}->()>=$p->{deadline};
    return 0 unless defined($prefix)&&!ref($prefix)&&$prefix=~/\A[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9.-]+\z/;
    return 0 unless ref($args) eq 'ARRAY' && @$args>=2 && !grep{!defined($_)||ref($_)||/[\x00-\x1f\x7f]/}@$args;
    my $nick=_fold($current->nick_folded);
    return 0 unless _fold($args->[0]) eq $nick && $s->{nick} eq $nick;
    if($code eq '221') {
        return 0 unless $p->{kind} eq 'mode' && $args->[1]=~/\A[+-][A-Za-z+-]*\z/;
        $s->{cloak}=_x_mode($args->[1]);
        if($s->{cloak}){$s->_ready($current,$c);return 1}
        unless($p->{attempted}++) {
            return 0 unless $s->_send($current,'MODE',undef,$current->nick_folded,'+x');
            return $s->_send($current,'MODE',undef,$current->nick_folded);
        }
        $s->{state}='cloak_unconfirmed';$s->_later($c);$s->_log('mode_not_confirmed');return 1;
    }
    return 0 unless $p->{kind} eq 'whois' && _fold($args->[1]) eq $p->{nick};
    if($code eq '311') {
        return 0 unless @$args>=6;
        return 0 if $p->{server} && $p->{server} ne lc($prefix);
        $p->{server}=lc($prefix);$p->{seen}=1;return 1;
    }
    return 0 unless $p->{seen} && lc($prefix) eq $p->{server};
    if($code eq '330') {
        unless(@$args>=3 && $args->[2]=~/\A[A-Za-z0-9_\[\]{}|^`.-]{1,64}\z/) {$p->{invalid}=1;return 0}
        $p->{invalid}=1 if defined($p->{account}) && lc($p->{account}) ne lc($args->[2]);
        $p->{account}=$args->[2];return 1;
    }
    return 0 unless $code eq '318';
    my $account=$p->{account};delete $s->{pending};
    if($p->{invalid}){$s->{state}='unverified';$s->_later($c);$s->_log('invalid_account_reply');return 0}
    if(defined($account) && lc($account) eq lc($c->{user})) {
        $s->{authenticated}=1;$s->{last_verified}=$s->{now}->();
        unless($c->{want_x}){$s->_ready($current,$c);return 1}
        $s->{state}='checking_cloak';
        $s->{pending}={kind=>'mode',deadline=>$s->{now}->()+20};
        return $s->_send($current,'MODE',undef,$current->nick_folded);
    }
    $s->{authenticated}=0;
    if(defined($account)){$s->{state}='account_mismatch';$s->_later($c);$s->_log('different_account');return 1}
    if(defined($s->{last_login}) && $s->{now}->()-$s->{last_login}<300) {
        $s->{state}='not_authenticated';$s->_later($c);$s->_log('login_not_confirmed');return 1;
    }
    $s->{last_login}=$s->{now}->();$s->{state}='login_pending';
    # Use the IRC transport directly: service credentials must never pass
    # through conversation logging, badword rewriting, splitting or retries.
    unless($s->_send($current,'PRIVMSG',undef,$c->{service},'LOGIN '.$c->{user}.' '.$c->{pass})){$s->_later($c);return 0}
    $s->{due}=$s->{now}->()+5;$s->_log('login_sent');return 1;
}
sub status {
    my ($s)=@_;my $c=$s->_config;my ($irc)=$s->_context;
    my $state=!$c->{under}?'disabled':!$c->{valid}?'not_configured':!$irc?'disconnected':$s->{state};
    return {state=>$state,configuration_ok=>$c->{valid},undernet=>$c->{under},authenticated=>$irc&&$s->{authenticated}?1:0,
        cloak=>$irc&&$s->{cloak}?1:0,want_x=>$c->{want_x},interval=>$c->{interval},
        verified_age=>$irc&&defined($s->{last_verified})?int($s->{now}->()-$s->{last_verified}):undef};
}
1;
