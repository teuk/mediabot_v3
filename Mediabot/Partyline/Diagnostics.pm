package Mediabot::Partyline::Diagnostics;
use strict;
use warnings;
use Encode qw(encode);
use Exporter 'import';
use Mediabot::Diagnostics::Channel;
our @EXPORT_OK=qw(_cmd_diagnose);
sub _cmd_diagnose {
    my ($self,$stream,$id,$arg)=@_;
    my $session=$self->{users}{$id};
    my $level=$session ? $session->{level}:undef;
    unless ($session && $session->{authenticated} && defined($level) && !ref($level)
        && "$level" =~ /\A[01]\z/) {
        $stream->write("Access denied: .diagnose requires an authenticated Master or Owner.\r\n");return;
    }
    unless (Mediabot::Diagnostics::Channel::valid_channel($arg)) {
        $stream->write("Usage: .diagnose <#channel> (read-only)\r\n");return;
    }
    my $lines=eval {
        my $diagnostic=Mediabot::Diagnostics::Channel->new(bot=>$self->{bot});
        $diagnostic->lines($diagnostic->collect($arg));
    };
    unless ($lines) {$stream->write("Channel diagnosis unavailable.\r\n");return}
    $stream->write(encode('UTF-8',join('',map {$_ . "\r\n"} @$lines)));
    return 1;
}
1;
