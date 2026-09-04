package Mediabot::Fullop;

use strict;
use warnings;
use utf8;

# +Fullop keeps a channel deliberately open while allowing every participant
# to be an IRC operator.  Policy is derived from ISUPPORT instead of assuming
# that mode letters have the same shape on every network (notably +q, which is
# an owner prefix on some IRCds and a quiet list on others).

use constant DEFAULT_BAN_SECONDS => 600;
use constant DEFAULT_REASON      => q{hey ho, c'est pas le genre de la maison};
use constant DELEGATED_BAN_WINDOW_SECONDS => 5;
use constant MAX_PENDING_DELEGATED_BANS    => 32;

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        bot              => $args{bot},
        channel_ban      => $args{channel_ban},
        enabled_cb       => $args{enabled_cb},
        privileged_cb    => $args{privileged_cb},
        send_cb          => $args{send_cb},
        announce_cb      => $args{announce_cb},
        nicklist_cb      => $args{nicklist_cb},
        channel_id_cb    => $args{channel_id_cb},
        isupport         => {},
        prefix_modes     => { o => '@', v => '+' },
        prefix_order     => 'ov',
        chanmode_groups  => [ 'beI', 'k', 'l', 'imnpst' ],
        max_modes        => 4,
        casemapping      => 'rfc1459',
        channel_state    => {},
        now_cb           => ref($args{now_cb}) eq 'CODE'
                            ? $args{now_cb} : sub { time() },
        delegated_service_masks => ref($args{delegated_service_masks}) eq 'ARRAY'
                            ? [ @{ $args{delegated_service_masks} } ] : undef,
        pending_delegated_bans => [],
    }, $class;

    my $configured_network = $args{network};
    if (!defined($configured_network) && $self->{bot}) {
        $configured_network = eval {
            $self->{bot}{conf}->get('connection.CONN_SERVER_NETWORK')
        };
    }
    $self->{network} = defined($configured_network) ? $configured_network : '';

    return $self;
}

sub _log {
    my ($self, $level, $text) = @_;
    return unless $self->{bot} && $self->{bot}{logger};
    $self->{bot}{logger}->log($level, $text);
}

sub reason { return DEFAULT_REASON }

sub ban_seconds {
    my ($self) = @_;
    my $seconds = DEFAULT_BAN_SECONDS;
    if ($self->{bot} && $self->{bot}{conf}) {
        $seconds = eval {
            $self->{bot}{conf}->get_int(
                'fullop.BAN_SECONDS',
                default => DEFAULT_BAN_SECONDS,
                min     => 60,
                max     => 3600,
            );
        } // DEFAULT_BAN_SECONDS;
    }
    return int($seconds);
}

