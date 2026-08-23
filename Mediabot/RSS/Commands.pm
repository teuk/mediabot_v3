package Mediabot::RSS::Commands;

use strict;
use warnings;
use utf8;

use Mediabot::CommandAsync;
use Mediabot::Helpers qw(botNotice botPrivmsg checkCmdCooldown checkUserChannelLevel logBot);
use Mediabot::RSS qw(
    normalize_feed_label canonical_feed_url validate_feed_url
    format_rss_announcement format_rss_feed_list
);
use Mediabot::RSS::Fetcher;
use Mediabot::RSS::Repository;
use Mediabot::RSS::TinyURL qw(make_shortener);

sub _syntax {
    my ($ctx) = @_;
    my $nick = $ctx->nick;
    my $bot  = $ctx->bot;
    botNotice($bot, $nick, 'RSS syntax:');
    botNotice($bot, $nick, 'rss list [#channel]');
    botNotice($bot, $nick, 'rss info [#channel] <feed name>');
    botNotice($bot, $nick, 'rss add [#channel] <feed name> <https://...> [interval=30] [max=5]');
    botNotice($bot, $nick, 'rss del [#channel] <feed name>');
    botNotice($bot, $nick, 'rss set [#channel] <feed name> <interval|max|enabled> <value>');
    botNotice($bot, $nick, 'rss probe <https://...>');
    botNotice($bot, $nick, 'rss show [#channel] <feed name>');
    return;
}

