package Mediabot::External::SearchCommand;

use strict;
use warnings;
use Encode qw(decode encode FB_CROAK LEAVE_SRC);
use Exporter 'import';
use Mediabot::Helpers ();
use Mediabot::AsyncWorker ();
use Mediabot::IRC::DeliveryContext qw(capture_delivery_context delivery_context_current);
use Mediabot::IRC::TextBudget qw(_irc_wire_bytes);

our @EXPORT_OK = qw(_edition _language _query run_lookup);

sub _edition {
    my ($value) = @_;
    return 'en' unless defined($value) && !ref($value);
    $value =~ s/^\s+|\s+$//g;
    return lc($1) if $value =~ /\A([a-z]{2,3})(?:[-_][a-z0-9]+)*\z/i;
    return 'en';
}
sub _language { return _edition(eval {Mediabot::Helpers::channel_lang($_[0], $_[1])}) }
sub _query {
    my ($args) = @_;
    return unless ref($args) eq 'ARRAY' && @$args && @$args <= 32;
    return if grep {!defined($_) || ref($_)} @$args;
    # MB1132: joining bytes to a character scalar upgrades the bytes as
    # Latin-1. Decode each argument first, without modifying caller values.
    my $raw_length = @$args - 1;
    my @parts;
    for my $arg (@$args) {
        $raw_length += length($arg);
        return if $raw_length > 640;
        my $part = utf8::is_utf8($arg) ? $arg
            : eval {decode('UTF-8', $arg, FB_CROAK | LEAVE_SRC)};
        return unless defined $part;
        push @parts, $part;
    }
    my $text = join ' ', @parts;
    return unless defined($text) && $text !~ /[\x00-\x1f\x7f]/;
    $text =~ s/\s+/ /g;
    $text =~ s/^\s+|\s+$//g;
    return unless length($text) && length($text) <= 160;
    my $bytes = eval {encode('UTF-8', $text, FB_CROAK | LEAVE_SRC)};
    return unless defined($bytes) && length($bytes) <= 320;
    return $text;
}
sub _name { return defined($_[0]) && !ref($_[0]) && $_[0] =~ /\A(?:Wikipedia|ddg)\z/ ? $_[0] : undef }
sub _channel { return defined($_[0]) && !ref($_[0]) && $_[0] =~ /\A#[^\x00-\x20\x7f,:]{1,254}\z/ }
sub enabled {
    my ($bot, $channel, $name) = @_;
    return 0 unless _name($name) && _channel($channel);
    my $on = eval {
        my $db = $bot->{db} ? $bot->{db}->ensure_connected : $bot->{dbh};
        return 0 unless $db;
        my $sth = $db->prepare(q{SELECT CS.id_channel_set FROM CHANNEL_SET CS
            JOIN CHANNEL C ON C.id_channel=CS.id_channel
            JOIN CHANSET_LIST CL ON CL.id_chanset_list=CS.id_chanset_list
            WHERE C.name=? AND CL.chanset=?}) or return 0;
        my ($ok, $row, $error);
        my $read = eval {$ok=$sth->execute($channel,$name);$row=$sth->fetchrow_arrayref if $ok;$error=$sth->err;1};
        eval {$sth->finish};
        return $read && $ok && !$error && ref($row) eq 'ARRAY' && @$row
            && defined($row->[0]) && !ref($row->[0]) && "$row->[0]" =~ /\A[1-9][0-9]*\z/ ? 1 : 0;
    };
    return $on ? 1 : 0;
}
sub register_chanset {
    my ($bot, $name) = @_;
    return unless _name($name);
    return eval {
        my $db = $bot->{db} ? $bot->{db}->ensure_connected : $bot->{dbh};
        return unless $db;
        my $sth = $db->prepare(q{INSERT INTO CHANSET_LIST(chanset)
            SELECT ? WHERE NOT EXISTS(SELECT 1 FROM CHANSET_LIST WHERE chanset=?)}) or return;
        my ($ok,$error);
        my $written = eval {$ok=$sth->execute($name,$name);$error=$sth->err;1};
        eval {$sth->finish};
        return $written && $ok && !$error ? 1 : undef;
    };
}
sub epoch { return $_[0]{_search_policy_epoch}{$_[2]}{lc($_[1])} // 0 }
sub note_policy_change {
    my ($bot,$channel,$name)=@_;
    return unless _name($name) && _channel($channel);
    return ++$bot->{_search_policy_epoch}{$name}{lc($channel)};
}

# Shared bounded lifecycle; the provider owns its child lookup and parent renderer.
sub run_lookup {
    my ($ctx,%args)=@_;
    my $name=_name($args{name}) or return;
    my $reply_limit=$name eq 'ddg' ? 3 : 2;
    my $bot=$ctx->bot;my $channel=$ctx->channel;
    return unless enabled($bot,$channel,$name);
    my $lang=_language($bot,$channel);my $input=$ctx->args;
    my $message=$args{message};
    unless (ref($input) eq 'ARRAY' && @$input) {$ctx->reply_private($message->($lang,'syntax'));return}
    my $query=_query($input);
    unless (defined $query) {$ctx->reply_private($message->($lang,'invalid'));return}
    my $loop=eval {$bot->getLoop};$loop||=$bot->{loop};
    unless ($loop && $loop->can('add') && $loop->can('remove')) {$ctx->reply_private($message->($lang,'unavailable'));return}
    my $key='_'.lc($name);my $pending=$bot->{$key.'_pending'} //= {};
    if (keys(%$pending)>=2) {$ctx->reply_private($message->($lang,'busy'));return}
    my $id=++$bot->{$key.'_sequence'};$pending->{$id}=1;
    my $binding=capture_delivery_context($bot,$channel);
    my $epoch=epoch($bot,$channel,$name);my $finished=0;
    my $done=sub {
        my ($result)=@_;return if $finished++;
        delete $pending->{$id};
        return unless delivery_context_current($bot,$binding)
            && epoch($bot,$channel,$name)==$epoch && enabled($bot,$channel,$name);
        my $lines;
        if (ref($result) eq 'HASH' && $result->{ok} && ref($result->{value}) eq 'HASH') {
            $lines=eval {$args{render}->($result->{value},$lang)};
        }
        $lines=[$message->($lang,'unavailable')] unless ref($lines) eq 'ARRAY' && @$lines && @$lines<=$reply_limit
            && !grep {!defined($_) || ref($_) || !length($_) || /[\x00-\x01\x04-\x0e\x10-\x1e\x7f]/ || _irc_wire_bytes($_)>400} @$lines;
        for my $line (@$lines) {
            # A synchronous transport callback can revoke later results too.
            last unless delivery_context_current($bot,$binding)
                && epoch($bot,$channel,$name)==$epoch && enabled($bot,$channel,$name);
            my $sent=eval {$ctx->reply($line);1};
            eval {$bot->{logger}->log(1,"$name reply failed")} if !$sent && $bot->{logger};
            last unless $sent;
        }
    };
    my $worker=eval {Mediabot::AsyncWorker->start(
        loop=>$loop,label=>$args{label},timeout=>$args{timeout}//12,
        term_grace=>$args{term_grace}//0.2,force_grace=>$args{force_grace}//1,max_output=>$args{max_output}//8192,
        child=>sub {
            eval {$bot->{dbh}{InactiveDestroy}=1 if $bot->{dbh}};
            eval {$bot->{db}{dbh}{InactiveDestroy}=1 if $bot->{db} && $bot->{db}{dbh}};
            return $args{lookup}->($query,$lang);
        },on_done=>$done)};
    $done->({ok=>0,error=>'worker_setup'}) unless $worker;
    return 1;
}

1;