sub enabled {
    my ($self, $channel) = @_;
    return 0 unless defined($channel) && $channel =~ /^[#&!+]/;

    if ($self->{enabled_cb}) {
        return $self->{enabled_cb}->($channel) ? 1 : 0;
    }

    return 0 unless $self->{bot};
    my $enabled = eval {
        require Mediabot::Helpers;
        Mediabot::Helpers::chanset_enabled(
            $self->{bot}, $channel, 'Fullop', default => 0
        );
    };
    return $enabled ? 1 : 0;
}

sub update_isupport {
    my ($self, @tokens) = @_;

    for my $token (@tokens) {
        next unless defined($token) && length($token);
        $token =~ s/^://;
        next if $token =~ /\s/;

        if ($token =~ /^-(\w+)$/) {
            delete $self->{isupport}{uc($1)};
            next;
        }
        next unless $token =~ /^(\w+)(?:=(.*))?$/;
        my ($key, $value) = (uc($1), defined($2) ? $2 : '');
        $self->{isupport}{$key} = $value;

        if ($key eq 'NETWORK' && $value ne '') {
            $self->{network} = $value;
        }
        elsif ($key eq 'CASEMAPPING' && $value =~ /^(?:ascii|rfc1459|strict-rfc1459)$/i) {
            $self->{casemapping} = lc($value);
        }
        elsif ($key eq 'MODES' && $value =~ /^\d+$/) {
            my $max = int($value);
            $self->{max_modes} = $max if $max >= 1 && $max <= 20;
        }
        elsif ($key eq 'PREFIX' && $value =~ /^\(([A-Za-z]+)\)(.+)$/) {
            my ($modes, $prefixes) = ($1, $2);
            if (length($modes) == length($prefixes)) {
                my %map;
                @map{split //, $modes} = split //, $prefixes;
                $self->{prefix_modes} = \%map;
                $self->{prefix_order} = $modes;
            }
        }
        elsif ($key eq 'CHANMODES') {
            my @groups = split /,/, $value, -1;
            $self->{chanmode_groups} = \@groups if @groups == 4;
        }
    }

    return 1;
}

sub network_name {
    my ($self) = @_;
    return $self->{network} // '';
}

sub _fold {
    my ($self, $value) = @_;
    $value = lc($value // '');
    my $mapping = $self->{casemapping} // 'rfc1459';
    if ($mapping eq 'rfc1459') {
        $value =~ tr/[]\\^/{}|~/;
    }
    elsif ($mapping eq 'strict-rfc1459') {
        $value =~ tr/[]\\/{}|/;
    }
    return $value;
}

sub names_from_blob {
    my ($self, $blob) = @_;
    return () unless defined($blob) && $blob ne '';

    my %prefix = map { $_ => 1 } values %{ $self->{prefix_modes} || {} };
    my @nicks;
    for my $token (split /\s+/, $blob) {
        next unless defined($token) && $token ne '';
        while (length($token) && $prefix{substr($token, 0, 1)}) {
            substr($token, 0, 1, '');
        }
        push @nicks, $token if $token ne '';
    }
    return @nicks;
}

sub _mode_category {
    my ($self, $mode) = @_;
    return 'status' if exists $self->{prefix_modes}{$mode};

    my @names = qw(A B C D);
    for my $idx (0 .. 3) {
        my $letters = $self->{chanmode_groups}[$idx] // '';
        return $names[$idx] if index($letters, $mode) >= 0;
    }
    return 'unknown';
}

sub _mode_takes_arg {
    my ($self, $sign, $category) = @_;
    return 1 if $category eq 'status' || $category eq 'A' || $category eq 'B';
    return $sign eq '+' ? 1 : 0 if $category eq 'C';
    return 0;
}

sub parse_mode_changes {
    my ($self, $mode_string, @args) = @_;
    return () unless defined($mode_string) && $mode_string ne '';

    my $sign = '+';
    my $arg_index = 0;
    my @changes;

    for my $char (split //, $mode_string) {
        if ($char eq '+' || $char eq '-') {
            $sign = $char;
            next;
        }
        next unless $char =~ /[A-Za-z]/;

        my $category = $self->_mode_category($char);
        my $takes_arg = $self->_mode_takes_arg($sign, $category);
        my $arg = $takes_arg ? $args[$arg_index++] : undef;

        push @changes, {
            sign      => $sign,
            mode      => $char,
            category  => $category,
            takes_arg => $takes_arg,
            arg       => $arg,
        };
    }

    return @changes;
}

sub _network_profile_modes {
    my ($self) = @_;
    my $network = lc($self->network_name);

    # Baseline RFC controls: ban/exemption lists and modes able to stop joins
    # or ordinary speech.  q is handled separately because it can be a status.
    my %modes = map { $_ => 1 } split //, 'beIiklm';

    if ($network =~ /(?:libera|solanum)/) {
        $modes{$_} = 1 for split //, 'fjqrRSz';
    }
    elsif ($network =~ /(?:epik|inspircd)/) {
        # InspIRCd networks commonly expose these optional restrictions.  Only
        # letters actually seen in a MODE line are acted upon.
        $modes{$_} = 1 for split //, 'BCGJLMORSTcdfjqrz';
    }
    elsif ($network =~ /undernet/) {
        $modes{$_} = 1 for split //, 'Dru';
    }

    my $configured = '';
    if ($self->{bot} && $self->{bot}{conf}) {
        $configured = eval {
            $self->{bot}{conf}->get('fullop.PROTECTED_MODES')
        } // '';
    }
    $modes{$_} = 1 for grep { /[A-Za-z]/ } split //, $configured;

    return \%modes;
}

sub _is_higher_status_than_op {
    my ($self, $mode) = @_;
    my $order = $self->{prefix_order} // '';
    my $op_index = index($order, 'o');
    my $mode_index = index($order, $mode);
    return 0 if $op_index < 0 || $mode_index < 0;
    return $mode_index < $op_index ? 1 : 0;
}

sub _is_protected_change {
    my ($self, $change) = @_;
    my ($mode, $sign, $category) = @{$change}{qw(mode sign category)};

    if ($category eq 'status') {
        return 1 if $mode eq 'o' && $sign eq '-';
        return 1 if $self->_is_higher_status_than_op($mode);
        return 0;
    }

    # q is a quiet list only when ISUPPORT did not declare it as a PREFIX mode.
    return 1 if $mode eq 'q' && $category eq 'A';

    my $profile = $self->_network_profile_modes;
    return $profile->{$mode} ? 1 : 0;
}

sub _state_for {
    my ($self, $channel) = @_;
    return ($self->{channel_state}{$self->_fold($channel)} //= {
        simple => {}, scalar => {}, list => {}, status => {},
    });
}

sub _remember_change {
    my ($self, $channel, $change) = @_;
    my $state = $self->_state_for($channel);
    my ($mode, $sign, $category, $arg) =
        @{$change}{qw(mode sign category arg)};

    if ($category eq 'status') {
        return unless defined($arg) && $arg ne '';
        if ($sign eq '+') {
            $state->{status}{$mode}{$self->_fold($arg)} = $arg;
        } else {
            delete $state->{status}{$mode}{$self->_fold($arg)};
        }
    }
    elsif ($category eq 'A') {
        return unless defined($arg) && $arg ne '';
        if ($sign eq '+') {
            $state->{list}{$mode}{$arg} = 1;
        } else {
            delete $state->{list}{$mode}{$arg};
        }
    }
    elsif ($category eq 'B' || $category eq 'C') {
        if ($sign eq '+') {
            $state->{scalar}{$mode} = $arg if defined($arg) && $arg ne '';
        } else {
            delete $state->{scalar}{$mode};
        }
    }
    else {
        if ($sign eq '+') {
            $state->{simple}{$mode} = 1;
        } else {
            delete $state->{simple}{$mode};
        }
    }
}

sub remember_channel_modes {
    my ($self, $channel, $mode_string, @args) = @_;
    return 0 unless defined($channel) && $channel ne '';

    $self->{channel_state}{$self->_fold($channel)} = {
        simple => {}, scalar => {}, list => {}, status => {},
    };
    my @changes = $self->parse_mode_changes($mode_string, @args);
    $self->_remember_change($channel, $_) for @changes;
    return scalar @changes;
}

sub _prior_scalar_arg {
    my ($self, $channel, $mode) = @_;
    my $state = $self->_state_for($channel);
    return $state->{scalar}{$mode};
}

sub _correction_commands {
    my ($self, $channel, $change) = @_;
    my ($sign, $mode, $category, $arg) =
        @{$change}{qw(sign mode category arg)};
    my $inverse = $sign eq '+' ? '-' : '+';
    my $state = $self->_state_for($channel);

    if ($category eq 'status' || $category eq 'A') {
        return () unless defined($arg) && $arg ne '';

        # -o is always repaired because +Fullop's invariant is that a present
        # user is an op even when a stale NAMES snapshot did not retain status.
        if ($category eq 'status') {
            return ([ $inverse . $mode, $arg ]);
        }

        my $was_listed = $state->{list}{$mode}{$arg} ? 1 : 0;
        return () if $sign eq '+' && $was_listed;
        return ([ $inverse . $mode, $arg ]);
    }
    if ($category eq 'B') {
        my $previous = $self->_prior_scalar_arg($channel, $mode);
        if ($sign eq '+') {
            return () if defined($previous) && defined($arg) && $previous eq $arg;
            return () unless defined($arg) && $arg ne '';
            my @commands = ([ '-' . $mode, $arg ]);
            push @commands, [ '+' . $mode, $previous ]
                if defined($previous) && $previous ne '';
            return @commands;
        }

        my $restore = defined($previous) && $previous ne '' ? $previous : $arg;
        return () unless defined($restore) && $restore ne '' && $restore ne '*';
        return ([ '+' . $mode, $restore ]);
    }
    if ($category eq 'C') {
        my $previous = $self->_prior_scalar_arg($channel, $mode);
        if ($sign eq '+') {
            return () if defined($previous) && defined($arg) && $previous eq $arg;
            my @commands = ([ '-' . $mode ]);
            push @commands, [ '+' . $mode, $previous ]
                if defined($previous) && $previous ne '';
            return @commands;
        }
        return () unless defined($previous) && $previous ne '';
        return ([ '+' . $mode, $previous ]);
    }

    my $was_set = $state->{simple}{$mode} ? 1 : 0;
    return () if $sign eq '+' && $was_set;
    return ([ $inverse . $mode ]);
}

sub _send {
    my ($self, @args) = @_;
    return $self->{send_cb}->(@args) if $self->{send_cb};
    return 0 unless $self->{bot} && $self->{bot}{irc};
    $self->{bot}{irc}->send_message(@args);
    return 1;
}

sub _announce {
    my ($self, $channel, $nick) = @_;
    my $text = "$nick: " . DEFAULT_REASON;
    return $self->{announce_cb}->($channel, $text) if $self->{announce_cb};
    return 0 unless $self->{bot};
    require Mediabot::Helpers;
    Mediabot::Helpers::botPrivmsg($self->{bot}, $channel, $text);
    return 1;
}

sub _nicklist {
    my ($self, $channel) = @_;
    return $self->{nicklist_cb}->($channel) if $self->{nicklist_cb};
    return () unless $self->{bot};
    return $self->{bot}->gethChannelsNicksOnChan($channel);
}

sub _channel_id {
    my ($self, $channel) = @_;
    return $self->{channel_id_cb}->($channel) if $self->{channel_id_cb};
    return undef unless $self->{bot};
    my $obj = $self->{bot}{channels}{lc($channel)};
    return eval { $obj->get_id };
}

sub _irc_glob_match {
    my ($pattern, $subject) = @_;
    return 0 unless defined($pattern) && defined($subject) && $pattern ne '';
    my $quoted = quotemeta($pattern);
    $quoted =~ s/\\\*/.*/g;
    $quoted =~ s/\\\?/./g;
    return eval { $subject =~ /^$quoted$/i } ? 1 : 0;
}

sub _trusted_service_patterns {
    my ($self) = @_;
    my $network = lc($self->network_name);
    my @patterns;

    push @patterns, 'X!cservice@undernet.org', 'X!cservice@*.undernet.org'
        if $network =~ /undernet/;
    push @patterns, 'ChanServ!ChanServ@services.libera.chat'
        if $network =~ /(?:libera|solanum)/;

    if ($self->{bot} && $self->{bot}{conf}) {
        my $raw = eval {
            $self->{bot}{conf}->get('fullop.TRUSTED_SERVICE_MASKS')
        } // '';
        push @patterns, grep { $_ ne '' } split /[\s,]+/, $raw;
    }

    return @patterns;
}

sub _delegated_ban_service_masks {
    my ($self) = @_;
    my $network = lc($self->network_name);
    my @masks;

    # Cronos is an official EpiKnet channel service. It is deliberately not a
    # generally trusted Fullop actor: the exact prefix is usable only through
    # the one-shot, target-bound delegation below.
    push @masks, 'Cronos!services@olympe.epiknet.org'
        if $network =~ /epik/;

    if (defined $self->{delegated_service_masks}) {
        push @masks, @{ $self->{delegated_service_masks} };
    }
    elsif ($self->{bot} && $self->{bot}{conf}) {
        my $raw = eval {
            $self->{bot}{conf}->get('fullop.DELEGATED_BAN_SERVICES')
        } // '';
        for my $entry (grep { $_ ne '' } split /[\s,]+/, $raw) {
            my ($scope, $mask) = split /\|/, $entry, 2;
            next unless defined($scope) && defined($mask);
            next unless lc($scope) eq $network;
            push @masks, $mask;
        }
    }

    my %seen;
    return grep {
        defined($_)
            && $_ =~ /^[^!*?\s|]+![^@*?\s|]+\@[^*?\s|]+$/
            && !$seen{lc($_)}++
    } @masks;
}

sub _now {
    my ($self) = @_;
    my $now = eval { $self->{now_cb}->() };
    return undef unless defined($now)
        && !ref($now)
        && $now =~ /^\d+(?:\.\d+)?$/;
    return 0 + $now;
}

sub _literal_ban_host {
    my ($mask) = @_;
    return undef unless defined($mask) && $mask ne '';
    my ($host) = $mask =~ /\@([^@]+)$/;
    return undef unless defined($host)
        && $host ne ''
        && $host !~ /[*?\s]/;
    return lc($host);
}

sub _purge_pending_delegations {
    my ($self, $now) = @_;
    $self->{pending_delegated_bans} = [
        grep { ($_->{expires_at} // -1) >= $now }
        @{ $self->{pending_delegated_bans} || [] }
    ];
    return scalar @{ $self->{pending_delegated_bans} };
}

sub authorize_delegated_ban {
    my ($self, %args) = @_;
    my $channel = $args{channel};
    return 0 unless $self->enabled($channel);
    return 0 unless $self->_delegated_ban_service_masks;

    my $host = _literal_ban_host($args{mask});
    return 0 unless defined($host);

    my $now = $self->_now;
    return 0 unless defined($now);
    $self->_purge_pending_delegations($now);

    my $pending = $self->{pending_delegated_bans};
    shift @$pending while @$pending >= MAX_PENDING_DELEGATED_BANS;
    push @$pending, {
        channel    => $self->_fold($channel),
        host       => $host,
        ban_id     => $args{ban_id},
        expires_at => $now + DELEGATED_BAN_WINDOW_SECONDS,
    };

    my $id = defined($args{ban_id}) ? " #$args{ban_id}" : '';
    $self->_log(4,
        "Fullop: armed one-shot delegated ban$id on $channel for "
        . DELEGATED_BAN_WINDOW_SECONDS . 's');
    return 1;
}

sub _consume_delegated_ban {
    my ($self, $channel, $prefix, $change) = @_;
    return 0 unless defined($change)
        && $change->{sign} eq '+'
        && $change->{mode} eq 'b'
        && $change->{category} eq 'A';

    my %service = map { lc($_) => 1 } $self->_delegated_ban_service_masks;
    return 0 unless defined($prefix) && $service{lc($prefix // '')};

    my $host = _literal_ban_host($change->{arg});
    return 0 unless defined($host);

    my $now = $self->_now;
    return 0 unless defined($now);
    $self->_purge_pending_delegations($now);

    my $channel_key = $self->_fold($channel);
    my $pending = $self->{pending_delegated_bans};
    for my $idx (0 .. $#$pending) {
        my $token = $pending->[$idx];
        next unless $token->{channel} eq $channel_key;
        next unless $token->{host} eq $host;
        splice @$pending, $idx, 1;

        $self->_remember_change($channel, $change);
        $self->_log(3,
            "Fullop: accepted one delegated +b on $channel from $prefix");
        if ($self->{bot} && $self->{bot}{metrics}) {
            $self->{bot}{metrics}->inc(
                'mediabot_fullop_delegated_bans_total',
                { channel => $channel },
            );
        }
        return 1;
    }
    return 0;
}

sub _actor_is_privileged {
    my ($self, $message, $channel, $prefix) = @_;

    return 1 if !defined($prefix) || $prefix eq '' || $prefix !~ /!/;
    return $self->{privileged_cb}->($message, $channel, $prefix) ? 1 : 0
        if $self->{privileged_cb};

    my ($nick) = $prefix =~ /^([^!]+)/;
    return 1 if $self->{bot} && eval { $self->{bot}{irc}->is_nick_me($nick) };
    return 1 if grep { _irc_glob_match($_, $prefix) }
                $self->_trusted_service_patterns;

    return 0 unless $self->{bot};
    my $user = eval { $self->{bot}->get_user_from_message($message) };
    return 0 unless $user && eval { $user->is_authenticated };
    return 1 if eval { $user->has_level('Administrator') };

    my $uid = eval { $user->id };
    return 0 unless defined($uid) && $uid ne '';
    my $allowed = eval {
        require Mediabot::Helpers;
        Mediabot::Helpers::checkUserChannelLevel(
            $self->{bot}, $message, $channel, $uid, 75
        );
    };
    return $allowed ? 1 : 0;
}

sub _sanction {
    my ($self, $channel, $prefix) = @_;
    return 0 unless defined($prefix)
        && $prefix =~ /^([^!]+)!([^@]+)\@(.+)$/;
    my ($nick, $ident, $host) = ($1, $2, $3);
    return 0 unless $nick ne '' && $ident ne '' && $host ne '';

    my $mask;
    if ($self->{channel_ban}) {
        $mask = $self->{channel_ban}->mask_from_hostmask($prefix);
    }
    $mask //= "*!*$ident\@$host";

    my $id_channel = $self->_channel_id($channel);
    my ($id, $error);
    my $stored = 0;
    if ($self->{channel_ban} && $id_channel) {
        my $ok = eval {
            ($id, $error) = $self->{channel_ban}->add_ban(
                id_channel      => $id_channel,
                mask            => $mask,
                ban_level       => 75,
                reason          => DEFAULT_REASON,
                created_by      => undef,
                created_by_nick => 'Mediabot +Fullop',
                expires_seconds => $self->ban_seconds,
                source          => 'fullop',
            );
            1;
        };
        if (!$ok) {
            ($error = $@ || 'unknown persistence exception') =~ s/\s+/ /g;
        }
        $stored = 1 if $id;
        if (!$stored && $error && $error =~ /active ban already exists/i) {
            my $existing = eval {
                $self->{channel_ban}->active_ban_for_mask(
                    $id_channel,
                    $prefix,
                );
            };
            if ($existing && defined($existing->{mask}) && $existing->{mask} ne '') {
                # Reuse the exact stored mask. The matching row may be broader
                # than this actor's normalized hostmask, and the expiry worker
                # can only remove the mask that is actually present in its row.
                $mask = $existing->{mask};
                $stored = 1;
            }
            else {
                $error = 'active ban reported but its durable mask could not be resolved';
            }
        }
    }
    else {
        $error = 'persistent channel or ChannelBan helper unavailable';
    }

    unless ($stored) {
        $error //= 'persistent ban returned neither an id nor an error';
        $self->_log(1,
            "Fullop: refusing unmanaged IRC ban on $channel for $prefix: $error");

        # The protected MODE has already been reversed. A plain kick remains
        # safe here, while setting +b without a durable expiry row could leave
        # an unbounded ban behind after a database failure.
        $self->_announce($channel, $nick);
        $self->_send('KICK', undef, $channel, $nick, DEFAULT_REASON);
        return 0;
    }

    $self->_announce($channel, $nick);
    $self->_send('MODE', undef, $channel, '+b', $mask);
    $self->_send('KICK', undef, $channel, $nick, DEFAULT_REASON);

    if ($self->{bot} && $self->{bot}{metrics}) {
        $self->{bot}{metrics}->inc('mediabot_fullop_sanctions_total',
            { channel => $channel });
    }
    return 1;
}

sub handle_mode {
    my ($self, %args) = @_;
    my $channel     = $args{channel};
    my $message     = $args{message};
    my $prefix      = defined($args{prefix}) ? $args{prefix}
                    : eval { $message->prefix };
    my $mode_string = $args{mode_string};
    my @mode_args   = @{ $args{mode_args} || [] };

    return { enabled => 0, corrected => 0, sanctioned => 0, delegated => 0 }
        unless $self->enabled($channel);

    my @changes = $self->parse_mode_changes($mode_string, @mode_args);
    return { enabled => 1, corrected => 0, sanctioned => 0, delegated => 0 }
        unless @changes;

    if ($self->_actor_is_privileged($message, $channel, $prefix)) {
        $self->_remember_change($channel, $_) for @changes;
        return {
            enabled => 1, privileged => 1, corrected => 0,
            sanctioned => 0, delegated => 0,
        };
    }

    my (@protected, @delegated);
    for my $change (@changes) {
        if (!$self->_is_protected_change($change)) {
            $self->_remember_change($channel, $change);
        }
        elsif ($self->_consume_delegated_ban($channel, $prefix, $change)) {
            push @delegated, $change;
        }
        else {
            push @protected, $change;
        }
    }

    return {
        enabled => 1, corrected => 0, sanctioned => 0,
        delegated => scalar(@delegated),
    }
        unless @protected;

    my $corrected = 0;
    for my $change (@protected) {
        my @commands = $self->_correction_commands($channel, $change);
        unless (@commands) {
            $self->_log(4,
                "Fullop: protected $change->{sign}$change->{mode} on $channel required no reconstructable mode change");
            next;
        }

        for my $command (@commands) {
            $self->_send('MODE', undef, $channel, @$command);
            my @inverse_change = $self->parse_mode_changes(@$command);
            $self->_remember_change($channel, $_) for @inverse_change;
            $corrected++;
        }

        if ($self->{bot} && $self->{bot}{metrics}) {
            $self->{bot}{metrics}->inc('mediabot_fullop_corrections_total',
                { channel => $channel, mode => $change->{mode} });
        }
    }

    my $sanctioned = $self->_sanction($channel, $prefix);
    if ($sanctioned) {
        $self->_log(1,
            "Fullop: reversed " . scalar(@protected)
            . " protected mode change(s) on $channel and sanctioned $prefix for "
            . $self->ban_seconds . 's');
    }
    else {
        $self->_log(1,
            "Fullop: reversed " . scalar(@protected)
            . " protected mode change(s) on $channel; actor was kicked but "
            . 'the persistent kickban was not issued');
    }

    return {
        enabled    => 1,
        corrected  => $corrected,
        protected  => scalar(@protected),
        sanctioned => $sanctioned ? 1 : 0,
        delegated  => scalar(@delegated),
    };
}

sub _send_op_batches {
    my ($self, $channel, @nicks) = @_;
    my %seen;
    @nicks = grep {
        defined($_) && $_ =~ /^[^\s,]+$/ && !$seen{$self->_fold($_)}++
    } @nicks;
    return 0 unless @nicks;

    my $batch = $self->{max_modes} || 4;
    $batch = 4 if $batch < 1 || $batch > 20;
    my $sent = 0;

    while (@nicks) {
        my @slice = splice(@nicks, 0, $batch);
        $self->_send('MODE', undef, $channel, '+' . ('o' x @slice), @slice);
        $sent += @slice;
    }
    return $sent;
}

sub handle_join {
    my ($self, $channel, $nick, %opts) = @_;
    return 0 unless $self->enabled($channel);
    return 0 if $opts{banned};
    return $self->_send_op_batches($channel, $nick);
}

sub sweep_channel {
    my ($self, $channel, @nicks) = @_;
    return 0 unless $self->enabled($channel);
    @nicks = $self->_nicklist($channel) unless @nicks;
    return $self->_send_op_batches($channel, @nicks);
}

sub activate_channel {
    my ($self, $channel, %opts) = @_;
    return 0 unless $self->enabled($channel);

    my $swept = $self->sweep_channel($channel);
    $self->_send('MODE', undef, $channel) if !exists($opts{query_mode}) || $opts{query_mode};
    $self->_send('NAMES', undef, $channel) if $opts{refresh_names};
    return $swept;
}

1;

__END__

=head1 NAME

Mediabot::Fullop - network-aware open-channel protection for +Fullop

=head1 POLICY

Every joiner is opped.  An unprivileged MODE that can restrict joins or speech,
remove an official exception, remove an op, or alter a higher status is reversed.
The actor is then banned and kicked for ten minutes.  Raw KICK remains outside
this module by design.  Exemptions require an authenticated global Administrator
or a channel access of at least 75.

=cut