sub _target_channel {
    my ($ctx, $args) = @_;
    my $channel;
    if (@$args && defined($args->[0]) && $args->[0] =~ /^[#&!+]/) {
        $channel = shift @$args;
    }
    else {
        my $cur = $ctx->channel // '';
        $channel = $cur if $cur =~ /^[#&!+]/;
    }
    return $channel;
}

sub _registered_channel_id {
    my ($ctx, $channel) = @_;
    return undef unless defined $channel;
    my $obj = $ctx->bot->{channels}{lc $channel};
    return undef unless $obj;
    return eval { $obj->get_id };
}

sub _can_manage {
    my ($ctx, $channel) = @_;
    my $user = $ctx->require_auth or return 0;
    return 1 if eval { $user->has_level('Administrator') };
    my $uid = eval { $user->id };
    return 0 unless defined $uid;
    return checkUserChannelLevel($ctx->bot, $ctx->message, $channel, $uid, 400) ? 1 : 0;
}

sub _repo {
    my ($ctx) = @_;
    return Mediabot::RSS::Repository->new(dbh => $ctx->bot->{dbh});
}

sub _db_error {
    my ($ctx, $what, $err) = @_;
    $err = 'unknown database error' unless defined $err && length $err;
    $err =~ s/[\r\n\0]+/ /g;
    eval { $ctx->bot->{logger}->log(1, "rss $what: $err") };
    $ctx->reply_private("RSS database error while $what.");
    return;
}

sub _list {
    my ($ctx, @args) = @_;
    my $channel = _target_channel($ctx, \@args);
    return botNotice($ctx->bot, $ctx->nick, 'Syntax: rss list [#channel]')
        unless defined $channel && !@args;
    my $rows = eval { _repo($ctx)->list_feeds($channel) };
    return _db_error($ctx, 'listing feeds', $@) unless $rows;
    return $ctx->reply("No RSS feeds configured for $channel.") unless @$rows;
    return $ctx->reply(format_rss_feed_list(map { $_->{label} } @$rows));
}

sub _info {
    my ($ctx, @args) = @_;
    my $channel = _target_channel($ctx, \@args);
    my $label = normalize_feed_label(join(' ', @args));
    return botNotice($ctx->bot, $ctx->nick, 'Syntax: rss info [#channel] <feed name>')
        unless defined $channel && defined $label;
    my $feed = eval { _repo($ctx)->get_feed($channel, $label) };
    return _db_error($ctx, 'reading feed info', $@) if $@;
    return botNotice($ctx->bot, $ctx->nick, "RSS feed '$label' not found on $channel.") unless $feed;
    my $interval = int(($feed->{poll_interval} || 0) / 60);
    my $enabled = $feed->{enabled} ? 'on' : 'off';
    botNotice($ctx->bot, $ctx->nick, "RSS [$feed->{label}] on $channel");
    botNotice($ctx->bot, $ctx->nick, "URL: $feed->{url}");
    botNotice($ctx->bot, $ctx->nick, "Interval: ${interval} min | max: $feed->{announce_limit} | enabled: $enabled | seen: " . ($feed->{item_count} || 0));
    botNotice($ctx->bot, $ctx->nick, 'Last success: ' . ($feed->{last_success_at} // 'never'));
    botNotice($ctx->bot, $ctx->nick, 'Last error: ' . ($feed->{last_error} // 'none'));
    return 1;
}

sub _parse_add {
    my (@args) = @_;
    my %opt = ( interval => 30, max => 5 );
    my $url_i;
    for my $i (0 .. $#args) {
        if (defined($args[$i]) && $args[$i] =~ m{^https?://}i) { $url_i = $i; last }
    }
    return unless defined $url_i && $url_i > 0;
    my $label = normalize_feed_label(join(' ', @args[0 .. $url_i-1]));
    my $url = $args[$url_i];
    for my $tok (@args[$url_i+1 .. $#args]) {
        next unless defined $tok && length $tok;
        return unless $tok =~ /^(interval|max)=(\d+)$/i;
        $opt{lc $1} = 0 + $2;
    }
    return unless defined $label;
    return unless $opt{interval} >= 5 && $opt{interval} <= 1440;
    return unless $opt{max} >= 1 && $opt{max} <= 10;
    return ($label, $url, \%opt);
}

sub _add {
    my ($ctx, @args) = @_;
    my $channel = _target_channel($ctx, \@args);
    return botNotice($ctx->bot, $ctx->nick,
        'Syntax: rss add [#channel] <feed name> <https://...> [interval=30] [max=5]')
        unless defined $channel;
    return unless _can_manage($ctx, $channel);
    my $id_channel = _registered_channel_id($ctx, $channel);
    return botNotice($ctx->bot, $ctx->nick, "Channel $channel is not registered to Mediabot.")
        unless defined $id_channel;
    my ($label, $url, $opt) = _parse_add(@args);
    return botNotice($ctx->bot, $ctx->nick,
        'Syntax: rss add [#channel] <feed name> <https://...> [interval=30] [max=5]')
        unless defined $label;
    my $valid = validate_feed_url($url);
    return botNotice($ctx->bot, $ctx->nick, "RSS URL rejected: $valid->{error}.")
        unless $valid->{ok};
    my $canon = canonical_feed_url($url);
    my $user = $ctx->user;
    my $ok = eval {
        _repo($ctx)->add_feed(
            id_channel      => $id_channel,
            label           => $label,
            url             => $canon,
            poll_interval   => $opt->{interval} * 60,
            announce_limit  => $opt->{max},
            created_by      => eval { $user->id },
            created_by_nick => eval { $user->nickname } // $ctx->nick,
        );
        1;
    };
    if (!$ok) {
        my $e = $@ || '';
        if ($e =~ /Duplicate entry/i) {
            return botNotice($ctx->bot, $ctx->nick,
                "RSS feed label or URL already exists on $channel.");
        }
        return _db_error($ctx, 'adding feed', $e);
    }
    logBot($ctx->bot, $ctx->message, $channel, 'rss', 'add', $label, $canon);
    return $ctx->reply("RSS [$label] added on $channel (every $opt->{interval} min, max $opt->{max}).");
}

sub _del {
    my ($ctx, @args) = @_;
    my $channel = _target_channel($ctx, \@args);
    my $label = normalize_feed_label(join(' ', @args));
    return botNotice($ctx->bot, $ctx->nick, 'Syntax: rss del [#channel] <feed name>')
        unless defined $channel && defined $label;
    return unless _can_manage($ctx, $channel);
    my $ok = eval { _repo($ctx)->delete_feed($channel, $label) };
    return _db_error($ctx, 'deleting feed', $@) if $@;
    return botNotice($ctx->bot, $ctx->nick, "RSS feed '$label' not found on $channel.") unless $ok;
    logBot($ctx->bot, $ctx->message, $channel, 'rss', 'del', $label);
    return $ctx->reply("RSS [$label] removed from $channel.");
}

sub _set {
    my ($ctx, @args) = @_;
    my $channel = _target_channel($ctx, \@args);
    return botNotice($ctx->bot, $ctx->nick,
        'Syntax: rss set [#channel] <feed name> <interval|max|enabled> <value>')
        unless defined $channel && @args >= 3;
    return unless _can_manage($ctx, $channel);
    my $value   = pop @args;
    my $setting = lc(pop @args // '');
    my $label   = normalize_feed_label(join(' ', @args));
    return botNotice($ctx->bot, $ctx->nick,
        'Syntax: rss set [#channel] <feed name> <interval|max|enabled> <value>')
        unless defined $label && $setting =~ /^(?:interval|max|enabled)$/;
    my $rv = eval { _repo($ctx)->update_feed_setting($channel, $label, $setting, $value) };
    return _db_error($ctx, 'updating feed', $@) if $@;
    return botNotice($ctx->bot, $ctx->nick, "RSS feed '$label' not found on $channel.") if !$rv;
    return botNotice($ctx->bot, $ctx->nick, "Invalid RSS $setting value.") if $rv < 0;
    logBot($ctx->bot, $ctx->message, $channel, 'rss', 'set', $label, $setting, $value);
    return $ctx->reply("RSS [$label] $setting set to $value on $channel.");
}

sub _probe_worker {
    my ($ctx, $url) = @_;
    my $res = Mediabot::RSS::Fetcher::fetch_feed_once($url, max_items => 3);
    unless ($res->{ok}) {
        return $ctx->reply_private(
            'RSS probe failed: ' . ($res->{error} // 'unknown') . '.');
    }
    my $feed = $res->{feed};
    my $title = $feed->{title} || 'RSS';
    my $count = scalar @{ $feed->{items} || [] };
    $ctx->reply_private(
        "RSS probe OK: [$title] $feed->{format}, $count item(s), HTTP $res->{status}.");
    if ($count) {
        my $it = $feed->{items}[0];
        my $shorten = make_shortener();
        my $display_url = $shorten->($it->{url});
        my $line = format_rss_announcement(
            label => $title, title => $it->{title}, url => $display_url
        );
        $ctx->reply($line) if defined $line;
    }
    return 1;
}

sub _probe {
    my ($ctx, @args) = @_;
    return botNotice($ctx->bot, $ctx->nick, 'Syntax: rss probe <https://...>') unless @args == 1;
    return unless $ctx->require_level('User');
    my $valid = validate_feed_url($args[0]);
    return botNotice($ctx->bot, $ctx->nick, "RSS URL rejected: $valid->{error}.") unless $valid->{ok};
    my $wait = checkCmdCooldown($ctx->bot, $ctx->channel, 'rssprobe', 15);
    return botNotice($ctx->bot, $ctx->nick, "RSS probe cooldown: ${wait}s.") if $wait > 0;
    my $url = $args[0];
    return Mediabot::CommandAsync::run_ctx_async(
        $ctx->bot, $ctx, 'rss probe', sub { _probe_worker($ctx, $url) }
    );
}

sub _show_worker {
    my ($ctx, $channel, $label) = @_;
    my $feed = eval { _repo($ctx)->get_feed($channel, $label) };
    return _db_error($ctx, 'reading feed', $@) if $@;
    return $ctx->reply_private("RSS feed '$label' not found on $channel.") unless $feed;
    my $res = Mediabot::RSS::Fetcher::fetch_feed_once(
        $feed->{url}, max_items => ($feed->{announce_limit} || 5)
    );
    unless ($res->{ok}) {
        return $ctx->reply_private(
            "RSS [$feed->{label}] fetch failed: " . ($res->{error} // 'unknown') . '.');
    }
    my @items = @{ $res->{feed}{items} || [] };
    return $ctx->reply_private("RSS [$feed->{label}] has no readable items.") unless @items;
    my $shorten = make_shortener();
    for my $it (@items) {
        my $display_url = $shorten->($it->{url});
        my $line = format_rss_announcement(
            label => $feed->{label}, title => $it->{title}, url => $display_url
        );
        $ctx->reply($line) if defined $line;
    }
    return 1;
}

sub _show {
    my ($ctx, @args) = @_;
    my $channel = _target_channel($ctx, \@args);
    my $label = normalize_feed_label(join(' ', @args));
    return botNotice($ctx->bot, $ctx->nick, 'Syntax: rss show [#channel] <feed name>')
        unless defined $channel && defined $label;
    return unless $ctx->require_level('User');
    my $wait = checkCmdCooldown($ctx->bot, $channel, 'rssshow', 15);
    return botNotice($ctx->bot, $ctx->nick, "RSS show cooldown: ${wait}s.") if $wait > 0;
    return Mediabot::CommandAsync::run_ctx_async(
        $ctx->bot, $ctx, 'rss show', sub { _show_worker($ctx, $channel, $label) }
    );
}

sub mbRss_ctx {
    my ($ctx) = @_;
    my @args = @{ $ctx->args || [] };
    return _syntax($ctx) unless @args;
    my $sub = lc shift @args;
    return _syntax($ctx) if $sub =~ /^(?:help|syntax)$/;
    return _list($ctx, @args)  if $sub eq 'list';
    return _info($ctx, @args)  if $sub eq 'info';
    return _add($ctx, @args)   if $sub eq 'add';
    return _del($ctx, @args)   if $sub =~ /^(?:del|delete|remove)$/;
    return _set($ctx, @args)   if $sub eq 'set';
    return _probe($ctx, @args) if $sub eq 'probe';
    return _show($ctx, @args)  if $sub eq 'show';
    return _syntax($ctx);
}

1;
